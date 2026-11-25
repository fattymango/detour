package com.detour.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Owns the local TUN interface and the TLS connection to the tunnel server,
 * pumping raw IP packets between them. Split-tunneling is just which apps
 * [VpnService.Builder.addAllowedApplication] is called for - everything else
 * bypasses this interface entirely at the OS level.
 */
class TunnelVpnService : VpnService() {
    // Single-threaded: connect/disconnect/reconnect requests must never run
    // concurrently, or a torn-down session can race a new one establishing.
    private val executor = Executors.newSingleThreadExecutor()

    // Only for timing reconnect backoff - keeps the delay off `executor` so a
    // user-tapped disconnect during a (possibly 30s) backoff wait is handled
    // immediately instead of queuing behind a sleeping task.
    private val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

    private var tunFd: ParcelFileDescriptor? = null
    private var client: TunnelClient? = null
    private var relayThreads: List<Thread> = emptyList()
    private val adBlockSettings by lazy { AdBlockSettings(applicationContext) }

    // Without this, Doze/App Standby can suspend the heartbeat thread's CPU
    // time while the screen is off, so no heartbeat actually reaches the
    // server even though the thread "is running" - the connection then dies
    // at the server's read-timeout and reconnects, repeatedly. Held only
    // while a session is actually up; see doConnect()/tearDown().
    private var wakeLock: PowerManager.WakeLock? = null

    // Bumped on every doConnect(). Lets a stale session's relay thread (still
    // unwinding after we closed its socket/fd during a live reconnect) tell
    // that it's no longer the active session, so it doesn't tear down or
    // reconnect over a new one that has since replaced it.
    private val sessionGeneration = AtomicLong(0)

    // True only while handling a user-tapped disconnect. Distinguishes "user
    // wants this off" (give up, go to DOWN) from "connection died on its own"
    // (auto-reconnect) in the relay threads' failure handling.
    @Volatile private var userInitiatedDisconnect = false

    // Reset to 0 on every successful connect; counts consecutive automatic
    // reconnect attempts so a genuinely dead server doesn't retry forever.
    private var reconnectAttempts = 0

    override fun onCreate() {
        super.onCreate()
        VpnLogStore.init(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT -> {
                val name = intent.getStringExtra(EXTRA_CONFIG_NAME) ?: return START_NOT_STICKY
                executor.execute {
                    userInitiatedDisconnect = false
                    doConnect(name)
                }
            }
            ACTION_DISCONNECT -> {
                executor.execute {
                    userInitiatedDisconnect = true
                    doDisconnect()
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun doConnect(name: String) {
        val mySession = sessionGeneration.incrementAndGet()
        // Must happen within a few seconds of the service starting whenever
        // it was launched via startForegroundService (the widget's connect
        // action does this, since a background/no-Activity caller isn't
        // allowed to plain-startService a service that's about to become
        // foreground) - posting this immediately, before the network
        // handshake below (which can take a real amount of time), avoids
        // Android killing the service for missing that window. Also just a
        // better UX: shows "Connecting..." instead of no notification at
        // all until the handshake finishes.
        startForeground(NOTIFICATION_ID, buildNotification(name, connecting = true))
        try {
            // In case a previous session is still up. Android doesn't always
            // release the old VPN interface synchronously just because its
            // ParcelFileDescriptor got closed - calling Builder.establish()
            // again immediately after can return null (misread as a real
            // connect failure) if the system hasn't caught up yet. A short
            // pause here, only when there was actually a prior interface to
            // tear down (skip it on a fresh first connect), gives it that
            // room.
            val hadPriorSession = tunFd != null
            tearDown()
            if (hadPriorSession) Thread.sleep(300)

            val config = ConfigStore(applicationContext).loadConfig(name)
            val tunnelClient = TunnelClient(config)
            tunnelClient.connectAndAuthenticate()
            // A read that gets nothing at all - not even a heartbeat - for
            // this long means the connection is dead (some network path
            // silently dropped it), not just quiet. See tunnel-server's
            // heartbeatInterval/readTimeout comment for the other half of this.
            tunnelClient.socket!!.soTimeout = READ_TIMEOUT_MS
            client = tunnelClient

            val builder = Builder()
                .setSession("detour")
                .addAddress(tunnelClient.assignedAddress!!, 24)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("1.1.1.1")
                .setMtu(1400)

            for (pkg in config.includedApplications) {
                try {
                    builder.addAllowedApplication(pkg)
                } catch (e: PackageManager.NameNotFoundException) {
                    Log.w(TAG, "Skipping unknown package in allow-list: $pkg")
                }
            }

            // establish() returning null is a known-flaky Android VPN API
            // result (transient system-side VPN state, not necessarily
            // anything wrong with this app's request) - one retry after a
            // beat clears it far more often than it's a real, persistent
            // failure worth surfacing to the user immediately.
            var pfd = builder.establish()
            if (pfd == null) {
                Log.w(TAG, "establish() returned null, retrying once")
                Thread.sleep(500)
                pfd = builder.establish()
            }
            tunFd = pfd ?: throw IOException("VpnService.Builder.establish() returned null")

            // Swap the "Connecting..." notification for the real one, now
            // that a session is actually up.
            startForeground(NOTIFICATION_ID, buildNotification(name, connecting = false))
            acquireWakeLock()

            val socket = tunnelClient.socket!!
            val socketOut = socket.outputStream
            val tunIn = FileInputStream(pfd.fileDescriptor)
            val tunOut = FileOutputStream(pfd.fileDescriptor)

            val adBlockEnabled = adBlockSettings.isEnabled()
            val tunToServer = Thread({ relayTunToServer(tunIn, socketOut, tunOut, adBlockEnabled, mySession) }, "tun-to-server")
            val serverToTun = Thread({ relayServerToTun(socket.inputStream, tunOut, mySession) }, "server-to-tun")
            val heartbeat = Thread({ heartbeatLoop(socketOut) }, "heartbeat")
            relayThreads = listOf(tunToServer, serverToTun, heartbeat)
            tunToServer.start()
            serverToTun.start()
            heartbeat.start()

            reconnectAttempts = 0
            currentState = "UP"
            currentConfigName = name
            notifyState(name, "UP")
            VpnLogStore.log("Connected to $name")
        } catch (e: Exception) {
            Log.e(TAG, "connect failed", e)
            VpnLogStore.log("Connect to $name failed: ${e.message}")
            handleSessionEnded(mySession, name)
        }
    }

    /** (configName, state) - invoked off the main thread; caller must post to UI. */
    private fun notifyState(name: String?, state: String) {
        stateListener?.invoke(name, state)
    }

    private fun relayTunToServer(tunIn: FileInputStream, serverOut: OutputStream, tunOut: FileOutputStream, adBlockEnabled: Boolean, session: Long) {
        val buffer = ByteArray(32767)
        try {
            while (true) {
                val n = tunIn.read(buffer)
                // A blocking read on the TUN fd should never return 0, and a
                // negative result means the fd was closed out from under us
                // (EOF) - not a transient "nothing to read yet". Treating
                // either as "try again immediately" turns this into a
                // tight, unthrottled spin loop that pins a CPU core for as
                // long as the session is up.
                if (n < 0) break
                if (n == 0) {
                    // On this fd, a 0-byte result seems to mean "nothing
                    // ready yet" rather than true blocking behavior - retry
                    // without a delay here becomes an unthrottled busy-spin
                    // that pins a CPU core the entire time the VPN is
                    // connected (confirmed via `top -H`: this thread alone
                    // sustained ~100% CPU independent of actual traffic).
                    Thread.sleep(5)
                    continue
                }

                if (adBlockEnabled) {
                    val blockedReply = AdBlockFilter.tryHandleDns(applicationContext, buffer, n)
                    if (blockedReply != null) {
                        tunOut.write(blockedReply)
                        continue // never forwarded into the tunnel
                    }
                }

                writeFramedPacket(serverOut, buffer, n)
            }
        } catch (e: Exception) {
            Log.i(TAG, "tun-to-server loop ended: ${e.message}")
        }
        handleSessionEnded(session, currentConfigName)
    }

    private fun relayServerToTun(serverIn: java.io.InputStream, tunOut: FileOutputStream, session: Long) {
        try {
            while (true) {
                val packet = readFramedPacket(serverIn)
                if (packet.isEmpty()) continue // heartbeat from server, nothing to write
                tunOut.write(packet)
            }
        } catch (e: Exception) {
            Log.i(TAG, "server-to-tun loop ended: ${e.message}")
        }
        handleSessionEnded(session, currentConfigName)
    }

    private fun heartbeatLoop(serverOut: OutputStream) {
        try {
            while (true) {
                Thread.sleep(HEARTBEAT_INTERVAL_MS)
                writeFramedPacket(serverOut, ByteArray(0), 0)
            }
        } catch (e: Exception) {
            Log.i(TAG, "heartbeat loop ended: ${e.message}")
        }
    }

    /**
     * Called from any relay thread (or a failed connect attempt) when a
     * session ends. If a newer session has since taken over, this is just a
     * stale thread noticing we closed its socket on purpose - ignore it. If
     * the user asked to disconnect, honor that. Otherwise the connection died
     * on its own (e.g. that idle-timeout scenario) - retry with backoff, up
     * to a point.
     */
    private fun handleSessionEnded(session: Long, name: String?) {
        // Multiple relay threads can notice the same dead session at once;
        // only the one that wins this CAS proceeds; a stale session (already
        // superseded by a newer doConnect) fails it too, since the value
        // will no longer be `session`.
        if (!sessionGeneration.compareAndSet(session, session + 1)) return

        if (userInitiatedDisconnect) {
            doDisconnect()
            return
        }

        if (name == null || reconnectAttempts >= RECONNECT_DELAYS_MS.size) {
            currentState = "DOWN"
            currentConfigName = null
            notifyState(name, "ERROR:Connection lost")
            VpnLogStore.log("Connection to $name lost, giving up after $reconnectAttempts attempt(s)")
            tearDown()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        val delay = RECONNECT_DELAYS_MS[reconnectAttempts]
        reconnectAttempts++
        Log.w(TAG, "Session ended unexpectedly, reconnecting to $name in ${delay}ms (attempt $reconnectAttempts)")
        VpnLogStore.log("Connection to $name dropped, reconnecting in ${delay}ms (attempt $reconnectAttempts)")
        currentState = "RECONNECTING"
        notifyState(name, "RECONNECTING")
        val claimedGeneration = session + 1 // what we just CAS'd sessionGeneration to, above
        scheduler.schedule({
            executor.execute {
                // Only proceed if nothing newer has happened since we claimed
                // this retry (no manual reconnect, no other retry in flight).
                if (sessionGeneration.get() == claimedGeneration && !userInitiatedDisconnect) {
                    doConnect(name)
                }
            }
        }, delay, TimeUnit.MILLISECONDS)
    }

    private fun doDisconnect() {
        val name = currentConfigName
        tearDown()
        currentState = "DOWN"
        currentConfigName = null
        notifyState(name, "DOWN")
        if (name != null) VpnLogStore.log("Disconnected from $name")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun tearDown() {
        relayThreads.forEach { it.interrupt() }
        relayThreads = emptyList()
        client?.close()
        client = null
        try {
            tunFd?.close()
        } catch (_: IOException) {
        }
        tunFd = null
        releaseWakeLock()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "detour:tunnel").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onRevoke() {
        userInitiatedDisconnect = true
        doDisconnect()
        super.onRevoke()
    }

    override fun onDestroy() {
        tearDown()
        scheduler.shutdownNow()
        super.onDestroy()
    }

    private fun buildNotification(configName: String, connecting: Boolean): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "VPN status", NotificationManager.IMPORTANCE_LOW)
            manager.createNotificationChannel(channel)
        }
        val disconnectIntent = Intent(this, TunnelVpnService::class.java).setAction(ACTION_DISCONNECT)
        val disconnectPending = PendingIntent.getService(
            this, 0, disconnectIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val title = if (connecting) "Connecting: $configName…" else "Connected: $configName"
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .addAction(0, "Disconnect", disconnectPending)
            .build()
    }

    companion object {
        const val ACTION_CONNECT = "com.detour.vpn.CONNECT"
        const val ACTION_DISCONNECT = "com.detour.vpn.DISCONNECT"
        const val EXTRA_CONFIG_NAME = "configName"
        private const val TAG = "TunnelVpnService"
        private const val CHANNEL_ID = "vpn_status"
        private const val NOTIFICATION_ID = 1

        private const val HEARTBEAT_INTERVAL_MS = 15_000L
        private const val READ_TIMEOUT_MS = 40_000
        private val RECONNECT_DELAYS_MS = longArrayOf(2_000, 4_000, 8_000, 16_000, 30_000)

        /** "UP", "DOWN", "RECONNECTING", or "ERROR:<message>" */
        @Volatile var currentState: String = "DOWN"
            private set

        @Volatile var currentConfigName: String? = null
            private set

        /** (configName, state) - invoked off the main thread; caller must post to UI. */
        var stateListener: ((String?, String) -> Unit)? = null
    }
}

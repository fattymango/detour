package com.detour.vpn

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Log
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import kotlin.math.min

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

    // What tunFd was set up for.
    private var tunAddress: String? = null
    private var tunApps: Set<String> = emptySet()

    private var client: TunnelClient? = null
    private var relayThreads: List<Thread> = emptyList()

    // Closing this ends the tun-to-server thread's wait for packets.
    private var stopPipe: FileDescriptor? = null

    // Never held for long: only while connecting, or checking the connection
    // after an alarm woke the phone.
    private val wakeLock by lazy {
        (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "detour:tunnel")
            .apply { setReferenceCounted(false) }
    }

    // elapsedRealtime of the last frame from the server.
    @Volatile private var lastReceived = 0L
    private val checking = AtomicBoolean(false)

    // Only used on executor.
    private var idleTracker: IdleTracker? = null
    private val idleStop by lazy { IdleStop(applicationContext) }
    private val trafficBytes = AtomicLong(0)
    @Volatile private var idleTimer: ScheduledFuture<*>? = null

    // The reconnect waiting out its backoff, if any.
    private val pendingRetry = AtomicReference<Runnable?>(null)

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = wakeUp()
    }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = wakeUp()
    }

    // Bumped on every doConnect(). Lets a stale session's relay thread (still
    // unwinding after we closed its socket/fd during a live reconnect) tell
    // that it's no longer the active session, so it doesn't tear down or
    // reconnect over a new one that has since replaced it.
    private val sessionGeneration = AtomicLong(0)

    // True only while handling a user-tapped disconnect. Distinguishes "user
    // wants this off" (give up, go to DOWN) from "connection died on its own"
    // (auto-reconnect) in the relay threads' failure handling.
    @Volatile private var userInitiatedDisconnect = false

    // Reset to 0 on every successful connect; picks the next backoff delay.
    private var reconnectAttempts = 0

    override fun onCreate() {
        super.onCreate()
        VpnLogStore.init(applicationContext)
        registerReceiver(screenReceiver, IntentFilter(Intent.ACTION_SCREEN_ON))
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(networkCallback)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT -> {
                val name = intent.getStringExtra(EXTRA_CONFIG_NAME) ?: return START_NOT_STICKY
                WidgetConfigStore(applicationContext).setLastConfig(name)
                executor.execute {
                    userInitiatedDisconnect = false
                    trafficBytes.set(0)
                    idleTracker = IdleTracker(packageName, System.currentTimeMillis())
                    doConnect(name)
                }
            }
            ACTION_DISCONNECT -> {
                executor.execute {
                    userInitiatedDisconnect = true
                    doDisconnect()
                }
            }
            ACTION_ALARM -> when (currentState) {
                "DOWN" -> stopSelf()
                "STANDBY" -> executor.execute {
                    val name = currentConfigName
                    if (currentState == "STANDBY" && idleStop.action != IdleStop.STANDBY && name != null) doConnect(name)
                }
                else -> {
                    wakeLock.acquire(CHECK_TIMEOUT_MS + 2_000)
                    executor.execute {
                        if (!stopIfIdle()) wakeUp(holdAwake = true)
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    /** How long the VPN's apps have been unused, or null if that doesn't matter or can't be known. */
    private fun idleTime(): Long? {
        val tracker = idleTracker ?: return null
        if (idleStop.action == IdleStop.OFF || !idleStop.hasUsageAccess()) return null
        val name = currentConfigName ?: return null
        return try {
            val apps = ConfigStore(applicationContext).loadConfig(name).includedApplications.toSet()
            val now = System.currentTimeMillis()
            tracker.update(idleStop.events(tracker.seenUntil, now), apps, trafficBytes.getAndSet(0), now)
        } catch (e: Exception) {
            Log.w(TAG, "can't tell whether the VPN is in use", e)
            null
        }
    }

    /** Stops the VPN if it's been unused for too long, or else schedules the next check. */
    private fun stopIfIdle(): Boolean {
        if (currentState == "DOWN" || currentState == "STANDBY") return true
        val idle = idleTime()
        if (idle != null && idle >= idleStop.limitMs) {
            if (idleStop.action == IdleStop.STANDBY && tunFd != null) enterStandby() else stopBecauseIdle()
            return true
        }
        scheduleChecks(idle)
        return false
    }

    /**
     * Leaves the server but keeps the tun, so the VPN's apps can't go around
     * it. The first packet sent while one of them is on screen reconnects.
     */
    private fun enterStandby() {
        val name = currentConfigName ?: return
        val session = sessionGeneration.incrementAndGet() // the ending session must not reconnect
        pendingRetry.set(null)
        cancelChecks()
        closeSession()
        currentState = "STANDBY"
        notifyState(name, "STANDBY")
        startForeground(NOTIFICATION_ID, buildNotification("Standby: $name"))
        VpnLogStore.log("$name on standby: not in use for ${idleStop.minutes} min")
        releaseWakeLock()

        val tun = tunFd!!.fileDescriptor
        val (stopRead, stopWrite) = Os.pipe().let { it[0] to it[1] }
        stopPipe = stopWrite
        val thread = Thread({ waitForUse(name, tun, stopRead, session) }, "standby")
        relayThreads = listOf(thread)
        thread.start()
    }

    private fun waitForUse(name: String, tun: FileDescriptor, stop: FileDescriptor, session: Long) {
        val buffer = ByteArray(32767)
        var lastLook = 0L
        try {
            forEachPacket(tun, stop, buffer) { n ->
                val now = SystemClock.elapsedRealtime()
                // Background traffic is dropped, without looking at every packet.
                if (now - lastLook < STANDBY_LOOK_MS) return@forEachPacket true
                lastLook = now
                if (!inUseNow(name)) return@forEachPacket true
                val first = buffer.copyOf(n)
                executor.execute {
                    if (sessionGeneration.get() == session && currentState == "STANDBY") doConnect(name, first)
                }
                false
            }
        } catch (e: Exception) {
            Log.w(TAG, "standby ended", e)
        }
        runCatching { Os.close(stop) }
    }

    private fun inUseNow(name: String): Boolean {
        if (!getSystemService(PowerManager::class.java).isInteractive) return false
        val tracker = idleTracker
        if (tracker == null || !idleStop.hasUsageAccess()) return true
        val apps = ConfigStore(applicationContext).loadConfig(name).includedApplications.toSet()
        val now = System.currentTimeMillis()
        tracker.update(idleStop.events(tracker.seenUntil, now), apps, 0, now)
        return tracker.vpnAppOnScreen()
    }

    /** Waits for packets, without polling, until [stop] is closed or [handle] returns false. */
    private fun forEachPacket(tun: FileDescriptor, stop: FileDescriptor, buffer: ByteArray, handle: (Int) -> Boolean) {
        fun poll(fd: FileDescriptor) = StructPollfd().apply {
            this.fd = fd
            events = OsConstants.POLLIN.toShort()
        }
        val fds = arrayOf(poll(tun), poll(stop))
        while (true) {
            try {
                Os.poll(fds, -1)
                if (fds[1].revents.toInt() != 0) return
                val n = Os.read(tun, buffer, 0, buffer.size)
                if (n <= 0 || !handle(n)) return
            } catch (e: ErrnoException) {
                if (e.errno != OsConstants.EAGAIN && e.errno != OsConstants.EINTR) throw e
            }
        }
    }

    private fun stopBecauseIdle() {
        val name = currentConfigName
        VpnLogStore.log("Stopped $name: not in use for ${idleStop.minutes} min")
        userInitiatedDisconnect = true
        doDisconnect()
        releaseWakeLock()
        if (name != null) {
            val reconnect = PendingIntent.getForegroundService(
                this, 2,
                Intent(this, TunnelVpnService::class.java).setAction(ACTION_CONNECT).putExtra(EXTRA_CONFIG_NAME, name),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            getSystemService(NotificationManager::class.java).notify(
                IDLE_NOTIFICATION_ID,
                Notification.Builder(this, CHANNEL_ID)
                    .setContentTitle("VPN stopped: not in use")
                    .setContentText("Your apps now use your normal connection")
                    .setSmallIcon(R.drawable.detour_notification)
                    .setAutoCancel(true)
                    .addAction(0, "Connect", reconnect)
                    .build(),
            )
        }
    }

    /** Retries now if reconnecting, otherwise makes sure the connection still works. */
    private fun wakeUp(holdAwake: Boolean = false) {
        val retry = pendingRetry.getAndSet(null)
        if (retry != null) {
            if (holdAwake) wakeLock.acquire(CONNECT_WAKE_MS)
            executor.execute(retry)
        } else if (currentState == "UP") {
            checkConnection(holdAwake)
        }
    }

    /** Pings the server, and drops the connection (so it reconnects) without an answer. */
    private fun checkConnection(holdAwake: Boolean) {
        val current = client ?: return
        val out = current.socket?.outputStream ?: return
        if (!checking.compareAndSet(false, true)) return
        if (holdAwake) wakeLock.acquire(CHECK_TIMEOUT_MS + 2_000)
        val sentAt = SystemClock.elapsedRealtime()
        // On its own thread, because writing to a dead connection can block.
        Thread({ runCatching { writeFramedPacket(out, PING, PING.size) } }, "ping").start()
        scheduler.schedule({
            checking.set(false)
            if (client === current && lastReceived < sentAt) {
                VpnLogStore.log("Server stopped answering")
                current.close()
            }
            releaseWakeLock()
        }, CHECK_TIMEOUT_MS, TimeUnit.MILLISECONDS)
    }

    private fun alarmIntent() = PendingIntent.getService(
        this, 1, Intent(this, TunnelVpnService::class.java).setAction(ACTION_ALARM),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    // Routers forget idle connections, so ping now and then even while asleep.
    private fun scheduleChecks(idle: Long?) {
        val untilIdle = if (idle == null) ALARM_INTERVAL_MS else IdleTracker.nextCheckMs(idle, idleStop.limitMs)
        getSystemService(AlarmManager::class.java).setAndAllowWhileIdle(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + min(ALARM_INTERVAL_MS, max(untilIdle, MIN_ALARM_MS)),
            alarmIntent(),
        )
        // Android runs the alarm minutes late. This is on time while the phone
        // is awake, and costs nothing while it sleeps.
        idleTimer?.cancel(false)
        idleTimer = if (idle == null) null else {
            scheduler.schedule({ executor.execute { stopIfIdle() } }, untilIdle, TimeUnit.MILLISECONDS)
        }
    }

    private fun cancelChecks() {
        getSystemService(AlarmManager::class.java).cancel(alarmIntent())
        idleTimer?.cancel(false)
        idleTimer = null
    }

    /** [first] is a packet from standby, to send if it is still valid. */
    private fun doConnect(name: String, first: ByteArray? = null) {
        val mySession = sessionGeneration.incrementAndGet()
        pendingRetry.set(null)
        currentConfigName = name
        wakeLock.acquire(CONNECT_WAKE_MS)
        scheduleChecks(idleTime())
        // Must happen within a few seconds of the service starting whenever
        // it was launched via startForegroundService (the widget's connect
        // action does this, since a background/no-Activity caller isn't
        // allowed to plain-startService a service that's about to become
        // foreground) - posting this immediately, before the network
        // handshake below (which can take a real amount of time), avoids
        // Android killing the service for missing that window. Also just a
        // better UX: shows "Connecting..." instead of no notification at
        // all until the handshake finishes.
        startForeground(NOTIFICATION_ID, buildNotification("Connecting: $name…"))
        getSystemService(NotificationManager::class.java).cancel(IDLE_NOTIFICATION_ID)
        if (currentState != "RECONNECTING") {
            currentState = "CONNECTING"
            notifyState(name, "CONNECTING")
        }
        try {
            // The old tun stays until the new one replaces it, so nothing
            // gets out around the VPN in between.
            closeSession()

            val config = ConfigStore(applicationContext).loadConfig(name)
            val tunnelClient = TunnelClient(config)
            tunnelClient.connectAndAuthenticate()
            // Silence is normal; checkConnection() finds dead connections.
            tunnelClient.socket!!.soTimeout = 0
            client = tunnelClient

            val address = tunnelClient.assignedAddress!!
            // This app stays outside its own tunnel, so it can always reach the server.
            val included = config.includedApplications.filter { it != packageName }.toSet()
            val reuse = tunFd != null && tunAddress == address && tunApps == included
            if (!reuse) establish(address, included)
            val pfd = tunFd!!

            // Swap the "Connecting..." notification for the real one, now
            // that a session is actually up.
            startForeground(NOTIFICATION_ID, buildNotification("Connected: $name"))

            val socket = tunnelClient.socket!!
            val socketOut = socket.outputStream
            val tunOut = FileOutputStream(pfd.fileDescriptor)
            val (stopRead, stopWrite) = Os.pipe().let { it[0] to it[1] }
            stopPipe = stopWrite
            lastReceived = SystemClock.elapsedRealtime()

            val tunToServer = Thread({ relayTunToServer(pfd.fileDescriptor, stopRead, socketOut, mySession, first.takeIf { reuse }) }, "tun-to-server")
            val serverToTun = Thread({ relayServerToTun(socket.inputStream, tunOut, mySession) }, "server-to-tun")
            relayThreads = listOf(tunToServer, serverToTun)
            tunToServer.start()
            serverToTun.start()

            reconnectAttempts = 0
            currentState = "UP"
            notifyState(name, "UP")
            VpnLogStore.log("Connected to $name")
        } catch (e: Exception) {
            Log.e(TAG, "connect failed", e)
            VpnLogStore.log("Connect to $name failed: ${e.message}")
            val fatal = e is AccessDeniedException || e is DataLimitException || e is UnclaimedInviteException ||
                e is ConfigParseException || e is IllegalArgumentException
            handleSessionEnded(mySession, name, if (fatal) e.message else null)
        } finally {
            releaseWakeLock()
        }
    }

    private fun establish(address: String, included: Set<String>) {
        val builder = Builder()
            .setSession("detour")
            .addAddress(address, 24)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .setMtu(1400)

        if (included.isEmpty()) builder.addDisallowedApplication(packageName)
        for (pkg in included) {
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
        val old = tunFd
        tunFd = pfd ?: throw IOException("VpnService.Builder.establish() returned null")
        tunAddress = address
        tunApps = included
        runCatching { old?.close() }
    }

    /** (configName, state) - invoked off the main thread; caller must post to UI. */
    private fun notifyState(name: String?, state: String) {
        stateListener?.invoke(name, state)
        VpnWidgetProvider.refreshAll(applicationContext)
    }

    private fun relayTunToServer(
        tun: FileDescriptor, stop: FileDescriptor, serverOut: OutputStream, session: Long, first: ByteArray?,
    ) {
        val buffer = ByteArray(32767)
        try {
            first?.let { writeFramedPacket(serverOut, it, it.size) }
            forEachPacket(tun, stop, buffer) { n ->
                writeFramedPacket(serverOut, buffer, n)
                trafficBytes.addAndGet(n.toLong())
                // Sending without hearing back may mean the connection is dead.
                if (SystemClock.elapsedRealtime() - lastReceived > QUIET_MS) checkConnection(holdAwake = false)
                true
            }
        } catch (e: Exception) {
            Log.i(TAG, "tun-to-server loop ended: ${e.message}")
        }
        runCatching { Os.close(stop) }
        handleSessionEnded(session, currentConfigName)
    }

    private fun relayServerToTun(serverIn: java.io.InputStream, tunOut: FileOutputStream, session: Long) {
        try {
            while (true) {
                val packet = readFramedPacket(serverIn)
                lastReceived = SystemClock.elapsedRealtime()
                if (packet.size < 20) { // a pong, not an IP packet
                    releaseWakeLock()
                    continue
                }
                tunOut.write(packet)
                trafficBytes.addAndGet(packet.size.toLong())
            }
        } catch (e: Exception) {
            Log.i(TAG, "server-to-tun loop ended: ${e.message}")
        }
        handleSessionEnded(session, currentConfigName)
    }

    /**
     * Called from any relay thread (or a failed connect attempt) when a
     * session ends. If a newer session has since taken over, this is just a
     * stale thread noticing we closed its socket on purpose - ignore it. If
     * the user asked to disconnect, honor that. Otherwise the connection died
     * on its own - keep retrying, less and less often; wakeUp() retries sooner
     * when the screen turns on or a network appears.
     */
    private fun handleSessionEnded(session: Long, name: String?, fatalError: String? = null) {
        // Multiple relay threads can notice the same dead session at once;
        // only the one that wins this CAS proceeds; a stale session (already
        // superseded by a newer doConnect) fails it too, since the value
        // will no longer be `session`.
        if (!sessionGeneration.compareAndSet(session, session + 1)) return

        if (userInitiatedDisconnect) {
            doDisconnect()
            return
        }

        if (fatalError != null || name == null) {
            currentState = "DOWN"
            currentConfigName = null
            notifyState(name, "ERROR:${fatalError ?: "Connection lost"}")
            VpnLogStore.log("Gave up on $name: ${fatalError ?: "Connection lost"}")
            cancelChecks()
            tearDown()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        val delay = RECONNECT_DELAYS_MS[min(reconnectAttempts, RECONNECT_DELAYS_MS.lastIndex)]
        reconnectAttempts++
        Log.w(TAG, "Session ended unexpectedly, reconnecting to $name in ${delay}ms (attempt $reconnectAttempts)")
        VpnLogStore.log("Connection to $name dropped, reconnecting in ${delay}ms (attempt $reconnectAttempts)")
        currentState = "RECONNECTING"
        notifyState(name, "RECONNECTING")
        val claimedGeneration = session + 1 // what we just CAS'd sessionGeneration to, above
        val retry = Runnable {
            // Only proceed if nothing newer has happened since we claimed
            // this retry (no manual reconnect, no other retry in flight).
            if (sessionGeneration.get() == claimedGeneration && !userInitiatedDisconnect) doConnect(name)
        }
        pendingRetry.set(retry)
        scheduler.schedule({
            if (pendingRetry.compareAndSet(retry, null)) executor.execute(retry)
        }, delay, TimeUnit.MILLISECONDS)
    }

    private fun doDisconnect() {
        val name = currentConfigName
        pendingRetry.set(null)
        cancelChecks()
        tearDown()
        currentState = "DOWN"
        currentConfigName = null
        notifyState(name, "DOWN")
        if (name != null) VpnLogStore.log("Disconnected from $name")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** Ends the server connection, and everything reading or writing the tun. */
    private fun closeSession() {
        stopPipe?.let { runCatching { Os.close(it) } }
        stopPipe = null
        client?.close()
        client = null
        // The tun must not be closed or reused while a thread may still be reading it.
        relayThreads.forEach { if (it !== Thread.currentThread()) it.join(1_000) }
        relayThreads = emptyList()
    }

    private fun tearDown() {
        closeSession()
        try {
            tunFd?.close()
        } catch (_: IOException) {
        }
        tunFd = null
    }

    private fun releaseWakeLock() {
        if (wakeLock.isHeld) runCatching { wakeLock.release() }
    }

    override fun onRevoke() {
        userInitiatedDisconnect = true
        doDisconnect()
        super.onRevoke()
    }

    override fun onDestroy() {
        userInitiatedDisconnect = true // the ending session must not schedule a retry
        cancelChecks()
        tearDown()
        releaseWakeLock()
        unregisterReceiver(screenReceiver)
        getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback)
        scheduler.shutdownNow()
        super.onDestroy()
    }

    private fun buildNotification(title: String): Notification {
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
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setSmallIcon(R.drawable.detour_notification)
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
        private const val IDLE_NOTIFICATION_ID = 2

        internal const val ACTION_ALARM = "com.detour.vpn.ALARM"
        private const val ALARM_INTERVAL_MS = 4 * 60_000L
        private const val MIN_ALARM_MS = 30_000L
        private const val CHECK_TIMEOUT_MS = 8_000L
        private const val CONNECT_WAKE_MS = 45_000L
        private const val QUIET_MS = 10_000L
        private const val STANDBY_LOOK_MS = 1_000L
        private val PING = byteArrayOf(1)
        private val RECONNECT_DELAYS_MS = longArrayOf(2_000, 4_000, 8_000, 16_000, 30_000, 60_000, 120_000, 300_000)

        /** "UP", "DOWN", "CONNECTING", "RECONNECTING", "STANDBY", or "ERROR:<message>" */
        @Volatile var currentState: String = "DOWN"
            private set

        @Volatile var currentConfigName: String? = null
            private set

        /** (configName, state) - invoked off the main thread; caller must post to UI. */
        var stateListener: ((String?, String) -> Unit)? = null
    }
}

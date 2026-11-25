package com.detour.vpn

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Process
import kotlin.math.max

internal data class UsageEvent(val time: Long, val type: Int, val packageName: String?, val className: String?)

/** Works out when any of the VPN's apps was last in use. Not thread-safe. */
internal class IdleTracker(private val ownPackage: String, startedAt: Long) {
    private val onScreen = mutableSetOf<String>()
    private var lastUse = startedAt
    private var trafficSince = startedAt

    /** Everything up to this time has been taken into account. */
    var seenUntil = startedAt - LOOK_BACK_MS
        private set

    /**
     * Takes in what happened since the last call and returns how long the apps
     * have been idle. [apps] empty means every app; [bytes] is the traffic since
     * the last call.
     */
    fun update(events: List<UsageEvent>, apps: Set<String>, bytes: Long, now: Long): Long {
        for (e in events) {
            val activity = "${e.packageName}/${e.className}"
            when (e.type) {
                UsageEvents.Event.ACTIVITY_RESUMED ->
                    if (apps.isEmpty() || e.packageName in apps || e.packageName == ownPackage) {
                        onScreen += activity
                        use(e.time)
                    }
                UsageEvents.Event.ACTIVITY_PAUSED, UsageEvents.Event.ACTIVITY_STOPPED ->
                    if (onScreen.remove(activity)) use(e.time)
                UsageEvents.Event.SCREEN_NON_INTERACTIVE -> {
                    if (onScreen.isNotEmpty()) use(e.time)
                    onScreen.clear()
                }
            }
        }
        seenUntil = now
        if (onScreen.isNotEmpty()) use(now)

        // Music, calls and downloads go on with the screen off.
        val elapsed = now - trafficSince
        if (elapsed > 0 && bytes * 60_000 / elapsed >= BUSY_BYTES_PER_MINUTE) use(now)
        trafficSince = now
        return now - lastUse
    }

    /** Whether a VPN app (not this one) is on screen, as of the last update. */
    fun vpnAppOnScreen() = onScreen.any { !it.startsWith("$ownPackage/") }

    private fun use(time: Long) {
        if (time > lastUse) lastUse = time
    }

    companion object {
        const val BUSY_BYTES_PER_MINUTE = 200_000L

        private const val MIN_CHECK_MS = 5_000L

        /** When to check again, given how long the apps have been [idle] so far. */
        fun nextCheckMs(idle: Long, limit: Long) = max(limit - idle, MIN_CHECK_MS)

        // An app may have been opened a while before the VPN connected.
        private const val LOOK_BACK_MS = 60 * 60_000L
    }
}

/** What to do when the VPN is not in use, and the usage access it depends on. */
internal class IdleStop(private val context: Context) {
    private val prefs = context.getSharedPreferences("detour_vpn", Context.MODE_PRIVATE)

    /** [OFF], [STOP] or [STANDBY]. */
    var action: String
        // Older versions only had stopping, as a switch.
        get() = prefs.getString(ACTION_KEY, null) ?: if (prefs.getBoolean(OLD_KEY, false)) STOP else OFF
        set(value) = prefs.edit().putString(ACTION_KEY, value).apply()

    var minutes: Int
        get() = prefs.getInt(MINUTES_KEY, DEFAULT_MINUTES)
        set(value) = prefs.edit().putInt(MINUTES_KEY, value.coerceIn(1, MAX_MINUTES)).apply()

    val limitMs get() = minutes * 60_000L

    fun hasUsageAccess(): Boolean {
        val ops = context.getSystemService(AppOpsManager::class.java)
        @Suppress("DEPRECATION")
        val mode = ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun events(from: Long, to: Long): List<UsageEvent> {
        val source = context.getSystemService(UsageStatsManager::class.java).queryEvents(from, to) ?: return emptyList()
        val result = mutableListOf<UsageEvent>()
        val event = UsageEvents.Event()
        while (source.getNextEvent(event)) {
            result += UsageEvent(event.timeStamp, event.eventType, event.packageName, event.className)
        }
        return result
    }

    companion object {
        const val OFF = "off"
        const val STOP = "stop"
        const val STANDBY = "standby"
        private const val ACTION_KEY = "idle_action"
        private const val OLD_KEY = "stop_when_idle"
        private const val MINUTES_KEY = "stop_when_idle_minutes"
        private const val DEFAULT_MINUTES = 5
        private const val MAX_MINUTES = 1440
    }
}

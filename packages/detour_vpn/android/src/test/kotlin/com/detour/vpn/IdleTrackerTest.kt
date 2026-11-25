package com.detour.vpn

import android.app.usage.UsageEvents.Event
import org.junit.Assert.assertEquals
import org.junit.Test

class IdleTrackerTest {
    private val min = 60_000L
    private val start = 100 * min
    private val tracker = IdleTracker("com.own", start)
    private val apps = setOf("com.chrome")

    private fun open(at: Long, pkg: String = "com.chrome", cls: String = "Main") = UsageEvent(start + at, Event.ACTIVITY_RESUMED, pkg, cls)
    private fun close(at: Long, pkg: String = "com.chrome", cls: String = "Main") = UsageEvent(start + at, Event.ACTIVITY_PAUSED, pkg, cls)
    private fun idle(at: Long, vararg e: UsageEvent, bytes: Long = 0, apps: Set<String> = this.apps) =
        tracker.update(e.toList(), apps, bytes, start + at)

    @Test fun countsFromConnecting() {
        assertEquals(4 * min, idle(4 * min))
        assertEquals(6 * min, idle(6 * min))
    }

    @Test fun anOpenAppIsInUseForAsLongAsItStaysOpen() {
        assertEquals(0, idle(4 * min, open(1 * min)))
        assertEquals(0, idle(60 * min))
        assertEquals(2 * min, idle(63 * min, close(61 * min)))
    }

    @Test fun anAppOpenedBeforeConnectingCounts() {
        assertEquals(start - 60 * min, tracker.seenUntil)
        assertEquals(0, idle(10 * min, open(-20 * min)))
    }

    @Test fun switchingScreensInsideAnAppKeepsItInUse() {
        assertEquals(0, idle(9 * min, open(1 * min, cls = "A"), open(2 * min, cls = "B"), close(2 * min, cls = "A")))
        assertEquals(1 * min, idle(10 * min, close(9 * min, cls = "B")))
    }

    @Test fun otherAppsDoNotCountButDetourDoes() {
        assertEquals(6 * min, idle(6 * min, open(1 * min, "com.other")))
        assertEquals(0, idle(7 * min, open(7 * min - 1, "com.own")))
    }

    @Test fun everyAppCountsWhenNoneIsSelected() {
        assertEquals(0, idle(6 * min, open(1 * min, "com.other"), apps = emptySet()))
    }

    @Test fun screenOffEndsUse() {
        val off = UsageEvent(start + 3 * min, Event.SCREEN_NON_INTERACTIVE, "android", null)
        assertEquals(5 * min, idle(8 * min, open(1 * min), off))
    }

    @Test fun steadyTrafficCountsButBackgroundSyncDoesNot() {
        assertEquals(4 * min, idle(4 * min, bytes = 4 * IdleTracker.BUSY_BYTES_PER_MINUTE - 4))
        assertEquals(0, idle(8 * min, bytes = 4 * IdleTracker.BUSY_BYTES_PER_MINUTE))
        assertEquals(5 * min, idle(13 * min))
    }

    @Test fun standbyWakesForVpnAppsOnly() {
        idle(1 * min, open(1, "com.own"), open(2, "com.other"))
        assertEquals(false, tracker.vpnAppOnScreen())
        idle(2 * min, open(2 * min))
        assertEquals(true, tracker.vpnAppOnScreen())
        idle(3 * min, close(3 * min))
        assertEquals(false, tracker.vpnAppOnScreen())
    }

    @Test fun checksAgainWhenTheLimitWouldBeReached() {
        assertEquals(1 * min, IdleTracker.nextCheckMs(0, 1 * min))
        assertEquals(20_000, IdleTracker.nextCheckMs(40_000, 1 * min))
        assertEquals(5_000, IdleTracker.nextCheckMs(1 * min - 1, 1 * min))
    }

    @Test fun oldEventsNeverMoveTimeBackwards() {
        idle(4 * min, open(3 * min), close(4 * min))
        assertEquals(2 * min, idle(6 * min, open(1 * min, cls = "X"), close(2 * min, cls = "X")))
    }
}

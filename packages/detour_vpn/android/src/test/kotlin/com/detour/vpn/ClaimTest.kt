package com.detour.vpn

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNotNull
import org.junit.Test

class ClaimTest {
    /** Runs against a real server when DETOUR_TEST_INVITE is an unused invite link. */
    @Test fun claimsAnInviteOnce() {
        val link = System.getenv("DETOUR_TEST_INVITE")
        assumeNotNull(link)
        val invite = parseConfig(link)
        val mine = invite.copy(password = "a".repeat(32))
        assertThrows(UnclaimedInviteException::class.java) { TunnelClient(invite).connectAndAuthenticate() }
        assertTrue(claimInvite(invite, mine.password))
        TunnelClient(mine).apply {
            connectAndAuthenticate()
            assertTrue(assignedAddress!!.startsWith("10.10.0."))
            close()
        }
        assertFalse(claimInvite(mine, "b".repeat(32)))
        val error = assertThrows(IOException::class.java) { claimInvite(invite, "c".repeat(32)) }
        assertEquals("This invite link was already used or cancelled", error.message)
    }
}

package com.detour.vpn

import java.io.File
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ConfigStoreTest {
    @get:Rule val folder = TemporaryFolder()

    private class FakeCipher(var broken: Boolean = false) : ConfigCipher {
        override fun encrypt(text: String) = ENCRYPTED_PREFIX + text.reversed()
        override fun decrypt(text: String) =
            if (broken) throw IllegalStateException() else text.removePrefix(ENCRYPTED_PREFIX).reversed()
    }

    private val cipher = FakeCipher()
    private val dir by lazy { folder.newFolder() }
    private val store by lazy { ConfigStore(dir, cipher) }
    private val config = TunnelConfig("", "16.0.0.1", 443, "ali", "invite-secret", "ab".repeat(32), emptyList())
    private val link = configLink(config)
    private fun file(name: String) = File(dir, "$name.conf")

    @Test fun claimsAnInviteAndStoresOnlyTheNewPassword() {
        var sent = ""
        store.importConfig("a", link) { c, new -> assertEquals("invite-secret", c.password); sent = new; true }
        assertTrue(sent.matches(Regex("[A-Za-z0-9]{32}")))
        assertEquals(config.copy(name = "a", password = sent), store.loadConfig("a"))
        assertTrue(file("a").readText().startsWith(ENCRYPTED_PREFIX))
        assertFalse(file("a").readText().contains(sent))
        store.importConfig("b", link) { _, new -> assertNotEquals(sent, new); true }
    }

    @Test fun keepsThePasswordWhenThereIsNothingToClaim() {
        store.importConfig("a", link) { _, _ -> false }
        assertEquals("invite-secret", store.loadConfig("a").password)
    }

    @Test fun savesNothingWhenClaimingFails() {
        assertThrows(IOException::class.java) { store.importConfig("a", link) { _, _ -> throw IOException("used") } }
        assertEquals(emptyList<String>(), store.listNames())
    }

    @Test fun doesNotUseUpAnInviteItCannotSave() {
        var asked = false
        assertThrows(ConfigParseException::class.java) { store.importConfig("../x", link) { _, _ -> asked = true; true } }
        cipher.broken = true
        assertThrows(IllegalStateException::class.java) { store.importConfig("a", link) { _, _ -> asked = true; true } }
        assertFalse(asked)
    }

    @Test fun encryptsOldFilesOnFirstLoad() {
        dir
        store
        val old = config.copy(includedApplications = listOf("com.a"))
        file("old").writeText(serializeConfig(old))
        repeat(2) { assertEquals(old.copy(name = "old"), store.loadConfig("old")) }
        assertTrue(file("old").readText().startsWith(ENCRYPTED_PREFIX))
        assertEquals(listOf("old"), store.listNames())
        assertEquals(listOf("old.conf"), dir.list()!!.toList())
    }

    @Test fun survivesEditsAndRename() {
        store.importConfig("a", link) { _, _ -> false }
        store.setIncludedApps("a", listOf("com.x"))
        store.renameConfig("a", "b")
        assertEquals(config.copy(name = "b", includedApplications = listOf("com.x")), store.loadConfig("b"))
        assertEquals(listOf("b"), store.listNames())
        assertTrue(file("b").readText().startsWith(ENCRYPTED_PREFIX))
    }

    @Test fun renameNeverOverwrites() {
        store.importConfig("a", link) { _, _ -> false }
        store.importConfig("b", link) { _, _ -> false }
        for (bad in listOf("b", "../x", "", ".c")) {
            assertThrows(bad, ConfigParseException::class.java) { store.renameConfig("a", bad) }
        }
        assertEquals(listOf("a", "b"), store.listNames())
    }

    @Test fun explainsAConfigFromAnotherDevice() {
        store.importConfig("a", link) { _, _ -> false }
        cipher.broken = true
        assertThrows(ConfigParseException::class.java) { store.loadConfig("a") }
    }
}

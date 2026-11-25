package com.detour.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ConfigParseTest {
    private val config = TunnelConfig("", "16.0.0.1", 443, "ali", "p+w/_-*x", "ab".repeat(32), listOf("com.a", "com.b"))
    private val text = serializeConfig(config)
    private fun check(s: String) = assertEquals(config, parseConfig(s))

    @Test fun plain() = check(text)
    @Test fun windowsNewlines() = check(text.replace("\n", "\r\n"))
    @Test fun invisibleDirectionMarks() = check(text.lines().joinToString("\n") { "‎⁨$it⁩" })
    @Test fun byteOrderMark() = check("﻿$text")
    @Test fun introInFront() = check("here it is:\n$text")
    @Test fun oneLine() = check(text.trim().replace("\n", " "))
    @Test fun oneLineWithIntro() = check("here: " + text.trim().replace("\n", " "))
    @Test fun nonBreakingSpaces() = check(text.replace(" ", " "))
    @Test fun lineSeparators() = check(text.trim().replace("\n", " "))

    private val shared = config.copy(name = "my server_1", includedApplications = emptyList())
    private val link = configLink(shared)

    @Test fun link() {
        assertEquals(shared, parseConfig(link))
        assertEquals(shared.copy(name = ""), parseConfig(configLink(shared.copy(name = ""))))
    }
    @Test fun linkInMessage() {
        assertEquals(shared, parseConfig("⁨Use this: $link⁩\nthanks"))
        assertEquals(shared, parseConfig("($link)"))
    }
    @Test fun linkWithOddValues() {
        for (c in listOf(
            shared.copy(host = "2001:db8::1"),
            shared.copy(host = "vpn.example.com", name = "خادم"),
            shared.copy(username = "a@b:c/d", password = "%41 +_*?#&=é"),
        )) {
            assertEquals(c, parseConfig(configLink(c)))
        }
    }
    @Test fun linkHasNoChatFormatting() = assertEquals(false, configLink(shared.copy(username = "a_b")).any { it in "_*~`" })
    @Test fun brokenLinks() {
        for (bad in listOf(link.take(60), link.replace(":443/", ":99999/"), link.replace("abab", "ab"), link.replace("p%2B", "p%2"))) {
            assertThrows(bad, ConfigParseException::class.java) { parseConfig(bad) }
        }
    }
    @Test fun oldCode() {
        val code = java.util.Base64.getEncoder().withoutPadding().encodeToString(text.toByteArray())
        check("detour:$code")
        assertThrows(ConfigParseException::class.java) { parseConfig("detour:${code.take(90)}") }
    }
    @Test fun passwordThatLooksLikeAField() {
        val odd = config.copy(password = "a;port:99")
        assertEquals(odd, parseConfig(serializeConfig(odd)))
    }

    @Test fun missingFields() {
        for (bad in listOf("", "hello", "host: a\nport: x")) {
            assertThrows(ConfigParseException::class.java) { parseConfig(bad) }
        }
    }
}

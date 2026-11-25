package com.detour.vpn

import android.content.Context
import java.io.File
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.Base64

/** A saved server profile for the simpletun TLS tunnel. */
data class TunnelConfig(
    val name: String,
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
    val fingerprint: String,
    val includedApplications: List<String>,
)

class ConfigParseException(message: String) : Exception(message)

private val LINK = Regex(
    """detour://([^:@/\s]+):([^@/\s]+)@(\[[0-9A-Fa-f:.]+]|[A-Za-z0-9.-]+):(\d{1,5})/""" +
        """([0-9A-Fa-f]{64})(?![0-9A-Fa-f])(?:\?name=([A-Za-z0-9%.+-]+))?"""
)
// Older app versions shared base64 codes instead of links.
private val CODE = Regex("""detour:([A-Za-z0-9+/]{40,})""")
private val FIELD = Regex("""(?i)(?<!\w)(host|port|username|password|fingerprint)\s*:\s*(\S+)""")
private val APPS = Regex("""(?i)(?<!\w)apps\s*:\s*([\w.]+(?:\s*,\s*[\w.]+)*)""")

/** Accepts a link from [configLink] or `key: value` text, tolerating what chat apps do to it. */
internal fun parseConfig(text: String): TunnelConfig {
    // Chat apps and right-to-left keyboards add invisible formatting characters.
    val clean = text.replace(Regex("""\p{Cf}"""), "").replace(Regex("[\r\u0085  ]"), "\n").replace(' ', ' ')
    if ("detour://" in clean) {
        return parseLink(clean) ?: throw ConfigParseException("This link is damaged or incomplete")
    }
    val code = CODE.find(clean)?.groupValues?.get(1)
    if (code != null) {
        val decoded = try {
            String(Base64.getDecoder().decode(code), Charsets.UTF_8)
        } catch (_: IllegalArgumentException) {
            throw ConfigParseException("This code is damaged or incomplete")
        }
        return parseLines(decoded)
    }
    return try {
        parseLines(clean)
    } catch (e: ConfigParseException) {
        // Newlines may have been lost, so look for the fields anywhere.
        val fields = FIELD.findAll(clean).map { "${it.groupValues[1]}: ${it.groupValues[2]}" }.toMutableList()
        if (fields.isEmpty()) throw ConfigParseException("This doesn't look like a Detour config")
        APPS.find(clean)?.let { fields += "apps: ${it.groupValues[1]}" }
        parseLines(fields.joinToString("\n"))
    }
}

private fun parseLink(clean: String): TunnelConfig? {
    val match = LINK.find(clean) ?: return null
    val (user, password, host, port, fingerprint, name) = match.destructured
    return try {
        TunnelConfig(
            name = URLDecoder.decode(name, "UTF-8"),
            host = host.removeSurrounding("[", "]"),
            port = port.toInt().also { require(it in 1..65535) },
            username = URLDecoder.decode(user, "UTF-8"),
            password = URLDecoder.decode(password, "UTF-8"),
            fingerprint = fingerprint.lowercase(),
            includedApplications = emptyList(),
        )
    } catch (_: IllegalArgumentException) {
        null
    }
}

/** A one-line link, without the app list. Not encrypted: it contains the password. */
internal fun configLink(config: TunnelConfig): String {
    // Chat apps treat _ and * as formatting.
    fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("_", "%5F").replace("*", "%2A")
    val host = if (':' in config.host) "[${config.host}]" else config.host
    val name = if (config.name.isEmpty()) "" else "?name=${enc(config.name)}"
    return "detour://${enc(config.username)}:${enc(config.password)}@$host:${config.port}/${config.fingerprint}$name"
}

private fun parseLines(text: String): TunnelConfig {
    val fields = mutableMapOf<String, String>()
    var apps: List<String> = emptyList()
    for (rawLine in text.lines()) {
        val line = rawLine.trim()
        if (line.isEmpty() || line.startsWith("#")) continue
        val idx = line.indexOf(':')
        if (idx <= 0) continue
        val key = line.substring(0, idx).trim().lowercase()
        val value = line.substring(idx + 1).trim()
        if (key == "apps") {
            apps = value.split(",").map { it.trim() }.filter { it.isNotEmpty() }
        } else {
            fields[key] = value
        }
    }

    val host = fields["host"] ?: throw ConfigParseException("Missing 'host'")
    val port = fields["port"]?.toIntOrNull() ?: throw ConfigParseException("Missing/invalid 'port'")
    val username = fields["username"] ?: throw ConfigParseException("Missing 'username'")
    val password = fields["password"] ?: throw ConfigParseException("Missing 'password'")
    val fingerprint = fields["fingerprint"] ?: throw ConfigParseException("Missing 'fingerprint'")

    return TunnelConfig(
        name = "",
        host = host,
        port = port,
        username = username,
        password = password,
        fingerprint = fingerprint.replace(":", "").lowercase(),
        includedApplications = apps,
    )
}

internal fun serializeConfig(config: TunnelConfig): String {
    val sb = StringBuilder()
    sb.appendLine("host: ${config.host}")
    sb.appendLine("port: ${config.port}")
    sb.appendLine("username: ${config.username}")
    sb.appendLine("password: ${config.password}")
    sb.appendLine("fingerprint: ${config.fingerprint}")
    sb.appendLine("apps: ${config.includedApplications.joinToString(",")}")
    return sb.toString()
}

/**
 * Persists tunnel profiles as simple `key: value` text files (one per config,
 * named `<name>.conf`) under the app's private storage. Deliberately not
 * reusing any VPN-protocol config format - this is a bespoke, minimal
 * client/server pair, so the config format is bespoke too.
 */
class ConfigStore(context: Context) {
    private val dir = File(context.filesDir, "tunnel_configs").apply { mkdirs() }

    // Names become file names.
    private fun checkName(name: String) {
        if (name.isBlank() || name.length > 40 || name.startsWith(".") || name.any { it == '/' || it.isISOControl() }) {
            throw ConfigParseException("Enter a name of up to 40 characters, without / or a leading dot")
        }
    }

    private fun fileFor(name: String) = File(dir, "$name.conf")

    @Throws(ConfigParseException::class)
    fun importConfig(name: String, text: String) {
        val config = parseConfig(text)
        checkName(name)
        fileFor(name).writeText(serializeConfig(config))
    }

    fun listNames(): List<String> {
        return dir.listFiles { f -> f.name.endsWith(".conf") }
            ?.map { it.name.removeSuffix(".conf") }
            ?.sorted()
            ?: emptyList()
    }

    @Throws(ConfigParseException::class)
    fun loadConfig(name: String): TunnelConfig {
        val file = fileFor(name)
        require(file.exists()) { "No such config: $name" }
        return parseConfig(file.readText()).copy(name = name)
    }

    fun deleteConfig(name: String) {
        fileFor(name).delete()
    }

    fun renameConfig(oldName: String, newName: String) {
        checkName(newName)
        val from = fileFor(oldName)
        require(from.exists()) { "No such config: $oldName" }
        from.copyTo(fileFor(newName), overwrite = true)
        from.delete()
    }

    /** Link for another [username] on the same server, ready to import. */
    fun configLinkFor(name: String, username: String, password: String): String =
        configLink(loadConfig(name).copy(username = username, password = password, includedApplications = emptyList()))

    @Throws(ConfigParseException::class)
    fun setIncludedApps(name: String, packages: List<String>) {
        val existing = loadConfig(name)
        fileFor(name).writeText(serializeConfig(existing.copy(includedApplications = packages)))
    }

    fun toMap(name: String): Map<String, Any?> {
        val config = loadConfig(name)
        return mapOf(
            "name" to name,
            "addresses" to emptyList<String>(),
            "includedApplications" to config.includedApplications,
            "endpointHost" to config.host,
            "endpointPort" to config.port,
        )
    }
}

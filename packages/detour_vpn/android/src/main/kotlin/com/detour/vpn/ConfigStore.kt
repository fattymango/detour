package com.detour.vpn

import android.content.Context
import java.io.File

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

/**
 * Persists tunnel profiles as simple `key: value` text files (one per config,
 * named `<name>.conf`) under the app's private storage. Deliberately not
 * reusing any VPN-protocol config format - this is a bespoke, minimal
 * client/server pair, so the config format is bespoke too.
 */
class ConfigStore(context: Context) {
    private val dir = File(context.filesDir, "tunnel_configs").apply { mkdirs() }

    private fun fileFor(name: String) = File(dir, "$name.conf")

    private fun parse(text: String): TunnelConfig {
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

    private fun serialize(config: TunnelConfig): String {
        val sb = StringBuilder()
        sb.appendLine("host: ${config.host}")
        sb.appendLine("port: ${config.port}")
        sb.appendLine("username: ${config.username}")
        sb.appendLine("password: ${config.password}")
        sb.appendLine("fingerprint: ${config.fingerprint}")
        sb.appendLine("apps: ${config.includedApplications.joinToString(",")}")
        return sb.toString()
    }

    @Throws(ConfigParseException::class)
    fun importConfig(name: String, text: String) {
        parse(text) // validate
        fileFor(name).writeText(text)
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
        return parse(file.readText()).copy(name = name)
    }

    fun deleteConfig(name: String) {
        fileFor(name).delete()
    }

    fun renameConfig(oldName: String, newName: String) {
        val from = fileFor(oldName)
        require(from.exists()) { "No such config: $oldName" }
        from.copyTo(fileFor(newName), overwrite = true)
        from.delete()
    }

    @Throws(ConfigParseException::class)
    fun setIncludedApps(name: String, packages: List<String>) {
        val existing = loadConfig(name)
        fileFor(name).writeText(serialize(existing.copy(includedApplications = packages)))
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

package com.detour.vpn

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * A small, capped log of VPN connection *events* (connect/disconnect/drop/
 * reconnect) for on-device troubleshooting - never traffic payload. Kept as
 * a bounded ring buffer in memory plus a capped text file so it survives app
 * restarts; both are rewritten wholesale on each append, which is fine at
 * this size (<=200 short lines).
 */
object VpnLogStore {
    private const val MAX_ENTRIES = 200
    private const val FILE_NAME = "vpn_logs.txt"
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)

    data class LogEntry(val timestampMillis: Long, val message: String)

    private val entries = ArrayDeque<LogEntry>(MAX_ENTRIES)
    private var logFile: File? = null

    @Synchronized
    fun init(context: Context) {
        if (logFile != null) return
        val file = File(context.filesDir, FILE_NAME)
        logFile = file
        if (file.exists()) {
            file.readLines().forEach { line ->
                val parts = line.split("|", limit = 2)
                if (parts.size == 2) {
                    val ts = parts[0].toLongOrNull() ?: return@forEach
                    entries.addLast(LogEntry(ts, parts[1]))
                }
            }
            while (entries.size > MAX_ENTRIES) entries.removeFirst()
        }
    }

    @Synchronized
    fun log(message: String) {
        val entry = LogEntry(System.currentTimeMillis(), message)
        entries.addLast(entry)
        while (entries.size > MAX_ENTRIES) entries.removeFirst()
        persist()
    }

    @Synchronized
    fun getAll(): List<LogEntry> = entries.toList()

    private fun persist() {
        val file = logFile ?: return
        try {
            file.writeText(entries.joinToString("\n") { "${it.timestampMillis}|${it.message}" })
        } catch (_: Exception) {
            // Best-effort - a failed write just means this entry isn't persisted,
            // it's still visible in-memory for the current process lifetime.
        }
    }

    fun formatTimestamp(millis: Long): String = dateFormat.format(Date(millis))
}

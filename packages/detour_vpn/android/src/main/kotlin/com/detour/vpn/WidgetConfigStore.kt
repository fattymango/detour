package com.detour.vpn

import android.content.Context
import java.io.File

/**
 * Persists the name of the last config connected to, so the home-screen
 * widget knows which profile to bring up - it has no picker UI of its own.
 */
class WidgetConfigStore(context: Context) {
    private val file = File(context.filesDir, "widget_last_config.conf")

    fun lastConfig(): String? = if (file.exists()) file.readText().trim().ifEmpty { null } else null

    fun setLastConfig(name: String) {
        file.writeText(name)
    }
}

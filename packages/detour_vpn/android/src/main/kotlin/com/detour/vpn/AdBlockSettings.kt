package com.detour.vpn

import android.content.Context
import java.io.File

/**
 * Persists the ad-block on/off toggle as a single small file, same
 * bespoke-key-value-file convention as [ConfigStore] - this repo has no
 * SharedPreferences usage anywhere, so a second storage mechanism would just
 * be inconsistency for no benefit.
 */
class AdBlockSettings(context: Context) {
    private val file = File(context.filesDir, "adblock_settings.conf")

    /** Applied to all apps by default. */
    fun isEnabled(): Boolean {
        if (!file.exists()) return true
        return file.readText().trim() != "false"
    }

    fun setEnabled(enabled: Boolean) {
        file.writeText(if (enabled) "true" else "false")
    }
}

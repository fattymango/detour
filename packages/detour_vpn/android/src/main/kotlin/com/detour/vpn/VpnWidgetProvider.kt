package com.detour.vpn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.widget.RemoteViews

/** Home-screen toggle for the last-connected config (see [WidgetConfigStore]). */
class VpnWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (id in appWidgetIds) updateWidget(context, appWidgetManager, id)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_TOGGLE) return

        val service = Intent(context, TunnelVpnService::class.java)
        if (TunnelVpnService.currentState != "DOWN") {
            context.startService(service.setAction(TunnelVpnService.ACTION_DISCONNECT))
            return
        }

        val names = ConfigStore(context).listNames()
        val target = WidgetConfigStore(context).lastConfig()?.takeIf { it in names } ?: names.singleOrNull()
        // Only the app can ask for VPN permission or let the user pick a config.
        if (target == null || VpnService.prepare(context) != null) {
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.let { context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            return
        }
        // Android refuses a plain startService() when no Activity is in front.
        context.startForegroundService(
            service.setAction(TunnelVpnService.ACTION_CONNECT)
                .putExtra(TunnelVpnService.EXTRA_CONFIG_NAME, target)
        )
    }

    companion object {
        private const val ACTION_TOGGLE = "com.detour.vpn.WIDGET_TOGGLE"

        fun refreshAll(context: Context) {
            // Null on devices without home-screen widgets.
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, VpnWidgetProvider::class.java))
            for (id in ids) updateWidget(context, manager, id)
        }

        private fun updateWidget(context: Context, manager: AppWidgetManager, id: Int) {
            val (background, label) = when (TunnelVpnService.currentState) {
                "UP" -> R.drawable.detour_widget_bg_connected to R.string.detour_widget_connected
                "CONNECTING", "RECONNECTING" ->
                    R.drawable.detour_widget_bg_connecting to R.string.detour_widget_connecting
                else -> R.drawable.detour_widget_bg_disconnected to R.string.detour_widget_disconnected
            }
            val views = RemoteViews(context.packageName, R.layout.detour_vpn_widget)
            views.setInt(R.id.detour_widget_icon, "setBackgroundResource", background)
            views.setContentDescription(R.id.detour_widget_icon, context.getString(label))
            views.setOnClickPendingIntent(
                R.id.detour_widget_icon,
                PendingIntent.getBroadcast(
                    context,
                    id,
                    Intent(context, VpnWidgetProvider::class.java).setAction(ACTION_TOGGLE),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            manager.updateAppWidget(id, views)
        }
    }
}

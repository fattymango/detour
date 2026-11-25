package com.detour.vpn

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlin.concurrent.thread
import org.json.JSONArray
import org.json.JSONObject

/**
 * Flutter plugin entry point: wires the `detour_vpn/vpn` method channel and
 * `detour_vpn/vpn/state` event channel to [TunnelVpnService]/[ConfigStore]/
 * [VpnLogStore]. Host apps only need to add this package as
 * a dependency - no manual MainActivity wiring required.
 */
class DetourVpnPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var appContext: Context
    private lateinit var configStore: ConfigStore
    private lateinit var idleStop: IdleStop
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var pendingNotificationResult: MethodChannel.Result? = null
    private var pendingPermissionResult: ((Boolean) -> Unit)? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        configStore = ConfigStore(appContext)
        idleStop = IdleStop(appContext)
        VpnLogStore.init(appContext)
        VpnWidgetProvider.refreshAll(appContext)
        TunnelVpnService.stateListener = { name, state ->
            mainHandler.post {
                eventSink?.success(mapOf("state" to state, "name" to name, "stats" to null))
            }
        }

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != VPN_PERMISSION_REQUEST_CODE) return false
        val granted = resultCode == Activity.RESULT_OK
        pendingPermissionResult?.invoke(granted)
        pendingPermissionResult = null
        return true
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST_CODE) return false
        pendingNotificationResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pendingNotificationResult = null
        return true
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        try {
            handle(call.method, args, result)
        } catch (e: Exception) {
            result.error("unexpected_error", e.message, null)
        }
    }

    private fun handle(method: String, args: Map<*, *>, result: MethodChannel.Result) {
        when (method) {
            "hasVpnPermission" -> result.success(VpnService.prepare(appContext) == null)

            "requestVpnPermission" -> {
                val host = activity
                val intent: Intent? = VpnService.prepare(appContext)
                if (intent == null) {
                    result.success(true)
                } else if (host == null) {
                    result.error("no_activity", "No activity to request VPN permission from", null)
                } else {
                    pendingPermissionResult = { granted -> result.success(granted) }
                    host.startActivityForResult(intent, VPN_PERMISSION_REQUEST_CODE)
                }
            }

            "requestNotificationPermission" -> {
                val host = activity
                val needed = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                if (!needed || host == null || pendingNotificationResult != null) {
                    result.success(!needed)
                } else {
                    pendingNotificationResult = result
                    host.requestPermissions(
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_REQUEST_CODE,
                    )
                }
            }

            "importConfig" -> {
                val name = args["name"] as String
                val text = args["text"] as String
                thread {
                    try {
                        configStore.importConfig(name, text, ::claimInvite)
                        mainHandler.post { result.success(null) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("bad_config", e.message ?: "Couldn't add this server", null) }
                    }
                }
            }

            "previewConfig" -> {
                try {
                    val config = parseConfig(args["text"] as String)
                    result.success(
                        mapOf(
                            "name" to config.name,
                            "includedApplications" to config.includedApplications,
                            "endpointHost" to config.host,
                            "endpointPort" to config.port,
                            "username" to config.username,
                        )
                    )
                } catch (e: ConfigParseException) {
                    result.error("bad_config", e.message ?: "Invalid tunnel config", null)
                }
            }

            "listConfigs" -> {
                try {
                    // Skips configs this device can't decrypt, which can only be added again.
                    result.success(configStore.listNames().mapNotNull { name -> runCatching { configStore.toMap(name) }.getOrNull() })
                } catch (e: Exception) {
                    result.error("list_failed", e.message, null)
                }
            }

            "deleteConfig" -> {
                configStore.deleteConfig(args["name"] as String)
                result.success(null)
            }

            "renameConfig" -> {
                try {
                    configStore.renameConfig(args["oldName"] as String, args["newName"] as String)
                    result.success(null)
                } catch (e: ConfigParseException) {
                    result.error("bad_name", e.message, null)
                }
            }

            "setIncludedApps" -> {
                val name = args["name"] as String
                val packages = (args["packages"] as? List<Any?>)?.map { it.toString() } ?: emptyList()
                try {
                    configStore.setIncludedApps(name, packages)
                    // If this config is the one currently connected, re-establish the
                    // tunnel immediately so the new app selection takes effect live
                    // instead of only on the next manual connect.
                    if (TunnelVpnService.currentState in listOf("UP", "STANDBY") && TunnelVpnService.currentConfigName == name) {
                        val intent = Intent(appContext, TunnelVpnService::class.java)
                            .setAction(TunnelVpnService.ACTION_CONNECT)
                            .putExtra(TunnelVpnService.EXTRA_CONFIG_NAME, name)
                        appContext.startService(intent)
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("set_apps_failed", e.message, null)
                }
            }

            "adminRequest" -> {
                val name = args["name"] as String
                val op = args["op"] as String
                val username = args["username"] as? String ?: ""
                thread {
                    try {
                        val request = JSONObject().put("op", op).put("username", username)
                            .put("speedKbps", (args["speedKbps"] as? Number)?.toLong() ?: 0L)
                            .put("quotaBytes", (args["quotaBytes"] as? Number)?.toLong() ?: 0L)
                        val reply = JSONObject(sendAdminRequest(configStore.loadConfig(name), request.toString()))
                        val error = reply.optString("error")
                        val password = reply.optString("password")
                        val users = reply.optJSONArray("users") ?: JSONArray()
                        val value = mapOf(
                            "users" to List(users.length()) { i ->
                                val u = users.getJSONObject(i)
                                mapOf(
                                    "username" to u.getString("username"),
                                    "admin" to u.getBoolean("admin"),
                                    "invite" to u.optBoolean("invite"),
                                    "connected" to u.getInt("connected"),
                                    "speedKbps" to u.optLong("speedKbps"),
                                    "quotaBytes" to u.optLong("quotaBytes"),
                                    "usedBytes" to u.optLong("usedBytes"),
                                )
                            },
                            "config" to if (password.isEmpty()) null else configStore.configLinkFor(name, username, password),
                        )
                        mainHandler.post {
                            if (error.isEmpty()) result.success(value) else result.error("admin_failed", error, null)
                        }
                    } catch (e: Exception) {
                        val code = if (e is AccessDeniedException) "admin_failed" else "unreachable"
                        mainHandler.post { result.error(code, e.message ?: "Request failed", null) }
                    }
                }
            }

            "connect" -> {
                val name = args["name"] as String
                val intent = Intent(appContext, TunnelVpnService::class.java)
                    .setAction(TunnelVpnService.ACTION_CONNECT)
                    .putExtra(TunnelVpnService.EXTRA_CONFIG_NAME, name)
                appContext.startService(intent)
                result.success(null)
            }

            "disconnect" -> {
                val intent = Intent(appContext, TunnelVpnService::class.java)
                    .setAction(TunnelVpnService.ACTION_DISCONNECT)
                appContext.startService(intent)
                result.success(null)
            }

            "getVpnLogs" -> {
                val logs = VpnLogStore.getAll().reversed().map {
                    mapOf(
                        "timestamp" to VpnLogStore.formatTimestamp(it.timestampMillis),
                        "message" to it.message,
                    )
                }
                result.success(logs)
            }

            "getState" -> {
                result.success(
                    mapOf(
                        "state" to TunnelVpnService.currentState,
                        "name" to TunnelVpnService.currentConfigName,
                        "stats" to null,
                    )
                )
            }

            "getLastConfig" -> result.success(WidgetConfigStore(appContext).lastConfig())

            "getIdleAction" -> result.success(if (idleStop.hasUsageAccess()) idleStop.action else IdleStop.OFF)

            "setIdleAction" -> {
                idleStop.action = args["action"] as String
                recheckIdle()
                result.success(null)
            }

            "getIdleMinutes" -> result.success(idleStop.minutes)

            "setIdleMinutes" -> {
                idleStop.minutes = args["minutes"] as Int
                recheckIdle()
                result.success(null)
            }

            "hasUsageAccess" -> result.success(idleStop.hasUsageAccess())

            "requestUsageAccess" -> {
                appContext.startActivity(
                    Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                result.success(null)
            }

            "hasBatteryExemption" -> {
                val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(powerManager.isIgnoringBatteryOptimizations(appContext.packageName))
            }

            "requestBatteryExemption" -> {
                appContext.startActivity(
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        .setData(Uri.parse("package:${appContext.packageName}"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /** Lets a running VPN reschedule its next check. */
    private fun recheckIdle() {
        if (TunnelVpnService.currentState == "DOWN") return
        appContext.startService(Intent(appContext, TunnelVpnService::class.java).setAction(TunnelVpnService.ACTION_ALARM))
    }

    private companion object {
        const val METHOD_CHANNEL = "detour_vpn/vpn"
        const val EVENT_CHANNEL = "detour_vpn/vpn/state"
        const val VPN_PERMISSION_REQUEST_CODE = 5100
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 5101
    }
}

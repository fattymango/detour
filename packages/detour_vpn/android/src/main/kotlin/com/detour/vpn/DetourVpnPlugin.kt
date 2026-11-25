package com.detour.vpn

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService
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
    PluginRegistry.ActivityResultListener {

    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var appContext: Context
    private lateinit var configStore: ConfigStore
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var pendingPermissionResult: ((Boolean) -> Unit)? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        configStore = ConfigStore(appContext)
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
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
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

            "importConfig" -> {
                val name = args["name"] as String
                val text = args["text"] as String
                try {
                    configStore.importConfig(name, text)
                    result.success(null)
                } catch (e: ConfigParseException) {
                    result.error("bad_config", e.message ?: "Invalid tunnel config", null)
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
                    result.success(configStore.listNames().map { configStore.toMap(it) })
                } catch (e: Exception) {
                    result.error("list_failed", e.message, null)
                }
            }

            "deleteConfig" -> {
                configStore.deleteConfig(args["name"] as String)
                result.success(null)
            }

            "renameConfig" -> {
                configStore.renameConfig(args["oldName"] as String, args["newName"] as String)
                result.success(null)
            }

            "setIncludedApps" -> {
                val name = args["name"] as String
                val packages = (args["packages"] as? List<Any?>)?.map { it.toString() } ?: emptyList()
                try {
                    configStore.setIncludedApps(name, packages)
                    // If this config is the one currently connected, re-establish the
                    // tunnel immediately so the new app selection takes effect live
                    // instead of only on the next manual connect.
                    if (TunnelVpnService.currentState == "UP" && TunnelVpnService.currentConfigName == name) {
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

    private companion object {
        const val METHOD_CHANNEL = "detour_vpn/vpn"
        const val EVENT_CHANNEL = "detour_vpn/vpn/state"
        const val VPN_PERMISSION_REQUEST_CODE = 5100
    }
}

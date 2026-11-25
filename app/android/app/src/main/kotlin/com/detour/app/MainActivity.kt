package com.detour.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "detour/share").setMethodCallHandler { call, result ->
            if (call.method != "text") return@setMethodCallHandler result.notImplemented()
            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, call.arguments as String)
            startActivity(Intent.createChooser(send, null))
            result.success(null)
        }
    }
}

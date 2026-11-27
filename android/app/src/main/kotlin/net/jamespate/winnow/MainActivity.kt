package net.jamespate.winnow

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Media management access (Android 12+): lets Winnow move photos to the trash without a confirm each time.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "winnow/media").setMethodCallHandler { call, result ->
            when (call.method) {
                "canManageMedia" ->
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && MediaStore.canManageMedia(this))
                "openManageMedia" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        startActivity(Intent(Settings.ACTION_REQUEST_MANAGE_MEDIA, Uri.parse("package:$packageName")))
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}

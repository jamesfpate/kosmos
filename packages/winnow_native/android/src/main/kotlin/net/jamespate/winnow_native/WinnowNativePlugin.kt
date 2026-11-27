package net.jamespate.winnow_native

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Media management access and Google authorization, for the app and the background upload engine. */
class WinnowNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var binding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "winnow_native")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canManageMedia" ->
                result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && MediaStore.canManageMedia(context))
            "openManageMedia" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val i = Intent(Settings.ACTION_REQUEST_MANAGE_MEDIA, Uri.parse("package:${context.packageName}"))
                    val activity = binding?.activity
                    if (activity != null) activity.startActivity(i)
                    else context.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                result.success(null)
            }
            "googleToken" -> googleToken(call, result)
            "openApp" -> {
                val i = context.packageManager.getLaunchIntentForPackage(call.argument<String>("package")!!)
                if (i != null) context.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(i != null)
            }
            else -> result.notImplemented()
        }
    }

    private fun googleToken(call: MethodCall, result: MethodChannel.Result) {
        val scopes = call.argument<List<String>>("scopes")!!.map { Scope(it) }
        val interactive = call.argument<Boolean>("interactive") ?: false
        val activity: Activity? = binding?.activity
        val client = if (activity != null) Identity.getAuthorizationClient(activity) else Identity.getAuthorizationClient(context)
        client.authorize(AuthorizationRequest.builder().setRequestedScopes(scopes).build())
            .addOnSuccessListener { r ->
                if (!r.hasResolution()) {
                    result.success(r.accessToken)
                } else if (!interactive || activity == null) {
                    result.success(null)
                } else {
                    pending = result
                    try {
                        activity.startIntentSenderForResult(r.pendingIntent!!.intentSender, REQUEST, null, 0, 0, 0, null)
                    } catch (e: Exception) {
                        pending = null
                        result.error("google", e.message, null)
                    }
                }
            }
            .addOnFailureListener { e -> result.error("google", e.message, null) }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        val result = pending ?: return true
        pending = null
        val activity = binding?.activity
        if (resultCode != Activity.RESULT_OK || activity == null) {
            result.success(null)
            return true
        }
        try {
            result.success(Identity.getAuthorizationClient(activity).getAuthorizationResultFromIntent(data).accessToken)
        } catch (e: Exception) {
            result.error("google", e.message, null)
        }
        return true
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        binding = b
        b.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)

    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding = null
    }

    companion object {
        private const val REQUEST = 7311
    }
}

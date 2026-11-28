package net.jamespate.winnow_native

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
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

/**
 * Media management access, Google authorization, and phone albums (Android galleries such as Samsung's show each
 * folder as an album, so an album here is the folder Pictures/<name>/ and filing a photo moves it there).
 */
class WinnowNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var binding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null
    private var writeGranted: ((Boolean) -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())

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
            "openUrl" -> {
                val i = Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url")!!))
                val activity = binding?.activity
                if (activity != null) activity.startActivity(i) else context.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(null)
            }
            "openApp" -> {
                val i = context.packageManager.getLaunchIntentForPackage(call.argument<String>("package")!!)
                if (i != null) context.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(i != null)
            }
            "albumEnsure" -> background(result) {
                val path = folderFor(call.argument<String>("title")!!)
                val known = call.argument<String>("known")
                // An album that was already on the phone (DCIM/Hawaii, say) stays where it is under the same name.
                if (known != null && known.trimEnd('/').substringAfterLast('/') == path.trimEnd('/').substringAfterLast('/')) return@background known
                // A renamed album: everything in the old folder moves to the new one.
                if (known != null && known != path) move(idsIn(known), path)
                path
            }
            "albumList" -> background(result) { folderAlbums() }
            "albumAdd" -> background(result) {
                move(call.argument<List<String>>("assets")!!.map { it.toLong() }, call.argument<String>("album")!!)
                null
            }
            // A photo leaves an album by moving into another one (albumAdd); nothing to do here.
            "albumRemove" -> result.success(null)
            "assetExists" -> background(result) { mediaUri(call.argument<String>("id")!!.toLong()) != null }
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

    /** Runs [work] off the main thread and answers on it. */
    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val v = work()
                main.post { result.success(v) }
            } catch (e: Exception) {
                main.post { result.error("albums", e.message, null) }
            }
        }.start()
    }

    /** The folder for an album title: Pictures/<title>/ (slashes and other unsafe characters replaced). */
    private fun folderFor(title: String): String {
        val safe = title.replace(Regex("[/\\\\:*?\"<>|]"), "-").trim().ifEmpty { "Album" }
        return "${android.os.Environment.DIRECTORY_PICTURES}/$safe/"
    }

    /** The photo or video [id] in its own collection (write requests want those), or null when it's gone. */
    private fun mediaUri(id: Long): Uri? {
        val files = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        context.contentResolver.query(files, arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE),
            "${MediaStore.Files.FileColumns._ID}=?", arrayOf(id.toString()), null)?.use { c ->
            if (!c.moveToFirst()) return null
            return when (c.getInt(0)) {
                MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE -> ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
                MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
                else -> null
            }
        }
        return null
    }

    /**
     * Folders directly in Pictures/ or DCIM/ that hold photos or videos: the albums Samsung Gallery and other gallery
     * apps show, the same kind Winnow makes. The camera's own folder, screenshots and hidden folders are left out.
     * Each with when its first and last photo was taken.
     */
    private fun folderAlbums(): List<Map<String, Any>> =
        listOf(android.os.Environment.DIRECTORY_PICTURES, android.os.Environment.DIRECTORY_DCIM).flatMap { folderAlbums("$it/") }

    private fun folderAlbums(root: String): List<Map<String, Any>> {
        val skip = setOf("camera", "screenshots", "screen recordings", "screenrecorder", "restored")
        val found = linkedMapOf<String, LongArray>()
        val files = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        context.contentResolver.query(files,
            arrayOf(MediaStore.MediaColumns.RELATIVE_PATH, MediaStore.MediaColumns.DATE_TAKEN),
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? AND ${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?,?)",
            arrayOf("$root%", MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(), MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()),
            null)?.use { c ->
            while (c.moveToNext()) {
                val path = c.getString(0) ?: continue
                val name = path.removePrefix(root).trimEnd('/')
                if (name.isEmpty() || name.contains('/') || name.startsWith(".") || name.lowercase() in skip) continue
                val t = if (c.isNull(1)) 0L else c.getLong(1)
                val r = found.getOrPut(path) { longArrayOf(Long.MAX_VALUE, 0L) }
                if (t > 0) {
                    r[0] = minOf(r[0], t)
                    r[1] = maxOf(r[1], t)
                }
            }
        }
        return found.map { (path, r) ->
            buildMap {
                put("id", path)
                put("title", path.removePrefix(root).trimEnd('/'))
                if (r[1] > 0) {
                    put("start", r[0])
                    put("end", r[1])
                }
            }
        }
    }

    /** Photos and videos in a folder (relative path, ending in /). */
    private fun idsIn(path: String): List<Long> {
        val ids = mutableListOf<Long>()
        val files = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        context.contentResolver.query(files, arrayOf(MediaStore.Files.FileColumns._ID),
            "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?,?)",
            arrayOf(path, MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(), MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()),
            null)?.use { c -> while (c.moveToNext()) ids.add(c.getLong(0)) }
        return ids
    }

    /**
     * Moves photos into [path]. Ones Winnow may not change yet (taken by the camera app) need a write grant: with
     * media management allowed it's given without asking, otherwise Android asks once for the batch. That needs the
     * app on screen, so a move from the background fails and is retried on the next sync with Winnow open.
     */
    private fun move(ids: List<Long>, path: String) {
        val values = ContentValues().apply { put(MediaStore.MediaColumns.RELATIVE_PATH, path) }
        val needGrant = mutableListOf<Uri>()
        for (id in ids) {
            val uri = mediaUri(id) ?: continue
            try {
                context.contentResolver.update(uri, values, null, null)
            } catch (e: SecurityException) {
                if (e !is RecoverableSecurityException && Build.VERSION.SDK_INT < Build.VERSION_CODES.R) throw e
                needGrant.add(uri)
            }
        }
        if (needGrant.isEmpty()) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) throw Exception("Android 11 or later is needed to move photos")
        // In batches: one write request with thousands of photos is too big to hand to the system.
        for (batch in needGrant.chunked(BATCH)) {
            if (!askToWrite(batch)) throw Exception("Winnow wasn't allowed to move the photos into the album folder")
            for (uri in batch) context.contentResolver.update(uri, values, null, null)
        }
    }

    /** Asks for write access to [uris] (on the main thread) and waits for the answer. */
    private fun askToWrite(uris: List<Uri>): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val lock = Object()
        var answer: Boolean? = null
        main.post {
            val activity = binding?.activity
            if (activity == null) {
                synchronized(lock) { answer = false; lock.notifyAll() }
                return@post
            }
            writeGranted = { ok -> synchronized(lock) { answer = ok; lock.notifyAll() } }
            try {
                val pi = MediaStore.createWriteRequest(context.contentResolver, uris)
                activity.startIntentSenderForResult(pi.intentSender, WRITE, null, 0, 0, 0, null)
            } catch (e: Exception) {
                writeGranted = null
                synchronized(lock) { answer = false; lock.notifyAll() }
            }
        }
        synchronized(lock) { while (answer == null) lock.wait() }
        return answer!!
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == WRITE) {
            val done = writeGranted
            writeGranted = null
            done?.invoke(resultCode == Activity.RESULT_OK)
            return true
        }
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
        private const val WRITE = 7312
        private const val BATCH = 500
    }
}

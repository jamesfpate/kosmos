package net.jamespate.kosmos;

import android.Manifest;
import android.app.Activity;
import android.app.PendingIntent;
import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.ImageDecoder;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import android.provider.Settings;
import android.util.Size;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.IntentSenderRequest;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.core.content.ContextCompat;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * MediaStore access for the web app: list photos/videos, render previews into the cache dir (loaded by the
 * WebView through Capacitor.convertFileSrc), open a video in the system player, and move items to the system
 * trash (MediaStore.createTrashRequest: one confirm dialog per batch, recoverable for 30 days).
 */
@CapacitorPlugin(
    name = "Media",
    permissions = {
        @Permission(alias = "media", strings = { Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO }),
        @Permission(alias = "legacy", strings = { Manifest.permission.READ_EXTERNAL_STORAGE })
    }
)
public class MediaPlugin extends Plugin {

    private static final String USER_SELECTED = "android.permission.READ_MEDIA_VISUAL_USER_SELECTED";

    private final ExecutorService previews = Executors.newFixedThreadPool(3);
    private ActivityResultLauncher<IntentSenderRequest> trashLauncher;
    private PluginCall pendingTrash;

    @Override
    public void load() {
        // Must be registered before the activity is started; plugins load during BridgeActivity.onCreate.
        trashLauncher = getActivity().registerForActivityResult(
            new ActivityResultContracts.StartIntentSenderForResult(),
            result -> {
                PluginCall call = pendingTrash;
                pendingTrash = null;
                if (call == null) return;
                JSObject ret = new JSObject();
                ret.put("confirmed", result.getResultCode() == Activity.RESULT_OK);
                call.resolve(ret);
            }
        );
    }

    private String alias() {
        return Build.VERSION.SDK_INT >= 33 ? "media" : "legacy";
    }

    /** "granted", "limited" (Android 14+ "selected photos only"), "prompt" or "denied". */
    private String access() {
        if (getPermissionState(alias()) == PermissionState.GRANTED) return "granted";
        if (Build.VERSION.SDK_INT >= 34 &&
            ContextCompat.checkSelfPermission(getContext(), USER_SELECTED) == PackageManager.PERMISSION_GRANTED) {
            return "limited";
        }
        PermissionState s = getPermissionState(alias());
        return s == PermissionState.DENIED ? "denied" : "prompt";
    }

    @PluginMethod
    public void getAccess(PluginCall call) {
        JSObject ret = new JSObject();
        ret.put("access", access());
        call.resolve(ret);
    }

    @PluginMethod
    public void requestAccess(PluginCall call) {
        requestPermissionForAlias(alias(), call, "accessCallback");
    }

    @PermissionCallback
    private void accessCallback(PluginCall call) {
        getAccess(call);
    }

    @PluginMethod
    public void openSettings(PluginCall call) {
        Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", getContext().getPackageName(), null));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        getContext().startActivity(intent);
        call.resolve();
    }

    /** JS numbers arrive as Integer or Long depending on size; PluginCall.getLong only accepts Long. */
    private static Long idOf(PluginCall call) {
        Object v = call.getData().opt("id");
        return v instanceof Number ? ((Number) v).longValue() : null;
    }

    private static Uri itemUri(long id, boolean video) {
        return ContentUris.withAppendedId(
            video ? MediaStore.Video.Media.EXTERNAL_CONTENT_URI : MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id);
    }

    // YYYYMMDD, optionally followed by _HHMMSS / -HHMMSS (PXL_20241005_123456789, IMG-20240827-WA0000, Screenshot_20240101-101010).
    private static final Pattern NAME_DATE = Pattern.compile("(20\\d{2})(\\d{2})(\\d{2})(?:[_-](\\d{2})(\\d{2})(\\d{2}))?");

    /**
     * When the photo was taken: DATE_TAKEN (EXIF), else a date in the file name (WhatsApp and many apps strip EXIF),
     * else the earlier of modified/added (added alone is the day the file reached this phone).
     */
    private static long takenOf(Cursor c) {
        if (!c.isNull(3) && c.getLong(3) > 0) return c.getLong(3);
        String name = c.getString(9);
        if (name != null) {
            Matcher m = NAME_DATE.matcher(name);
            if (m.find()) {
                try {
                    int mo = Integer.parseInt(m.group(2)), d = Integer.parseInt(m.group(3));
                    if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
                        Calendar cal = Calendar.getInstance();
                        cal.clear();
                        cal.set(Integer.parseInt(m.group(1)), mo - 1, d,
                            m.group(4) == null ? 12 : Integer.parseInt(m.group(4)),
                            m.group(5) == null ? 0 : Integer.parseInt(m.group(5)),
                            m.group(6) == null ? 0 : Integer.parseInt(m.group(6)));
                        long t = cal.getTimeInMillis();
                        if (t <= System.currentTimeMillis() + 86_400_000L) return t;
                    }
                } catch (NumberFormatException ignored) {
                }
            }
        }
        long added = c.getLong(4) * 1000L;
        long modified = c.isNull(12) ? 0 : c.getLong(12) * 1000L;
        return modified > 0 && modified < added ? modified : added;
    }

    /** Every image and video on the device (trashed items are excluded by MediaStore), oldest first. */
    @PluginMethod
    public void list(PluginCall call) {
        String[] projection = {
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.DURATION,
            MediaStore.MediaColumns.ORIENTATION,
            MediaStore.MediaColumns.DATE_MODIFIED,
        };
        String selection = MediaStore.Files.FileColumns.MEDIA_TYPE + " IN (" +
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE + "," + MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO + ")";
        JSArray items = new JSArray();
        ContentResolver resolver = getContext().getContentResolver();
        try (Cursor c = resolver.query(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), projection,
                selection, null, MediaStore.MediaColumns.DATE_TAKEN + " ASC")) {
            if (c != null) {
                while (c.moveToNext()) {
                    boolean video = c.getInt(1) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO;
                    long taken = takenOf(c);
                    JSObject o = new JSObject();
                    o.put("id", c.getLong(0));
                    o.put("type", video ? "video" : "image");
                    o.put("mime", c.getString(2));
                    o.put("taken", taken);
                    // WIDTH/HEIGHT are as stored; a 90/270 rotation means the photo shows the other way round.
                    int rot = c.isNull(11) ? 0 : c.getInt(11);
                    boolean turned = rot == 90 || rot == 270;
                    o.put("width", c.getInt(turned ? 6 : 5));
                    o.put("height", c.getInt(turned ? 5 : 6));
                    o.put("size", c.getLong(7));
                    o.put("bucket", c.getString(8));
                    o.put("name", c.getString(9));
                    o.put("duration", c.isNull(10) ? 0 : c.getLong(10));
                    items.put(o);
                }
            }
        } catch (Exception e) {
            call.reject("MediaStore query failed: " + e.getMessage(), e);
            return;
        }
        JSObject ret = new JSObject();
        ret.put("items", items);
        call.resolve(ret);
    }

    /**
     * Renders a JPEG preview (long side <= size) into cache/previews and returns its path. Images are decoded
     * with ImageDecoder (applies EXIF rotation); videos use the MediaStore thumbnail (a frame).
     */
    @PluginMethod
    public void preview(PluginCall call) {
        Long id = idOf(call);
        boolean video = "video".equals(call.getString("type"));
        Object sizeArg = call.getData().opt("size");
        int size = sizeArg instanceof Number ? ((Number) sizeArg).intValue() : 1600;
        if (id == null) {
            call.reject("id is required");
            return;
        }
        previews.execute(() -> {
            try {
                File dir = new File(getContext().getCacheDir(), "previews");
                dir.mkdirs();
                File out = new File(dir, id + "_" + size + ".jpg");
                if (!out.exists()) {
                    Uri uri = itemUri(id, video);
                    Bitmap bmp;
                    if (video || size <= 512) {
                        bmp = getContext().getContentResolver().loadThumbnail(uri, new Size(size, size), null);
                    } else {
                        ImageDecoder.Source src = ImageDecoder.createSource(getContext().getContentResolver(), uri);
                        bmp = ImageDecoder.decodeBitmap(src, (decoder, info, s) -> {
                            int w = info.getSize().getWidth(), h = info.getSize().getHeight();
                            float scale = Math.min(1f, (float) size / Math.max(w, h));
                            decoder.setTargetSize(Math.max(1, Math.round(w * scale)), Math.max(1, Math.round(h * scale)));
                            decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);
                        });
                    }
                    File tmp = new File(dir, out.getName() + ".tmp");
                    try (FileOutputStream fos = new FileOutputStream(tmp)) {
                        bmp.compress(Bitmap.CompressFormat.JPEG, 85, fos);
                    }
                    bmp.recycle();
                    if (!tmp.renameTo(out)) throw new Exception("rename failed");
                }
                JSObject ret = new JSObject();
                ret.put("path", out.getAbsolutePath());
                call.resolve(ret);
            } catch (Exception e) {
                android.util.Log.e("Kosmos", "preview " + id + " failed", e);
                call.reject("preview failed: " + e, e);
            }
        });
    }

    /** Opens the item in the system viewer (used to play videos). */
    @PluginMethod
    public void open(PluginCall call) {
        Long id = idOf(call);
        String type = call.getString("type", "image");
        if (id == null) {
            call.reject("id is required");
            return;
        }
        Intent intent = new Intent(Intent.ACTION_VIEW);
        intent.setDataAndType(itemUri(id, "video".equals(type)), call.getString("mime", "video".equals(type) ? "video/*" : "image/*"));
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            getContext().startActivity(intent);
            call.resolve();
        } catch (Exception e) {
            call.reject("no app can open this: " + e.getMessage(), e);
        }
    }

    /** Moves items to the system trash after one system confirm dialog. Resolves { confirmed }. */
    @PluginMethod
    public void trash(PluginCall call) {
        JSArray arr = call.getArray("items");
        List<Uri> uris = new ArrayList<>();
        try {
            for (int i = 0; i < arr.length(); i++) {
                org.json.JSONObject o = arr.getJSONObject(i);
                uris.add(itemUri(o.getLong("id"), "video".equals(o.optString("type"))));
            }
        } catch (Exception e) {
            call.reject("bad items: " + e.getMessage(), e);
            return;
        }
        if (uris.isEmpty()) {
            JSObject ret = new JSObject();
            ret.put("confirmed", true);
            call.resolve(ret);
            return;
        }
        if (pendingTrash != null) {
            call.reject("a trash request is already open");
            return;
        }
        PendingIntent pi = MediaStore.createTrashRequest(getContext().getContentResolver(), uris, true);
        pendingTrash = call;
        getActivity().runOnUiThread(() ->
            trashLauncher.launch(new IntentSenderRequest.Builder(pi.getIntentSender()).build()));
    }
}

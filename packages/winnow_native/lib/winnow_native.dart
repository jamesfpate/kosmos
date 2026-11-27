import 'dart:io';

import 'package:flutter/services.dart';

/// Winnow's native calls: Android (registered as a plugin, so they also work in the background upload task) and macOS.
class WinnowNative {
  static const _channel = MethodChannel('winnow_native');

  /// Android's "media management" special access: trash without a confirm dialog each time.
  static Future<bool> canManageMedia() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canManageMedia') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openManageMedia() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('openManageMedia');
  }

  /// A Google access token for [scopes]. [interactive]: may show the account picker / consent screen (needs the app
  /// on screen); otherwise returns null when the user would have to be asked.
  static Future<String?> googleToken(List<String> scopes, {bool interactive = false}) =>
      _channel.invokeMethod<String>('googleToken', {'scopes': scopes, 'interactive': interactive});

  /// Opens another app by package name. False when it isn't installed.
  static Future<bool> openApp(String package) async =>
      Platform.isAndroid && (await _channel.invokeMethod<bool>('openApp', {'package': package}) ?? false);

  /// Opens a web page in the browser.
  static Future<void> openUrl(String url) async {
    if (Platform.isAndroid || Platform.isMacOS) return _channel.invokeMethod<void>('openUrl', {'url': url});
    if (Platform.isLinux) await Process.run('xdg-open', [url]);
    if (Platform.isWindows) await Process.run('explorer', [url]);
  }

  /// macOS: for each file, its displayed width and height, when it was taken (epoch ms; from EXIF or the video's
  /// creation date, absent when unknown) and a video's length in seconds. Null entries for files it can't read.
  static Future<List<Map<String, Object?>?>> probe(List<String> paths) async {
    final out = await _channel.invokeListMethod<Object?>('probe', {'paths': paths}) ?? [];
    return [for (final o in out) o == null ? null : (o as Map).cast<String, Object?>()];
  }

  /// macOS: an upright JPEG thumbnail at most [size] px on its long side (photos incl. HEIC and RAW, and videos).
  static Future<Uint8List?> thumb(String path, int size) =>
      _channel.invokeMethod<Uint8List>('thumb', {'path': path, 'size': size});

  /// macOS: moves files to the Trash. Returns the paths moved.
  static Future<List<String>> trash(List<String> paths) async =>
      await _channel.invokeListMethod<String>('trash', {'paths': paths}) ?? [];
}

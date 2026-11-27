import 'dart:io';

import 'package:flutter/services.dart';

/// Winnow's Android-only calls. Registered as a plugin, so they also work in the background upload task.
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
}

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';
import 'package:winnow_native/winnow_native.dart';

import 'models.dart';

// Google Photos (Library API, 2025 rules): Winnow uploads kept photos and files them into albums it creates with the
// same names. It can only see and change what it made itself: no access to the rest of the library, and no delete
// (only take its own photos out of its own albums).

const googleScopes = [
  'https://www.googleapis.com/auth/photoslibrary.appendonly',
  'https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata',
  'https://www.googleapis.com/auth/photoslibrary.edit.appcreateddata',
  'https://www.googleapis.com/auth/userinfo.email',
];

class GPhotosConfig {
  const GPhotosConfig({
    this.email = '',
    this.enabled = false,
    this.wifiOnly = true,
    this.videos = true,
    this.background = 'off',
    this.backupOffSeen = false,
  });

  /// The signed-in account ('' when signed out).
  final String email;
  final bool enabled;
  final bool wifiOnly;
  final bool videos;
  final String background;

  /// The user confirmed Google Photos' own backup is off (hides the notice).
  final bool backupOffSeen;

  bool get ready => email.isNotEmpty;

  GPhotosConfig copyWith({
    String? email,
    bool? enabled,
    bool? wifiOnly,
    bool? videos,
    String? background,
    bool? backupOffSeen,
  }) =>
      GPhotosConfig(
        email: email ?? this.email,
        enabled: enabled ?? this.enabled,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        videos: videos ?? this.videos,
        background: background ?? this.background,
        backupOffSeen: backupOffSeen ?? this.backupOffSeen,
      );

  Map<String, Object?> toJson() => {
        'email': email,
        'enabled': enabled,
        'wifiOnly': wifiOnly,
        'videos': videos,
        'background': background,
        'backupOffSeen': backupOffSeen,
      };

  static GPhotosConfig fromJson(Map<String, Object?>? j) => j == null
      ? const GPhotosConfig()
      : GPhotosConfig(
          email: (j['email'] as String?) ?? '',
          enabled: j['enabled'] == true,
          wifiOnly: j['wifiOnly'] != false,
          videos: j['videos'] != false,
          background: (j['background'] as String?) ?? 'off',
          backupOffSeen: j['backupOffSeen'] == true,
        );
}

/// A photo in Google Photos and the Winnow album it was last filed into there.
class GRecord {
  GRecord({required this.id, required this.mediaItemId, this.albumId});

  final String id;
  final String mediaItemId;
  String? albumId;

  Map<String, Object?> toJson() => {'id': id, 'mediaItemId': mediaItemId, if (albumId != null) 'albumId': albumId};

  static GRecord fromJson(Map<String, Object?> j) =>
      GRecord(id: '${j['id']}', mediaItemId: j['mediaItemId'] as String, albumId: j['albumId'] as String?);
}

/// Signs in (account picker and consent) and returns the account's email.
Future<String> googleSignIn() async {
  final token = await WinnowNative.googleToken(googleScopes, interactive: true);
  if (token == null) throw Exception('Sign-in was cancelled');
  final res = await http.get(Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
      headers: {'Authorization': 'Bearer $token'});
  if (res.statusCode >= 400) throw Exception('Google ${res.statusCode}: ${res.body}');
  return '${(jsonDecode(res.body) as Map)['email']}';
}

class GPhotosApi {
  GPhotosApi._(this._token);

  final String _token;
  final _client = http.Client();
  static const _base = 'https://photoslibrary.googleapis.com/v1';

  /// Without asking the user (works in the background once they've signed in). Null if they need to sign in again.
  static Future<GPhotosApi?> connect() async {
    final token = await WinnowNative.googleToken(googleScopes);
    return token == null ? null : GPhotosApi._(token);
  }

  Future<Map<String, Object?>> _call(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$_base$path'))
      ..headers.addAll({'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'});
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _client.send(req));
    if (res.statusCode >= 400) {
      var msg = res.body;
      try {
        msg = '${((jsonDecode(res.body) as Map)['error'] as Map)['message']}';
      } catch (_) {}
      throw GoogleError(res.statusCode, msg);
    }
    return res.body.isEmpty ? {} : (jsonDecode(res.body) as Map).cast<String, Object?>();
  }

  /// Uploads the original bytes; returns an upload token for [create].
  Future<String> upload(Item item) async {
    final file = await item.entity.originFile;
    if (file == null) throw Exception('could not read ${item.name}');
    final req = http.StreamedRequest('POST', Uri.parse('$_base/uploads'))
      ..headers.addAll({
        'Authorization': 'Bearer $_token',
        'Content-Type': 'application/octet-stream',
        'X-Goog-Upload-Content-Type': item.entity.mimeType ?? (item.isVideo ? 'video/mp4' : 'image/jpeg'),
        'X-Goog-Upload-Protocol': 'raw',
      })
      ..contentLength = await file.length();
    file.openRead().listen(req.sink.add, onDone: req.sink.close, onError: req.sink.addError);
    final res = await http.Response.fromStream(await _client.send(req));
    if (res.statusCode >= 400) throw GoogleError(res.statusCode, res.body);
    return res.body;
  }

  /// Creates media items from upload tokens (up to 50) in [albumId]. Returns the new ids, in order (null = failed).
  Future<List<String?>> create(List<({String token, String name})> uploads, String albumId) async {
    final res = await _call('POST', '/mediaItems:batchCreate', {
      'albumId': albumId,
      'newMediaItems': [
        for (final u in uploads) {'simpleMediaItem': {'uploadToken': u.token, 'fileName': u.name}},
      ],
    });
    return [
      for (final r in (res['newMediaItemResults'] as List? ?? []).cast<Map>()) (r['mediaItem'] as Map?)?['id'] as String?,
    ];
  }

  /// The Google album for a Winnow album: the remembered one (renamed if needed), else a new one.
  Future<String> ensureAlbum(Album album) async {
    final title = albumTitle(album);
    final known = album.googleAlbumId;
    if (known != null) {
      try {
        final a = await _call('GET', '/albums/$known');
        if (a['title'] != title) await _call('PATCH', '/albums/$known?updateMask=title', {'title': title});
        return known;
      } on GoogleError catch (e) {
        if (e.status != 404 && e.status != 400) rethrow;
      }
    }
    final a = await _call('POST', '/albums', {
      'album': {'title': title},
    });
    return album.googleAlbumId = a['id'] as String;
  }

  Future<void> add(String albumId, List<String> ids) async {
    for (var i = 0; i < ids.length; i += 50) {
      await _call('POST', '/albums/$albumId:batchAddMediaItems', {'mediaItemIds': ids.sublist(i, (i + 50).clamp(0, ids.length))});
    }
  }

  Future<void> remove(String albumId, List<String> ids) async {
    for (var i = 0; i < ids.length; i += 50) {
      await _call('POST', '/albums/$albumId:batchRemoveMediaItems', {'mediaItemIds': ids.sublist(i, (i + 50).clamp(0, ids.length))});
    }
  }

  Future<bool> exists(String mediaItemId) async {
    try {
      await _call('GET', '/mediaItems/$mediaItemId');
      return true;
    } on GoogleError catch (e) {
      if (e.status == 404 || e.status == 400) return false;
      rethrow;
    }
  }

  void close() {
    _client.close();
    PhotoManager.clearFileCache();
  }
}

class GoogleError implements Exception {
  GoogleError(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'Google $status: $message';
}

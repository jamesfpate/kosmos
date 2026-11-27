import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

import 'models.dart';

// Backblaze B2 (native API v3): kept photos are uploaded straight from the phone into
// <prefix>YYYY/YYYY-MM name/file (dated albums) or <prefix>Albums/name/file (undated). A photo that moves to another
// album, or whose album is renamed, is copied to its new path and the old one hidden (B2 keeps it as a hidden
// version until the bucket's lifecycle rules remove it).

class B2Config {
  const B2Config({
    this.keyId = '',
    this.appKey = '',
    this.bucket = '',
    this.prefix = 'Photos/',
    this.enabled = false,
    this.wifiOnly = false,
    this.videos = true,
    this.background = 'off',
  });

  final String keyId;
  final String appKey;
  final String bucket;

  /// Folder in the bucket everything goes under ('' for the top).
  final String prefix;
  final bool enabled;
  final bool wifiOnly;
  final bool videos;
  final String background;

  bool get ready => keyId.isNotEmpty && appKey.isNotEmpty && bucket.isNotEmpty;

  B2Config copyWith({
    String? keyId,
    String? appKey,
    String? bucket,
    String? prefix,
    bool? enabled,
    bool? wifiOnly,
    bool? videos,
    String? background,
  }) =>
      B2Config(
        keyId: keyId ?? this.keyId,
        appKey: appKey ?? this.appKey,
        bucket: bucket ?? this.bucket,
        prefix: prefix ?? this.prefix,
        enabled: enabled ?? this.enabled,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        videos: videos ?? this.videos,
        background: background ?? this.background,
      );

  Map<String, Object?> toJson() => {
        'keyId': keyId,
        'appKey': appKey,
        'bucket': bucket,
        'prefix': prefix,
        'enabled': enabled,
        'wifiOnly': wifiOnly,
        'videos': videos,
        'background': background,
      };

  static B2Config fromJson(Map<String, Object?>? j) => j == null
      ? const B2Config()
      : B2Config(
          keyId: (j['keyId'] as String?) ?? '',
          appKey: (j['appKey'] as String?) ?? '',
          bucket: (j['bucket'] as String?) ?? '',
          prefix: (j['prefix'] as String?) ?? 'Photos/',
          enabled: j['enabled'] == true,
          wifiOnly: j['wifiOnly'] == true,
          videos: j['videos'] != false,
          background: (j['background'] as String?) ?? 'off',
        );
}

/// A photo in B2: where it is now.
class B2Record {
  B2Record({required this.id, required this.fileId, required this.fileName});

  final String id;
  final String fileId;
  final String fileName;

  Map<String, Object?> toJson() => {'id': id, 'fileId': fileId, 'fileName': fileName};

  static B2Record fromJson(Map<String, Object?> j) =>
      B2Record(id: '${j['id']}', fileId: j['fileId'] as String, fileName: j['fileName'] as String);
}

/// Where a photo filed into [album] goes in the bucket (before any name clash suffix).
String b2Path(B2Config c, Album album, String fileName) {
  var p = c.prefix.trim();
  if (p.isNotEmpty && !p.endsWith('/')) p = '$p/';
  final safe = albumTitle(album).replaceAll('/', '-').trim();
  final folder = album.start == null ? 'Albums/$safe' : '${DateTime.fromMillisecondsSinceEpoch(album.start!).year}/$safe';
  return '$p$folder/${fileName.replaceAll('/', '-')}';
}

/// Inserts a suffix before the extension: `IMG_1.jpg` -> `IMG_1_tag.jpg`.
String withSuffix(String path, String tag) {
  final dot = path.lastIndexOf('.');
  final slash = path.lastIndexOf('/');
  if (dot <= slash) return '${path}_$tag';
  return '${path.substring(0, dot)}_$tag${path.substring(dot)}';
}

// Test builds can point this at a mock (--dart-define=B2_AUTH_URL=...).
const _authUrl = String.fromEnvironment('B2_AUTH_URL',
    defaultValue: 'https://api.backblazeb2.com/b2api/v3/b2_authorize_account');

class B2Api {
  B2Api(this.cfg);

  final B2Config cfg;
  final _client = http.Client();
  String? _apiUrl;
  String? _token;
  String? _bucketId;
  String? _uploadUrl;
  String? _uploadToken;

  /// Signs in and finds the bucket. Returns the bucket name (the key may be limited to one bucket).
  Future<String> authorize() async {
    final basic = base64Encode(utf8.encode('${cfg.keyId.trim()}:${cfg.appKey.trim()}'));
    final res = await _client.get(Uri.parse(_authUrl),
        headers: {'Authorization': 'Basic $basic'});
    final j = _decode(res);
    final storage = (j['apiInfo'] as Map)['storageApi'] as Map;
    _apiUrl = storage['apiUrl'] as String;
    _token = j['authorizationToken'] as String;
    final allowed = (storage['allowed'] as Map?) ?? {};
    final buckets = (allowed['buckets'] as List?)?.cast<Map>() ?? const [];
    final restricted = buckets.where((b) => b['name'] == cfg.bucket.trim()).firstOrNull;
    if (restricted != null) {
      _bucketId = restricted['id'] as String;
    } else {
      final found = await _call('b2_list_buckets', {'accountId': j['accountId'], 'bucketName': cfg.bucket.trim()});
      final list = (found['buckets'] as List).cast<Map>();
      if (list.isEmpty) throw Exception('No bucket named "${cfg.bucket.trim()}" for this key');
      _bucketId = list.first['bucketId'] as String;
    }
    return cfg.bucket.trim();
  }

  Map<String, Object?> _decode(http.Response res) {
    if (res.statusCode >= 400) {
      var msg = res.body;
      try {
        msg = '${(jsonDecode(res.body) as Map)['message']}';
      } catch (_) {}
      throw B2Error(res.statusCode, msg);
    }
    return (jsonDecode(res.body) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> _call(String op, Map<String, Object?> body) async {
    final res = await _client.post(Uri.parse('$_apiUrl/b2api/v3/$op'),
        headers: {'Authorization': _token!, 'Content-Type': 'application/json'}, body: jsonEncode(body));
    return _decode(res);
  }

  /// Uploads the original file to [fileName]. Returns the B2 file id.
  Future<String> upload(Item item, String fileName) async {
    final file = await item.entity.originFile;
    if (file == null) throw Exception('could not read ${item.name}');
    final digest = await sha1.bind(file.openRead()).first;
    final length = await file.length();
    for (var attempt = 0;; attempt++) {
      if (_uploadUrl == null) {
        final u = await _call('b2_get_upload_url', {'bucketId': _bucketId});
        _uploadUrl = u['uploadUrl'] as String;
        _uploadToken = u['authorizationToken'] as String;
      }
      final req = http.StreamedRequest('POST', Uri.parse(_uploadUrl!))
        ..headers.addAll({
          'Authorization': _uploadToken!,
          'X-Bz-File-Name': Uri.encodeComponent(fileName).replaceAll('%2F', '/'),
          'Content-Type': item.entity.mimeType ?? 'b2/x-auto',
          'X-Bz-Content-Sha1': '$digest',
          'X-Bz-Info-src_last_modified_millis': '${item.taken}',
        })
        ..contentLength = length;
      file.openRead().listen(req.sink.add, onDone: req.sink.close, onError: req.sink.addError);
      try {
        final res = await http.Response.fromStream(await _client.send(req));
        return _decode(res)['fileId'] as String;
      } catch (e) {
        // Upload URLs can go busy or expire: get a fresh one and retry (twice).
        _uploadUrl = null;
        if (attempt >= 2 || (e is B2Error && e.status < 500 && e.status != 401 && e.status != 408)) rethrow;
      }
    }
  }

  /// Moves a file: copy to the new name, hide the old one. Returns the new file id.
  Future<String> move(B2Record r, String fileName) async {
    final copied = await _call('b2_copy_file', {'sourceFileId': r.fileId, 'fileName': fileName});
    await _call('b2_hide_file', {'bucketId': _bucketId, 'fileName': r.fileName});
    return copied['fileId'] as String;
  }

  /// Whether the file is still there (for freeing up space).
  Future<bool> exists(B2Record r) async {
    try {
      final info = await _call('b2_get_file_info', {'fileId': r.fileId});
      return info['action'] == 'upload';
    } on B2Error catch (e) {
      if (e.status == 404 || e.status == 400) return false;
      rethrow;
    }
  }

  void close() {
    _client.close();
    PhotoManager.clearFileCache();
  }
}

class B2Error implements Exception {
  B2Error(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'B2 $status: $message';
}

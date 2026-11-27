import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

import 'models.dart';
import 'store.dart';

const b2Def = StoreDef(
  key: 'b2',
  title: 'Backblaze B2',
  label: 'B2',
  intro: [
    'Kept photos are copied, original files, into your own B2 bucket by album. Moving a photo or renaming an album moves its files.',
    'In Backblaze: Application Keys → Add a New Application Key, allow access to the bucket, Read and Write. Set the bucket to keep only the last version so moved files don\'t take up space.',
  ],
  fields: [
    FieldDef('keyId', 'Key ID', 'keyID'),
    FieldDef('appKey', 'Application key', 'applicationKey', secret: true),
    FieldDef('bucket', 'Bucket', 'my-photos'),
  ],
  folderLabel: 'Folder in the bucket',
  make: _make,
);

FileStore _make(StoreConfig c, void Function(String, String) remember) => B2Api(c);

// Backblaze B2 (native API v3). A photo that moves to another album, or whose album is renamed, is copied to its new
// path and the old one hidden (B2 keeps it as a hidden version until the bucket's lifecycle rules remove it).

// Test builds can point this at a mock (--dart-define=B2_AUTH_URL=...).
const _authUrl = String.fromEnvironment('B2_AUTH_URL',
    defaultValue: 'https://api.backblazeb2.com/b2api/v3/b2_authorize_account');

class B2Api extends FileStore {
  B2Api(this.cfg);

  final StoreConfig cfg;
  final _client = http.Client();
  String? _apiUrl;
  String? _token;
  String? _bucketId;
  String? _uploadUrl;
  String? _uploadToken;

  /// Signs in and finds the bucket. Returns the bucket name (the key may be limited to one bucket).
  @override
  Future<String> authorize() async {
    final basic = base64Encode(utf8.encode('${cfg['keyId'].trim()}:${cfg['appKey'].trim()}'));
    final res = await _client.get(Uri.parse(_authUrl),
        headers: {'Authorization': 'Basic $basic'});
    final j = _decode(res);
    final storage = (j['apiInfo'] as Map)['storageApi'] as Map;
    _apiUrl = storage['apiUrl'] as String;
    _token = j['authorizationToken'] as String;
    final allowed = (storage['allowed'] as Map?) ?? {};
    final buckets = (allowed['buckets'] as List?)?.cast<Map>() ?? const [];
    final restricted = buckets.where((b) => b['name'] == cfg['bucket'].trim()).firstOrNull;
    if (restricted != null) {
      _bucketId = restricted['id'] as String;
    } else {
      final found = await _call('b2_list_buckets', {'accountId': j['accountId'], 'bucketName': cfg['bucket'].trim()});
      final list = (found['buckets'] as List).cast<Map>();
      if (list.isEmpty) throw Exception('No bucket named "${cfg['bucket'].trim()}" for this key');
      _bucketId = list.first['bucketId'] as String;
    }
    return cfg['bucket'].trim();
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
  @override
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
          'X-Bz-File-Name': Uri.encodeComponent(objectKey(fileName)).replaceAll('%2F', '/'),
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
  @override
  Future<String> move(FileRecord r, String fileName) async {
    final copied = await _call('b2_copy_file', {'sourceFileId': r.fileId, 'fileName': objectKey(fileName)});
    await _call('b2_hide_file', {'bucketId': _bucketId, 'fileName': objectKey(r.fileName)});
    return copied['fileId'] as String;
  }

  /// Whether the file is still there (for freeing up space).
  @override
  Future<bool> exists(FileRecord r) async {
    try {
      final info = await _call('b2_get_file_info', {'fileId': r.fileId});
      return info['action'] == 'upload';
    } on B2Error catch (e) {
      if (e.status == 404 || e.status == 400) return false;
      rethrow;
    }
  }

  @override
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

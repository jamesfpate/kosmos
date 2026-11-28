import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'store.dart';

// Dropbox. Sign-in is OAuth with PKCE and no redirect: Dropbox shows a code after you allow access, and you paste it
// into Winnow. The app key is set at build time (--dart-define=DROPBOX_APP_KEY=...; Dropbox App Console, scoped
// access, files.content.write + files.content.read + account_info.read).

const dropboxAppKey = String.fromEnvironment('DROPBOX_APP_KEY');
const _api = 'https://api.dropboxapi.com';
const _content = 'https://content.dropboxapi.com';

const dropboxDef = StoreDef(
  key: 'dropbox',
  title: 'Dropbox',
  label: 'Dropbox',
  intro: [
    'Kept photos are copied, original files, into a folder in your Dropbox by album. Moving a photo or renaming an '
        'album moves its files.',
  ],
  fields: [
    FieldDef('account', 'Account', '', hidden: true),
    FieldDef('refreshToken', 'Refresh token', '', hidden: true),
  ],
  folderLabel: 'Folder in Dropbox',
  make: _make,
  signIn: _signIn,
  available: dropboxAppKey != '',
);

FileStore _make(StoreConfig c, void Function(String, String) remember) => DropboxApi(c);

String _b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Future<Map<String, String>> _signIn(SignInUi ui) async {
  if (dropboxAppKey.isEmpty) throw Exception('Dropbox isn\'t set up in this build of Winnow');
  final rand = Random.secure();
  final verifier = _b64url(List<int>.generate(48, (_) => rand.nextInt(256)));
  final challenge = _b64url(sha256.convert(ascii.encode(verifier)).bytes);
  final url = Uri.https('www.dropbox.com', '/oauth2/authorize', {
    'client_id': dropboxAppKey,
    'response_type': 'code',
    'token_access_type': 'offline',
    'code_challenge': challenge,
    'code_challenge_method': 'S256',
  }).toString();
  final code = await ui.askCode(url);
  if (code == null || code.trim().isEmpty) throw Exception('Sign-in was cancelled');
  final res = await http.post(Uri.parse('$_api/oauth2/token'), body: {
    'code': code.trim(),
    'grant_type': 'authorization_code',
    'client_id': dropboxAppKey,
    'code_verifier': verifier,
  });
  final t = jsonDecode(res.body) as Map;
  if (res.statusCode >= 400) throw Exception('Dropbox: ${t['error_description'] ?? t['error']}');
  final me = await http.post(Uri.parse('$_api/2/users/get_current_account'),
      headers: {'Authorization': 'Bearer ${t['access_token']}'});
  final account = me.statusCode < 400 ? '${(jsonDecode(me.body) as Map)['email']}' : '';
  return {'refreshToken': '${t['refresh_token']}', 'account': account};
}

/// Dropbox-API-Arg must be ASCII: non-ASCII characters as JSON escapes.
String _arg(Object value) => jsonEncode(value).replaceAllMapped(
    RegExp(r'[^\x00-\x7F]'), (m) => '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}');

class DropboxApi extends FileStore {
  DropboxApi(this.cfg);

  final StoreConfig cfg;
  final _client = http.Client();
  String? _token;

  static String _path(String path) => '/${objectKey(path)}';

  Future<Map<String, Object?>> _rpc(String route, Object? body) async {
    final res = await _client.post(Uri.parse('$_api/2/$route'),
        headers: {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'}, body: jsonEncode(body));
    if (res.statusCode >= 400) throw DropboxError(res.statusCode, res.body);
    return res.body.isEmpty ? {} : (jsonDecode(res.body) as Map).cast<String, Object?>();
  }

  @override
  Future<String> authorize() async {
    if (dropboxAppKey.isEmpty) throw Exception('Dropbox isn\'t set up in this build of Winnow');
    final res = await _client.post(Uri.parse('$_api/oauth2/token'), body: {
      'grant_type': 'refresh_token',
      'refresh_token': cfg['refreshToken'],
      'client_id': dropboxAppKey,
    });
    final t = jsonDecode(res.body) as Map;
    if (res.statusCode >= 400) throw Exception('Dropbox: sign in again (${t['error_description'] ?? t['error']})');
    _token = '${t['access_token']}';
    return '${cfg['account']} · Dropbox/${cfg.folder}';
  }

  Future<Map<String, Object?>> _contentCall(String route, Object arg, List<int> bytes) async {
    final res = await _client.post(Uri.parse('$_content/2/$route'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Content-Type': 'application/octet-stream',
          'Dropbox-API-Arg': _arg(arg),
        },
        body: bytes);
    if (res.statusCode >= 400) throw DropboxError(res.statusCode, res.body);
    return res.body.isEmpty || res.body == 'null' ? {} : (jsonDecode(res.body) as Map).cast<String, Object?>();
  }

  @override
  Future<String> upload(Item item, String path) async {
    final file = await item.file();
    if (file == null) throw Exception('could not read ${item.name}');
    final size = await file.length();
    final commit = {'path': _path(path), 'mode': 'overwrite', 'autorename': false, 'mute': true};
    const chunk = 8 * 1024 * 1024;
    if (size <= chunk) {
      return '${(await _contentCall('files/upload', commit, await file.readAsBytes()))['id']}';
    }
    // Larger (videos): an upload session.
    final raf = await file.open();
    try {
      final first = await raf.read(chunk);
      final session = '${(await _contentCall('files/upload_session/start', {'close': false}, first))['session_id']}';
      var at = first.length;
      while (size - at > chunk) {
        final bytes = await raf.read(chunk);
        await _contentCall('files/upload_session/append_v2', {
          'cursor': {'session_id': session, 'offset': at},
          'close': false,
        }, bytes);
        at += bytes.length;
      }
      final last = await raf.read(size - at);
      final done = await _contentCall('files/upload_session/finish', {
        'cursor': {'session_id': session, 'offset': at},
        'commit': commit,
      }, last);
      return '${done['id']}';
    } finally {
      await raf.close();
    }
  }

  @override
  Future<String> move(FileRecord r, String path) async {
    final res = await _rpc('files/move_v2', {'from_path': r.fileId, 'to_path': _path(path), 'autorename': false});
    return '${(res['metadata'] as Map)['id']}';
  }

  @override
  Future<bool> exists(FileRecord r) async {
    try {
      await _rpc('files/get_metadata', {'path': r.fileId});
      return true;
    } on DropboxError catch (e) {
      if (e.status == 409 && e.body.contains('not_found')) return false;
      rethrow;
    }
  }

  @override
  Future<List<RemoteFile>> list(String dir) async {
    final out = <RemoteFile>[];
    Map<String, Object?> page;
    try {
      page = await _rpc('files/list_folder', {'path': _path(dir), 'limit': 2000});
    } on DropboxError catch (e) {
      if (e.status == 409 && e.body.contains('not_found')) return [];
      rethrow;
    }
    while (true) {
      for (final f in (page['entries'] as List).cast<Map>()) {
        if (f['.tag'] != 'file') continue;
        final name = f['name'] as String;
        out.add(RemoteFile(dir.isEmpty ? name : '$dir/$name', '${f['id']}', (f['size'] as num).toInt(),
            dropbox: f['content_hash'] as String?));
      }
      if (page['has_more'] != true) break;
      page = await _rpc('files/list_folder/continue', {'cursor': page['cursor']});
    }
    return out;
  }

  @override
  Future<List<String>> folders(String dir) async {
    final out = <String>[];
    Map<String, Object?> page;
    try {
      page = await _rpc('files/list_folder', {'path': _path(dir), 'limit': 2000});
    } on DropboxError catch (e) {
      if (e.status == 409 && e.body.contains('not_found')) return [];
      rethrow;
    }
    while (true) {
      for (final f in (page['entries'] as List).cast<Map>()) {
        if (f['.tag'] == 'folder') out.add(f['name'] as String);
      }
      if (page['has_more'] != true) break;
      page = await _rpc('files/list_folder/continue', {'cursor': page['cursor']});
    }
    return out;
  }

  @override
  Future<Uint8List> head(RemoteFile f, int n) async {
    final req = http.Request('POST', Uri.parse('$_content/2/files/download'))
      ..headers.addAll({'Authorization': 'Bearer $_token', 'Dropbox-API-Arg': _arg({'path': f.id}), 'Range': 'bytes=0-${n - 1}'});
    final res = await _client.send(req);
    if (res.statusCode >= 400) throw DropboxError(res.statusCode, 'reading ${f.path}');
    return takeBytes(res.stream, n);
  }

  @override
  void close() {
    _client.close();
    clearFileCache();
  }
}

class DropboxError implements Exception {
  DropboxError(this.status, this.body);

  final int status;
  final String body;

  @override
  String toString() {
    var msg = body;
    try {
      msg = '${(jsonDecode(body) as Map)['error_summary']}';
    } catch (_) {}
    return 'Dropbox $status: $msg';
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

import 'models.dart';
import 'store.dart';

// Microsoft OneDrive (personal, work or school) through Microsoft Graph. Sign-in is the device-code flow: Winnow
// shows a code to enter at microsoft.com/devicelogin, so no redirect back into the app is needed. The app's client
// id is set at build time (--dart-define=ONEDRIVE_CLIENT_ID=...; Azure app registration, public client, Files.ReadWrite
// and offline_access).

const oneDriveClientId = String.fromEnvironment('ONEDRIVE_CLIENT_ID');
const _scopes = 'Files.ReadWrite User.Read offline_access';
const _login = 'https://login.microsoftonline.com/common/oauth2/v2.0';
const _graph = 'https://graph.microsoft.com/v1.0';

const oneDriveDef = StoreDef(
  key: 'onedrive',
  title: 'OneDrive',
  label: 'OneDrive',
  intro: [
    'Kept photos are copied, original files, into a folder in your OneDrive by album. Moving a photo or renaming an '
        'album moves its files. Works with personal and work or school accounts.',
  ],
  fields: [
    FieldDef('account', 'Account', '', hidden: true),
    FieldDef('refreshToken', 'Refresh token', '', hidden: true),
  ],
  folderLabel: 'Folder in OneDrive',
  make: _make,
  signIn: _signIn,
  available: oneDriveClientId != '',
);

FileStore _make(StoreConfig c, void Function(String, String) remember) => OneDriveApi(c, remember);

Future<Map<String, String>> _signIn(SignInUi ui) async {
  if (oneDriveClientId.isEmpty) throw Exception('OneDrive isn\'t set up in this build of Winnow');
  final start = await http.post(Uri.parse('$_login/devicecode'), body: {'client_id': oneDriveClientId, 'scope': _scopes});
  final j = jsonDecode(start.body) as Map;
  if (start.statusCode >= 400) throw Exception('OneDrive: ${j['error_description'] ?? start.body}');
  await ui.showCode('${j['user_code']}', '${j['verification_uri']}');
  var interval = (j['interval'] as num?)?.toInt() ?? 5;
  final until = DateTime.now().add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 900));
  try {
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(Duration(seconds: interval));
      final res = await http.post(Uri.parse('$_login/token'), body: {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'client_id': oneDriveClientId,
        'device_code': '${j['device_code']}',
      });
      final t = jsonDecode(res.body) as Map;
      if (res.statusCode < 400) {
        final me = await http.get(Uri.parse('$_graph/me'), headers: {'Authorization': 'Bearer ${t['access_token']}'});
        final m = jsonDecode(me.body) as Map;
        return {'refreshToken': '${t['refresh_token']}', 'account': '${m['userPrincipalName'] ?? m['displayName'] ?? ''}'};
      }
      switch (t['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += 5;
          continue;
        default:
          throw Exception('OneDrive: ${t['error_description'] ?? t['error']}');
      }
    }
    throw Exception('OneDrive: the code expired; try again');
  } finally {
    ui.done();
  }
}

class OneDriveApi extends FileStore {
  OneDriveApi(this.cfg, this.remember);

  final StoreConfig cfg;
  final void Function(String, String) remember;
  final _client = http.Client();
  String? _token;
  final _made = <String>{};

  static String _enc(String path) => objectKey(path).split('/').where((p) => p.isNotEmpty).map(Uri.encodeComponent).join('/');

  Future<Map<String, Object?>> _call(String method, String url, [Object? body]) async {
    final req = http.Request(method, Uri.parse(url.startsWith('http') ? url : '$_graph$url'))
      ..headers.addAll({'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'});
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _client.send(req));
    if (res.statusCode >= 400) throw OneDriveError(res.statusCode, res.body);
    return res.body.isEmpty ? {} : (jsonDecode(res.body) as Map).cast<String, Object?>();
  }

  @override
  Future<String> authorize() async {
    if (oneDriveClientId.isEmpty) throw Exception('OneDrive isn\'t set up in this build of Winnow');
    final res = await _client.post(Uri.parse('$_login/token'), body: {
      'grant_type': 'refresh_token',
      'client_id': oneDriveClientId,
      'refresh_token': cfg['refreshToken'],
      'scope': _scopes,
    });
    final t = jsonDecode(res.body) as Map;
    if (res.statusCode >= 400) throw Exception('OneDrive: sign in again (${t['error_description'] ?? t['error']})');
    _token = '${t['access_token']}';
    // Refresh tokens rotate: keep the new one.
    if (t['refresh_token'] != null && t['refresh_token'] != cfg['refreshToken']) remember('refreshToken', '${t['refresh_token']}');
    return '${cfg['account']} · OneDrive/${cfg.folder}';
  }

  /// Makes each folder of [path]'s directory that doesn't exist yet.
  Future<void> _dirs(String path) async {
    final parts = objectKey(path).split('/')..removeLast();
    var at = '';
    for (final p in parts.where((p) => p.isNotEmpty)) {
      final parent = at;
      at = at.isEmpty ? p : '$at/$p';
      if (_made.contains(at)) continue;
      try {
        await _call('POST', parent.isEmpty ? '/me/drive/root/children' : '/me/drive/root:/${_enc(parent)}:/children', {
          'name': p,
          'folder': <String, Object?>{},
          '@microsoft.graph.conflictBehavior': 'fail',
        });
      } on OneDriveError catch (e) {
        if (e.status != 409) rethrow;
      }
      _made.add(at);
    }
  }

  @override
  Future<String> upload(Item item, String path) async {
    final File? file = await item.entity.originFile;
    if (file == null) throw Exception('could not read ${item.name}');
    final size = await file.length();
    if (size <= 4 * 1024 * 1024) {
      final res = await _client.put(Uri.parse('$_graph/me/drive/root:/${_enc(path)}:/content'),
          headers: {'Authorization': 'Bearer $_token', 'Content-Type': item.entity.mimeType ?? 'application/octet-stream'},
          body: await file.readAsBytes());
      if (res.statusCode >= 400) throw OneDriveError(res.statusCode, res.body);
      return '${(jsonDecode(res.body) as Map)['id']}';
    }
    // Larger: an upload session, in chunks (a multiple of 320 KiB).
    final session = await _call('POST', '/me/drive/root:/${_enc(path)}:/createUploadSession', {
      'item': {'@microsoft.graph.conflictBehavior': 'replace'},
    });
    final url = session['uploadUrl'] as String;
    const chunk = 320 * 1024 * 32;
    final raf = await file.open();
    try {
      for (var at = 0; at < size; at += chunk) {
        final n = min(chunk, size - at);
        final bytes = await raf.read(n);
        final res = await _client.put(Uri.parse(url),
            headers: {'Content-Range': 'bytes $at-${at + n - 1}/$size', 'Content-Length': '$n'}, body: bytes);
        if (res.statusCode >= 400) throw OneDriveError(res.statusCode, res.body);
        if (res.statusCode == 200 || res.statusCode == 201) return '${(jsonDecode(res.body) as Map)['id']}';
      }
    } finally {
      await raf.close();
    }
    throw Exception('OneDrive: upload of ${item.name} did not finish');
  }

  @override
  Future<String> move(FileRecord r, String path) async {
    await _dirs(path);
    final key = objectKey(path);
    final parent = key.contains('/') ? key.substring(0, key.lastIndexOf('/')) : '';
    final res = await _call('PATCH', '/me/drive/items/${r.fileId}', {
      'parentReference': {'path': '/drive/root:/$parent'},
      'name': key.split('/').last,
    });
    return '${res['id']}';
  }

  @override
  Future<bool> exists(FileRecord r) async {
    try {
      final item = await _call('GET', '/me/drive/items/${r.fileId}');
      return item['deleted'] == null;
    } on OneDriveError catch (e) {
      if (e.status == 404) return false;
      rethrow;
    }
  }

  @override
  void close() {
    _client.close();
    PhotoManager.clearFileCache();
  }
}

class OneDriveError implements Exception {
  OneDriveError(this.status, this.body);

  final int status;
  final String body;

  @override
  String toString() {
    var msg = body;
    try {
      msg = '${((jsonDecode(body) as Map)['error'] as Map)['message']}';
    } catch (_) {}
    return 'OneDrive $status: $msg';
  }
}

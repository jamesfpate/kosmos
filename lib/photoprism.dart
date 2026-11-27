import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

import 'models.dart';
import 'store.dart';

// PhotoPrism: kept photos are uploaded and imported straight into albums of the same names; moving a photo or
// renaming an album updates them. Uploads are matched back to their photo by original name + SHA-1.

const photoprismDef = StoreDef(
  key: 'photoprism',
  title: 'PhotoPrism',
  label: 'PhotoPrism',
  intro: [
    'Kept photos upload, original files, into your PhotoPrism library and into albums of the same names. Moving a '
        'photo or renaming an album updates them. Deleted photos are never uploaded.',
    'Use an app password if you have two-factor sign-in on (Settings → Account → Apps and Devices), or your normal '
        'password. The account needs upload rights.',
  ],
  fields: [
    FieldDef('url', 'Server', 'https://photos.example.com', url: true),
    FieldDef('user', 'User name', 'admin'),
    FieldDef('password', 'Password or app password', 'password', secret: true),
  ],
  albums: _make,
);

AlbumService _make(StoreConfig c, void Function(String, String) remember) => PhotoPrismApi(c);

class PhotoPrismApi implements AlbumService {
  PhotoPrismApi(this.cfg);

  final StoreConfig cfg;
  final _client = http.Client();
  String? _token;
  String? _user;

  String get _base {
    var u = cfg['url'].trim().replaceAll(RegExp(r'/+$'), '');
    if (u.isNotEmpty && !RegExp(r'^https?://').hasMatch(u)) u = 'https://$u';
    return '$u/api/v1';
  }

  Future<dynamic> _call(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$_base$path'))
      ..headers.addAll({'Content-Type': 'application/json', if (_token != null) 'Authorization': 'Bearer $_token'});
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _client.send(req));
    if (res.statusCode >= 400) {
      var msg = res.body;
      try {
        msg = '${(jsonDecode(res.body) as Map)['error']}';
      } catch (_) {}
      throw PhotoPrismError(res.statusCode, msg);
    }
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

  @override
  Future<String> authorize() async {
    if (_token != null) return _base;
    final s = await _call('POST', '/session', {'username': cfg['user'].trim(), 'password': cfg['password'].trim()}) as Map;
    _token = (s['access_token'] ?? s['id']) as String;
    _user = (s['user'] as Map)['UID'] as String;
    return '${cfg['user']} on ${cfg['url']}';
  }

  @override
  Future<String> upload(Item item, String albumId) async {
    await authorize();
    final file = await item.entity.originFile;
    if (file == null) throw Exception('could not read ${item.name}');
    final digest = '${await sha1.bind(file.openRead()).first}';
    final token = digest.substring(0, 12);
    final req = http.MultipartRequest('POST', Uri.parse('$_base/users/$_user/upload/$token'))
      ..headers['Authorization'] = 'Bearer $_token'
      ..files.add(await http.MultipartFile.fromPath('files', file.path, filename: item.name));
    final res = await http.Response.fromStream(await _client.send(req));
    if (res.statusCode >= 400) throw PhotoPrismError(res.statusCode, res.body);
    await _call('PUT', '/users/$_user/upload/$token', {
      'albums': [albumId],
    });
    // Find the imported photo: same original name, same contents.
    final stem = item.name.contains('.') ? item.name.substring(0, item.name.lastIndexOf('.')) : item.name;
    for (var attempt = 0; attempt < 5; attempt++) {
      final found = (await _call('GET', '/photos?count=50&merged=true&q=${Uri.encodeQueryComponent('original:$stem*')}') as List)
          .cast<Map>();
      for (final p in found) {
        final files = (p['Files'] as List?)?.cast<Map>() ?? const [];
        if (p['Hash'] == digest || files.any((f) => f['Hash'] == digest)) return p['UID'] as String;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw Exception('PhotoPrism: uploaded ${item.name} but could not find it after importing');
  }

  @override
  Future<String> ensureAlbum(String title, String? known) async {
    await authorize();
    if (known != null) {
      try {
        final a = await _call('GET', '/albums/$known') as Map;
        if (a['Title'] != title) await _call('PUT', '/albums/$known', {'Title': title});
        return known;
      } on PhotoPrismError catch (e) {
        if (e.status != 404) rethrow;
      }
    }
    final a = await _call('POST', '/albums', {'Title': title}) as Map;
    return a['UID'] as String;
  }

  @override
  Future<void> add(String albumId, List<String> ids) async {
    await authorize();
    await _call('POST', '/albums/$albumId/photos', {'photos': ids});
  }

  @override
  Future<void> remove(String albumId, List<String> ids) async {
    await authorize();
    await _call('DELETE', '/albums/$albumId/photos', {'photos': ids});
  }

  @override
  Future<bool> exists(String id) async {
    await authorize();
    try {
      await _call('GET', '/photos/$id');
      return true;
    } on PhotoPrismError catch (e) {
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

class PhotoPrismError implements Exception {
  PhotoPrismError(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'PhotoPrism $status: $message';
}

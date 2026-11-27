import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'store.dart';

// ownCloud / Nextcloud (or any WebDAV server): photos go into folders made as needed; a photo whose album changes is
// MOVEd. On Nextcloud the photos are also added to Nextcloud Photos albums of the same name (what the Photos and
// Memories apps show), and albums left empty by a rename or move are removed.

const webdavDef = StoreDef(
  key: 'webdav',
  title: 'Nextcloud / ownCloud',
  label: 'WebDAV',
  intro: [
    'Kept photos are copied, original files, into a folder on your server by album. Moving a photo or renaming an '
        'album moves its files. On Nextcloud they also go into Nextcloud Photos albums of the same name. Works with '
        'any WebDAV server.',
    'Use an app password, not your login: Nextcloud → Settings → Security → Devices & sessions; ownCloud → Settings → '
        'Security → App passwords.',
  ],
  fields: [
    FieldDef('url', 'Server', 'https://cloud.example.com', url: true),
    FieldDef('user', 'User name', 'you'),
    FieldDef('password', 'App password', 'xxxxx-xxxxx-xxxxx', secret: true),
  ],
  make: _make,
);

FileStore _make(StoreConfig c, void Function(String, String) remember) => WebDavApi(c);

class WebDavApi extends FileStore {
  WebDavApi(this.cfg);

  final StoreConfig cfg;
  final _client = http.Client();
  final _made = <String>{};
  final _emptied = <String>{};

  /// Nextcloud Photos albums are available (found when signing in).
  bool _albums = false;

  /// The user's files root: given as is when it already has a path, else the Nextcloud/ownCloud one.
  String get root {
    var u = cfg['url'].trim().replaceAll(RegExp(r'/+$'), '');
    if (u.isNotEmpty && !RegExp(r'^https?://').hasMatch(u)) u = 'https://$u';
    final path = Uri.tryParse(u)?.path ?? '';
    if (path.isEmpty || path == '/') u = '$u/remote.php/dav/files/${Uri.encodeComponent(cfg['user'].trim())}';
    return u;
  }

  /// Nextcloud Photos albums root, when [root] is a Nextcloud files root.
  String? get _albumRoot {
    final m = RegExp(r'^(.*)/remote\.php/dav/files/([^/]+)$').firstMatch(root);
    return m == null ? null : '${m[1]}/remote.php/dav/photos/${m[2]}/albums';
  }

  Map<String, String> get _auth =>
      {'Authorization': 'Basic ${base64Encode(utf8.encode('${cfg['user'].trim()}:${cfg['password'].trim()}'))}'};

  static String _enc(String path) => path.split('/').where((p) => p.isNotEmpty).map(Uri.encodeComponent).join('/');

  Uri _uri(String path) => Uri.parse('$root/${_enc(path)}');

  Future<http.Response> _send(String method, Uri uri, {Map<String, String> headers = const {}}) async {
    final req = http.Request(method, uri)..headers.addAll({..._auth, ...headers});
    return http.Response.fromStream(await _client.send(req));
  }

  void _check(http.Response res, String what) {
    if (res.statusCode >= 400) {
      final hint = res.statusCode == 401 ? ' (check the user name and app password)' : '';
      throw Exception('WebDAV ${res.statusCode} $what$hint');
    }
  }

  @override
  Future<String> authorize() async {
    final res = await _send('PROPFIND', _uri(''), headers: {'Depth': '0'});
    _check(res, 'connecting to $root');
    final albums = _albumRoot;
    if (albums != null) {
      final a = await _send('PROPFIND', Uri.parse(albums), headers: {'Depth': '0'});
      _albums = a.statusCode == 207;
    }
    return _albums ? '$root (with Nextcloud Photos albums)' : root;
  }

  /// Makes each folder of [path]'s directory that doesn't exist yet.
  Future<void> _dirs(String path) async {
    final parts = path.split('/')..removeLast();
    var at = '';
    for (final p in parts.where((p) => p.isNotEmpty)) {
      at = at.isEmpty ? p : '$at/$p';
      if (_made.contains(at)) continue;
      final res = await _send('MKCOL', _uri(at));
      // 405: already there.
      if (res.statusCode >= 400 && res.statusCode != 405) _check(res, 'making folder $at');
      _made.add(at);
    }
  }

  @override
  Future<String> upload(Item item, String path) async {
    final file = await item.file();
    if (file == null) throw Exception('could not read ${item.name}');
    await _dirs(path);
    final req = http.StreamedRequest('PUT', _uri(path))
      ..headers.addAll({..._auth, 'Content-Type': item.mimeType ?? 'application/octet-stream'})
      ..contentLength = await file.length();
    file.openRead().listen(req.sink.add, onDone: req.sink.close, onError: req.sink.addError);
    final res = await http.Response.fromStream(await _client.send(req));
    _check(res, 'uploading ${item.name}');
    return path;
  }

  @override
  Future<String> move(FileRecord r, String path) async {
    await _dirs(path);
    final res =
        await _send('MOVE', _uri(r.fileName), headers: {'Destination': _uri(path).toString(), 'Overwrite': 'F'});
    _check(res, 'moving ${r.fileName}');
    return path;
  }

  @override
  Future<bool> exists(FileRecord r) async {
    final res = await _send('PROPFIND', _uri(r.fileName), headers: {'Depth': '0'});
    if (res.statusCode == 404) return false;
    _check(res, 'checking ${r.fileName}');
    return true;
  }

  Uri _album(String title, [String? file]) =>
      Uri.parse('$_albumRoot/${Uri.encodeComponent(title)}${file == null ? '' : '/${Uri.encodeComponent(file)}'}');

  static String _base(String path) => path.split('/').last;

  @override
  Future<void> filed(FileRecord now, FileRecord? before) async {
    if (!_albums || now.album == null) return;
    if (before?.album != null && before!.album != now.album) {
      // Nextcloud names album entries "<file id>-<name>": find this photo's entry in the old album.
      final list = await _send('PROPFIND', _album(before.album!), headers: {'Depth': '1'});
      final name = Uri.encodeComponent(_base(before.fileName));
      for (final m in RegExp(r'<(?:\w+:)?href>([^<]+)</(?:\w+:)?href>').allMatches(list.body)) {
        final href = m[1]!;
        final last = href.split('/').last;
        if (last == name || last.endsWith('-$name')) {
          final res = await _send('DELETE', Uri.parse(root).replace(path: href));
          if (res.statusCode >= 400 && res.statusCode != 404) _check(res, 'taking it out of album ${before.album}');
        }
      }
      _emptied.add(before.album!);
    }
    final mk = await _send('MKCOL', _album(now.album!));
    if (mk.statusCode >= 400 && mk.statusCode != 405) _check(mk, 'making album ${now.album}');
    final res = await _send('COPY', _uri(now.fileName),
        headers: {'Destination': _album(now.album!, _base(now.fileName)).toString(), 'Overwrite': 'F'});
    // 409/412: already in the album.
    if (res.statusCode >= 400 && res.statusCode != 409 && res.statusCode != 412) {
      _check(res, 'adding it to album ${now.album}');
    }
  }

  /// Albums a rename or move left empty are removed.
  @override
  Future<void> finish() async {
    for (final title in _emptied) {
      final res = await _send('PROPFIND', _album(title), headers: {'Depth': '1'});
      if (res.statusCode != 207) continue;
      // Only the album itself in the listing: empty.
      if (RegExp(r'<(\w+:)?response[ >]').allMatches(res.body).length <= 1) await _send('DELETE', _album(title));
    }
  }

  @override
  void close() {
    _client.close();
    clearFileCache();
  }
}

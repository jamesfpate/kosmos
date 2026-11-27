import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

import 'models.dart';
import 'store.dart';

// ownCloud / Nextcloud (or any WebDAV server): kept photos go into <folder>/YYYY/YYYY-MM name/file, folders made as
// needed; a photo whose album changes is MOVEd. Use an app password (Nextcloud: Settings > Security > Devices &
// sessions; ownCloud: Settings > Security > App passwords).

class WebDavConfig {
  const WebDavConfig({
    this.url = '',
    this.user = '',
    this.password = '',
    this.folder = 'Photos/',
    this.enabled = false,
    this.wifiOnly = false,
    this.videos = true,
    this.background = 'off',
  });

  /// The server's WebDAV address, or just the server (https://cloud.example.com): the Nextcloud/ownCloud path is
  /// added for you.
  final String url;
  final String user;
  final String password;
  final String folder;
  final bool enabled;
  final bool wifiOnly;
  final bool videos;
  final String background;

  bool get ready => url.isNotEmpty && user.isNotEmpty && password.isNotEmpty;

  /// The user's files root: given as is when it already points into /remote.php/ (or any other DAV path).
  String get root {
    var u = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (u.isNotEmpty && !RegExp(r'^https?://').hasMatch(u)) u = 'https://$u';
    final path = Uri.tryParse(u)?.path ?? '';
    if (path.isEmpty || path == '/') u = '$u/remote.php/dav/files/${Uri.encodeComponent(user.trim())}';
    return u;
  }

  WebDavConfig copyWith({
    String? url,
    String? user,
    String? password,
    String? folder,
    bool? enabled,
    bool? wifiOnly,
    bool? videos,
    String? background,
  }) =>
      WebDavConfig(
        url: url ?? this.url,
        user: user ?? this.user,
        password: password ?? this.password,
        folder: folder ?? this.folder,
        enabled: enabled ?? this.enabled,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        videos: videos ?? this.videos,
        background: background ?? this.background,
      );

  Map<String, Object?> toJson() => {
        'url': url,
        'user': user,
        'password': password,
        'folder': folder,
        'enabled': enabled,
        'wifiOnly': wifiOnly,
        'videos': videos,
        'background': background,
      };

  static WebDavConfig fromJson(Map<String, Object?>? j) => j == null
      ? const WebDavConfig()
      : WebDavConfig(
          url: (j['url'] as String?) ?? '',
          user: (j['user'] as String?) ?? '',
          password: (j['password'] as String?) ?? '',
          folder: (j['folder'] as String?) ?? 'Photos/',
          enabled: j['enabled'] == true,
          wifiOnly: j['wifiOnly'] == true,
          videos: j['videos'] != false,
          background: (j['background'] as String?) ?? 'off',
        );
}

class WebDavApi implements FileStore {
  WebDavApi(this.cfg);

  final WebDavConfig cfg;
  final _client = http.Client();
  final _made = <String>{};

  Map<String, String> get _auth =>
      {'Authorization': 'Basic ${base64Encode(utf8.encode('${cfg.user.trim()}:${cfg.password.trim()}'))}'};

  Uri _uri(String path) =>
      Uri.parse('${cfg.root}/${path.split('/').where((p) => p.isNotEmpty).map(Uri.encodeComponent).join('/')}');

  Future<http.Response> _send(String method, String path, {Map<String, String> headers = const {}}) async {
    final req = http.Request(method, _uri(path))..headers.addAll({..._auth, ...headers});
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
    final res = await _send('PROPFIND', '', headers: {'Depth': '0'});
    _check(res, 'connecting to ${cfg.root}');
    return cfg.root;
  }

  /// Makes each folder of [path]'s directory that doesn't exist yet.
  Future<void> _dirs(String path) async {
    final parts = path.split('/')..removeLast();
    var at = '';
    for (final p in parts.where((p) => p.isNotEmpty)) {
      at = at.isEmpty ? p : '$at/$p';
      if (_made.contains(at)) continue;
      final res = await _send('MKCOL', at);
      // 405: already there.
      if (res.statusCode >= 400 && res.statusCode != 405) _check(res, 'making folder $at');
      _made.add(at);
    }
  }

  @override
  Future<String> upload(Item item, String path) async {
    final file = await item.entity.originFile;
    if (file == null) throw Exception('could not read ${item.name}');
    await _dirs(path);
    final req = http.StreamedRequest('PUT', _uri(path))
      ..headers.addAll({..._auth, 'Content-Type': item.entity.mimeType ?? 'application/octet-stream'})
      ..contentLength = await file.length();
    file.openRead().listen(req.sink.add, onDone: req.sink.close, onError: req.sink.addError);
    final res = await http.Response.fromStream(await _client.send(req));
    _check(res, 'uploading ${item.name}');
    return path;
  }

  @override
  Future<String> move(FileRecord r, String path) async {
    await _dirs(path);
    final res = await _send('MOVE', r.fileName, headers: {'Destination': _uri(path).toString(), 'Overwrite': 'F'});
    _check(res, 'moving ${r.fileName}');
    return path;
  }

  @override
  Future<bool> exists(FileRecord r) async {
    final res = await _send('PROPFIND', r.fileName, headers: {'Depth': '0'});
    if (res.statusCode == 404) return false;
    _check(res, 'checking ${r.fileName}');
    return true;
  }

  @override
  void close() {
    _client.close();
    PhotoManager.clearFileCache();
  }
}

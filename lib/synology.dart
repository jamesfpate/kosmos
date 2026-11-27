import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'store.dart';

// Synology Photos (DSM 7, personal space): kept photos upload into folders laid out like the other stores
// (Folder/YYYY/YYYY-MM name/), and into albums of the same names; moving a photo or renaming an album updates the
// albums (the file stays in the folder it was first uploaded to).
//
// Synology doesn't document the Photos API. Everything here goes through /webapi/entry.cgi. Where each call's shape
// comes from:
// - SYNO.API.Auth v6: Synology's DSM Login Web API guide (otp_code, device tokens).
// - SYNO.Foto.Browse.NormalAlbum create / add_item / delete_item and SYNO.Foto.Browse.Album delete: community clients
//   that checked them against a real NAS (sahilagnihotri/synology-native-photos, DSM 7.3).
// - SYNO.Foto.Browse.Album set_name, SYNO.Foto.Browse.Folder get / list / create and SYNO.Foto.Browse.Item get / list:
//   community clients (N4S4/synology-api, pfilbin90/nas-google-sync, finia2NA/cirrusphotos notes).
// - SYNO.Foto.Upload.Item upload_to_folder (target_folder_id, name, mtime, duplicate, file): from the Photos web
//   app, as recorded by finia2NA/cirrusphotos.
// String values go JSON-encoded ("name": "\"IMG_1.jpg\""), the way the Photos web app sends them.

const synologyDef = StoreDef(
  key: 'synology',
  title: 'Synology Photos',
  label: 'Synology',
  intro: [
    'Kept photos upload, original files, into your Synology Photos personal space: into folders by year and album '
        '(Folder/2026/2026-11 Thanksgiving/), and into albums of the same names. Moving a photo or renaming an album '
        'updates the albums. Deleted photos are never uploaded.',
    'Server: your NAS address with its DSM port, e.g. https://nas.example.com:5001, or http://192.168.1.10:5000 at '
        'home. QuickConnect addresses don\'t work, and https needs a valid certificate.',
    'Two-step sign-in: enter the current code once when you save; Winnow then remembers this phone as a trusted '
        'device.',
  ],
  fields: [
    FieldDef('url', 'Server', 'https://nas.example.com:5001', url: true),
    FieldDef('user', 'User name', 'james'),
    FieldDef('password', 'Password', 'password', secret: true),
    FieldDef('otp', 'Two-step code (only if your account has one)', '123456', optional: true),
    FieldDef('did', 'Trusted device token', '', hidden: true, optional: true),
  ],
  folderLabel: 'Folder in Synology Photos',
  albums: _make,
);

AlbumService _make(StoreConfig c, void Function(String, String) remember) => SynologyApi(c, remember);

class SynologyApi implements AlbumService {
  SynologyApi(this.cfg, this.remember);

  final StoreConfig cfg;
  final void Function(String key, String value) remember;
  final _client = http.Client();
  String? _sid;
  String? _token;
  Map<String, ({int min, int max})>? _versions;

  /// Album id -> its title, from [ensureAlbum] (an upload goes into the folder named after its album).
  final _titles = <String, String>{};

  /// Folder path ("/2026/2026-11 Thanksgiving") -> folder id.
  final _folders = <String, int>{};

  /// Folder id -> the files already in it, by name.
  final _files = <int, Map<String, ({int id, int size})>>{};

  String get _base {
    var u = cfg['url'].trim().replaceAll(RegExp(r'/+$'), '');
    if (u.isNotEmpty && !RegExp(r'^https?://').hasMatch(u)) u = 'https://$u';
    return u;
  }

  Uri get _entry => Uri.parse('$_base/webapi/entry.cgi');

  Map<String, String> get _headers => {
        'X-SYNO-TOKEN': ?_token,
        if (_sid != null) 'Cookie': 'id=$_sid',
      };

  /// One API call. [params] values that aren't strings are JSON-encoded; strings are sent as JSON strings unless
  /// [raw] (Auth takes plain values).
  Future<Map> _call(String api, String method, int version, Map<String, Object?> params,
      {bool raw = false, bool retry = true}) async {
    final body = <String, String>{
      'api': api,
      'method': method,
      'version': '$version',
      '_sid': ?_sid,
      for (final e in params.entries)
        if (e.value != null) e.key: e.value is String && raw ? e.value as String : jsonEncode(e.value),
    };
    final res = await _client.post(_entry, headers: _headers, body: body);
    if (res.statusCode >= 400) throw SynologyError(api, res.statusCode, res.body);
    final j = jsonDecode(res.body) as Map;
    if (j['success'] == true) return (j['data'] as Map?) ?? {};
    final code = ((j['error'] as Map?)?['code'] as num?)?.toInt() ?? -1;
    // 119: session expired or invalid. Sign in again once.
    if (code == 119 && retry && api != 'SYNO.API.Auth') {
      _sid = null;
      _token = null;
      await authorize();
      return _call(api, method, version, params, raw: raw, retry: false);
    }
    throw SynologyError(api, code, _message(api, code));
  }

  /// The version to call [api] with: [want], kept inside the range the server offers.
  Future<int> _v(String api, int want) async {
    _versions ??= await _apiInfo();
    final range = _versions![api];
    if (range == null) {
      throw Exception('Synology: Synology Photos isn\'t installed on this NAS, or this account can\'t use it');
    }
    return want.clamp(range.min, range.max);
  }

  Future<Map<String, ({int min, int max})>> _apiInfo() async {
    final d = await _call('SYNO.API.Info', 'query', 1, {'query': 'all'}, raw: true);
    return {
      for (final e in d.entries)
        if ((e.key as String).startsWith('SYNO.Foto.'))
          e.key as String: (
            min: (((e.value as Map)['minVersion'] as num?) ?? 1).toInt(),
            max: ((e.value as Map)['maxVersion'] as num).toInt(),
          ),
    };
  }

  @override
  Future<String> authorize() async {
    if (_sid != null) return _base;
    final otp = cfg['otp'].replaceAll(' ', '');
    final did = cfg['did'];
    final Map d;
    try {
      d = await _call(
          'SYNO.API.Auth',
          'login',
          6,
          {
            'account': cfg['user'].trim(),
            'passwd': cfg['password'],
            'session': 'webui',
            'format': 'sid',
            'enable_syno_token': 'yes',
            if (otp.isNotEmpty) 'otp_code': otp,
            if (otp.isNotEmpty) 'enable_device_token': 'yes',
            if (otp.isNotEmpty) 'device_name': 'Winnow',
            if (otp.isEmpty && did.isNotEmpty) 'device_id': did,
          },
          raw: true);
    } on SynologyError catch (e) {
      // A trusted-device token that stopped working (removed in DSM): forget it so the user is asked for a code.
      if (e.code == 403 && did.isNotEmpty) remember('did', '');
      rethrow;
    }
    _sid = d['sid'] as String?;
    _token = d['synotoken'] as String?;
    if (_sid == null) throw Exception('Synology: signed in, but the NAS sent no session');
    if (otp.isNotEmpty) {
      // The code is single-use; the device token (v6 "did", v7 "device_id") replaces it from now on.
      final token = (d['did'] ?? d['device_id']) as String?;
      if (token != null && token.isNotEmpty) remember('did', token);
      remember('otp', '');
    }
    await _v('SYNO.Foto.Upload.Item', 1);
    return '${cfg['user']} on ${cfg['url']}';
  }

  /// The folder (inside the personal space) an album's photos go in: Folder/YYYY/YYYY-MM name, or
  /// Folder/Albums/name. The personal space already is the Photos folder, so a leading "Photos/" is dropped.
  String _dirFor(String title) {
    var root = cfg.folder.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (root == 'Photos') root = '';
    if (root.startsWith('Photos/')) root = root.substring(7);
    final year = RegExp(r'^(\d{4})-\d{2}\b').firstMatch(title)?[1];
    return ['', if (root.isNotEmpty) root, year ?? 'Albums', title.replaceAll('/', '-').trim()].join('/');
  }

  /// The id of [path] ("/2026/2026-11 Thanksgiving"), creating the missing folders.
  Future<int> _folderId(String path) async {
    if (_folders.containsKey(path)) return _folders[path]!;
    final v = await _v('SYNO.Foto.Browse.Folder', 2);
    if (path.isEmpty || path == '/') {
      final d = await _call('SYNO.Foto.Browse.Folder', 'get', v, {'id': 0});
      return _folders[path] = ((d['folder'] as Map)['id'] as num).toInt();
    }
    final cut = path.lastIndexOf('/');
    final parentPath = cut <= 0 ? '/' : path.substring(0, cut);
    final name = path.substring(cut + 1);
    final parent = await _folderId(parentPath);
    // Folder names come back as full paths ("/2026/2026-11 Thanksgiving").
    for (var offset = 0;; offset += 1000) {
      final d = await _call('SYNO.Foto.Browse.Folder', 'list', v, {'id': parent, 'offset': offset, 'limit': 1000});
      final list = ((d['list'] as List?) ?? const []).cast<Map>();
      for (final f in list) {
        final fname = f['name'] as String;
        _folders[fname] = (f['id'] as num).toInt();
      }
      if (_folders.containsKey(path)) return _folders[path]!;
      if (list.length < 1000) break;
    }
    final d = await _call('SYNO.Foto.Browse.Folder', 'create', await _v('SYNO.Foto.Browse.Folder', 1),
        {'name': name, 'target_id': parent});
    return _folders[path] = ((d['folder'] as Map)['id'] as num).toInt();
  }

  /// The files already in [folder], by name.
  Future<Map<String, ({int id, int size})>> _filesIn(int folder, {bool fresh = false}) async {
    if (!fresh && _files.containsKey(folder)) return _files[folder]!;
    final v = await _v('SYNO.Foto.Browse.Item', 7);
    final out = <String, ({int id, int size})>{};
    for (var offset = 0;; offset += 1000) {
      final d = await _call('SYNO.Foto.Browse.Item', 'list', v,
          {'folder_id': folder, 'offset': offset, 'limit': 1000, 'additional': <String>[]});
      final list = ((d['list'] as List?) ?? const []).cast<Map>();
      for (final i in list) {
        out[i['filename'] as String] = (id: (i['id'] as num).toInt(), size: ((i['filesize'] as num?) ?? -1).toInt());
      }
      if (list.length < 1000) break;
    }
    return _files[folder] = out;
  }

  @override
  Future<String> upload(Item item, String albumId) async {
    await authorize();
    final file = await item.file();
    if (file == null) throw Exception('could not read ${item.name}');
    final size = await file.length();
    final title = _titles[albumId] ?? await _albumName(albumId) ?? 'Winnow';
    final folder = await _folderId(_dirFor(title));
    final present = await _filesIn(folder);

    // Already uploaded (an earlier sync stopped before recording it): same name, same size. A different photo with
    // the same name (two cameras both make IMG_0001.JPG) gets the photo's id added to its name.
    var name = item.name.replaceAll('/', '-');
    var same = present[name];
    if (same != null && same.size != size) {
      // Phone ids are short numbers; a computer's are file paths, so those get a short hash instead.
      final tag = RegExp(r'^[A-Za-z0-9_-]{1,24}$').hasMatch(item.id)
          ? item.id
          : '${sha1.convert(utf8.encode(item.id))}'.substring(0, 8);
      name = withSuffix(name, tag);
      same = present[name];
    }
    int? id = same != null && same.size == size ? same.id : null;

    if (id == null) {
      final res = await _multipart({
        'api': 'SYNO.Foto.Upload.Item',
        'method': 'upload_to_folder',
        'version': '${await _v('SYNO.Foto.Upload.Item', 1)}',
        '_sid': _sid!,
        'target_folder_id': '$folder',
        'name': jsonEncode(name),
        'mtime': '${item.taken ~/ 1000}',
        'duplicate': jsonEncode('ignore'),
      }, file, name);
      if (res.statusCode >= 400) throw SynologyError('SYNO.Foto.Upload.Item', res.statusCode, res.body);
      final j = jsonDecode(res.body) as Map;
      if (j['success'] != true) {
        final code = ((j['error'] as Map?)?['code'] as num?)?.toInt() ?? -1;
        throw SynologyError('SYNO.Foto.Upload.Item', code, _message('SYNO.Foto.Upload.Item', code));
      }
      final d = (j['data'] as Map?) ?? {};
      id = (d['id'] as num?)?.toInt();
      // Not in the reply: look for it in the folder (the NAS indexes uploads in the background).
      for (var attempt = 0; id == null && attempt < 6; attempt++) {
        if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
        id = (await _filesIn(folder, fresh: true))[name]?.id;
      }
      if (id == null) throw Exception('Synology: uploaded ${item.name} but could not find it afterwards');
      present[name] = (id: id, size: size);
    }
    await add(albumId, ['$id']);
    return '$id';
  }

  /// A multipart POST built by hand: DSM rejects http's MultipartRequest (error 108, upload_err -5), which puts each
  /// part's Content-Type before its Content-Disposition. The file is streamed, not read into memory.
  Future<http.Response> _multipart(Map<String, String> fields, File file, String name) async {
    const boundary = 'WinnowFormBoundary7MA4YWxkTrZu0gW';
    final head = StringBuffer();
    for (final e in fields.entries) {
      head.write('--$boundary\r\nContent-Disposition: form-data; name="${e.key}"\r\n\r\n${e.value}\r\n');
    }
    head.write('--$boundary\r\nContent-Disposition: form-data; name="file"; '
        'filename="${name.replaceAll('"', '%22')}"\r\nContent-Type: application/octet-stream\r\n\r\n');
    final start = utf8.encode('$head');
    final end = utf8.encode('\r\n--$boundary--\r\n');
    final req = http.StreamedRequest('POST', _entry)
      ..headers.addAll({..._headers, 'Content-Type': 'multipart/form-data; boundary=$boundary'})
      ..contentLength = start.length + await file.length() + end.length;
    final sent = _client.send(req);
    req.sink.add(start);
    await req.sink.addStream(file.openRead());
    req.sink.add(end);
    await req.sink.close();
    return http.Response.fromStream(await sent);
  }

  Future<String?> _albumName(String id) async {
    final d = await _call('SYNO.Foto.Browse.Album', 'get', await _v('SYNO.Foto.Browse.Album', 2), {
      'id': [int.parse(id)],
    });
    final list = ((d['list'] as List?) ?? const []).cast<Map>();
    return list.isEmpty ? null : list.first['name'] as String?;
  }

  @override
  Future<String> ensureAlbum(String title, String? known) async {
    await authorize();
    if (known != null) {
      final name = await _albumName(known);
      if (name != null) {
        if (name != title) {
          await _call('SYNO.Foto.Browse.Album', 'set_name', 1, {'id': int.parse(known), 'name': title});
        }
        return _remember(known, title);
      }
    }
    // An album of that name made by an earlier install, or by hand: use it rather than making a second one.
    final v = await _v('SYNO.Foto.Browse.Album', 4);
    for (var offset = 0;; offset += 500) {
      final d = await _call('SYNO.Foto.Browse.Album', 'list', v,
          {'offset': offset, 'limit': 500, if (v >= 2) 'category': 'normal'});
      final list = ((d['list'] as List?) ?? const []).cast<Map>();
      for (final a in list) {
        if (a['name'] == title && (a['type'] == null || a['type'] == 'normal')) {
          return _remember('${(a['id'] as num).toInt()}', title);
        }
      }
      if (list.length < 500) break;
    }
    final d = await _call('SYNO.Foto.Browse.NormalAlbum', 'create', 1, {'name': title, 'item': <int>[]});
    return _remember('${((d['album'] as Map)['id'] as num).toInt()}', title);
  }

  String _remember(String id, String title) {
    _titles[id] = title;
    return id;
  }

  @override
  Future<void> add(String albumId, List<String> ids) async {
    await authorize();
    if (ids.isEmpty) return;
    final d = await _call('SYNO.Foto.Browse.NormalAlbum', 'add_item', 1, {
      'id': int.parse(albumId),
      'item': [for (final i in ids) int.parse(i)],
    });
    final failed = (d['error_list'] as List?) ?? const [];
    if (failed.isNotEmpty) throw Exception('Synology: could not add ${failed.length} photo(s) to the album');
  }

  @override
  Future<void> remove(String albumId, List<String> ids) async {
    await authorize();
    if (ids.isEmpty) return;
    await _call('SYNO.Foto.Browse.NormalAlbum', 'delete_item', 1, {
      'id': int.parse(albumId),
      'item': [for (final i in ids) int.parse(i)],
    });
  }

  @override
  Future<bool> exists(String id) async {
    await authorize();
    // Unknown or deleted ids are left out of the list (no error).
    final d = await _call('SYNO.Foto.Browse.Item', 'get', await _v('SYNO.Foto.Browse.Item', 7), {
      'id': [int.parse(id)],
    });
    return ((d['list'] as List?) ?? const []).isNotEmpty;
  }

  @override
  void close() {
    final sid = _sid;
    if (sid != null) {
      // Best effort; the session would expire anyway.
      _client
          .post(_entry, body: {'api': 'SYNO.API.Auth', 'method': 'logout', 'version': '6', 'session': 'webui', '_sid': sid})
          .whenComplete(_client.close)
          .ignore();
    } else {
      _client.close();
    }
    clearFileCache();
  }
}

String _message(String api, int code) {
  if (api == 'SYNO.API.Auth') {
    return switch (code) {
      400 => 'wrong user name or password',
      401 => 'this account is disabled',
      402 => 'this account isn\'t allowed to sign in',
      403 => 'this account uses two-step sign-in: enter the current code under "Two-step code" and save again',
      404 => 'the two-step code was wrong or expired; enter a new one',
      406 => 'the NAS requires two-step sign-in for this account; set it up in DSM, then enter a code here',
      407 => 'too many failed sign-ins: this address is blocked for a while (DSM → Security → Account)',
      _ => 'sign-in failed (error $code)',
    };
  }
  return switch (code) {
    102 || 103 || 104 => 'this Synology Photos version doesn\'t support a call Winnow makes (error $code)',
    105 => 'this account doesn\'t have permission (error 105); check it can use Synology Photos',
    119 => 'the session expired (error 119)',
    120 => 'the NAS rejected a request (error 120)',
    _ => 'error $code',
  };
}

class SynologyError implements Exception {
  SynologyError(this.api, this.code, this.message);

  final String api;
  final int code;
  final String message;

  @override
  String toString() => 'Synology: $message';
}

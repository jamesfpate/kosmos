import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:photo_manager/photo_manager.dart';

import 'models.dart';

// Immich v3 API: POST /assets (multipart, streamed from the original file), albums, tags.

class ImmichConfig {
  const ImmichConfig({
    this.server = '',
    this.key = '',
    this.enabled = false,
    this.shareWith = const {},
    this.wifiOnly = false,
    this.videos = true,
    this.background = 'off',
  });

  /// Upload while Winnow is closed (Android, about every 15 minutes): 'off', 'charging' (only while charging) or
  /// 'always'.
  final String background;

  final String server;
  final String key;
  final bool enabled;

  /// Upload only on Wi-Fi (or ethernet); waits otherwise and starts when Wi-Fi comes back.
  final bool wifiOnly;

  /// Upload videos too (off: they stay on the phone only).
  final bool videos;

  /// Immich users (id -> name) every album is shared with, as editors (they can add photos too).
  final Map<String, String> shareWith;

  bool get ready => server.isNotEmpty && key.isNotEmpty;

  ImmichConfig copyWith(
          {String? server, String? key, bool? enabled, Map<String, String>? shareWith, bool? wifiOnly, bool? videos, String? background}) =>
      ImmichConfig(
        server: server ?? this.server,
        key: key ?? this.key,
        enabled: enabled ?? this.enabled,
        shareWith: shareWith ?? this.shareWith,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        videos: videos ?? this.videos,
        background: background ?? this.background,
      );

  Map<String, Object?> toJson() => {
        'server': server,
        'key': key,
        'enabled': enabled,
        'shareWith': shareWith,
        'wifiOnly': wifiOnly,
        'videos': videos,
        'background': background,
      };

  static ImmichConfig fromJson(Map<String, Object?>? j) => j == null
      ? const ImmichConfig()
      : ImmichConfig(
          server: (j['server'] as String?) ?? '',
          key: (j['key'] as String?) ?? '',
          enabled: j['enabled'] == true,
          shareWith: ((j['shareWith'] as Map?) ?? {}).cast<String, String>(),
          wifiOnly: j['wifiOnly'] == true,
          videos: j['videos'] != false,
          background: (j['background'] as String?) ?? 'off',
        );
}

/// What the API key must be allowed to do (Immich → Account settings → API keys).
const immichPermissions = [
  'asset.upload',
  'album.read',
  'album.create',
  'album.update',
  'albumAsset.create',
  'albumAsset.delete',
  'tag.create',
  'tag.asset',
];

/// For browsing Immich in Explorer (list, thumbnails, save to phone).
const immichBrowsePermissions = ['asset.read', 'asset.view', 'asset.download'];

/// Extra permissions for sharing albums (Share albums with).
const immichSharePermissions = ['user.read', 'albumUser.create'];

String cleanServer(String url) {
  var s = url.trim().replaceAll(RegExp(r'/+$'), '').replaceAll(RegExp(r'/api$'), '');
  if (s.isNotEmpty && !RegExp(r'^https?://').hasMatch(s)) s = 'https://$s';
  return s;
}

class ImmichApi {
  ImmichApi(this.cfg);

  final ImmichConfig cfg;
  final _client = http.Client();

  Uri _uri(String path) => Uri.parse('${cleanServer(cfg.server)}/api$path');

  /// Headers for loading Immich images directly (thumbnails in Explorer).
  Map<String, String> get imageHeaders => {'x-api-key': cfg.key};

  String thumbUrl(String assetId, {bool preview = false}) =>
      '${cleanServer(cfg.server)}/api/assets/$assetId/thumbnail?size=${preview ? 'preview' : 'thumbnail'}';

  /// The original file's bytes (for saving to the phone).
  Future<List<int>> download(String assetId) async {
    final res = await _client.get(_uri('/assets/$assetId/original'), headers: imageHeaders);
    if (res.statusCode >= 400) throw Exception('Immich ${res.statusCode}: could not download');
    return res.bodyBytes;
  }

  Map<String, String> get _headers =>
      {'x-api-key': cfg.key, 'Accept': 'application/json', 'Content-Type': 'application/json'};

  Future<dynamic> call(String method, String path, [Object? body]) async {
    final req = http.Request(method, _uri(path))..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _client.send(req));
    if (res.statusCode >= 400) {
      var msg = res.body;
      try {
        msg = '${(jsonDecode(res.body) as Map)['message']}';
      } catch (_) {}
      throw Exception('Immich ${res.statusCode}: ${msg.length > 200 ? msg.substring(0, 200) : msg}');
    }
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

  /// Checks the server and key; returns the key's name and any missing permissions (sharing ones only if sharing).
  Future<({String name, List<String> missing})> test() async {
    final key = await call('GET', '/api-keys/me') as Map;
    final perms = (key['permissions'] as List).cast<String>();
    final all = perms.contains('all');
    final need = [
      ...immichPermissions,
      ...immichBrowsePermissions,
      if (cfg.shareWith.isNotEmpty) ...immichSharePermissions,
    ];
    return (name: '${key['name']}', missing: all ? <String>[] : [for (final p in need) if (!perms.contains(p)) p]);
  }

  /// Everyone on the server except the key's owner (who can't share with themselves).
  Future<List<({String id, String name, String email})>> users() async {
    final me = await call('GET', '/users/me') as Map;
    final list = (await call('GET', '/users') as List).cast<Map>();
    return [
      for (final u in list)
        if (u['id'] != me['id']) (id: u['id'] as String, name: '${u['name']}', email: '${u['email']}'),
    ];
  }

  /// Adds the share-with users to an album as editors (skips anyone already in it).
  Future<void> share(String albumId) async {
    if (cfg.shareWith.isEmpty) return;
    final album = await call('GET', '/albums/$albumId') as Map;
    final present = {
      for (final au in (album['albumUsers'] as List? ?? []).cast<Map>()) (au['user'] as Map)['id'],
    };
    final add = [for (final id in cfg.shareWith.keys) if (!present.contains(id)) {'userId': id, 'role': 'editor'}];
    if (add.isNotEmpty) await call('PUT', '/albums/$albumId/users', {'albumUsers': add});
  }

  /// Uploads the original file (location kept when Winnow has media location access). Returns the Immich asset id.
  Future<String> upload(Item item) async {
    final file = await item.entity.originFile;
    if (file == null) throw Exception('could not read ${item.name}');
    final when = DateTime.fromMillisecondsSinceEpoch(item.taken).toUtc().toIso8601String();
    final mime = item.entity.mimeType ?? (item.isVideo ? 'video/mp4' : 'image/jpeg');
    final req = http.MultipartRequest('POST', _uri('/assets'))
      ..headers.addAll({'x-api-key': cfg.key, 'Accept': 'application/json'})
      ..fields['fileCreatedAt'] = when
      ..fields['fileModifiedAt'] = when
      ..fields['filename'] = item.name;
    if (item.isVideo && item.entity.duration > 0) req.fields['duration'] = '${item.entity.duration * 1000}';
    req.files.add(await http.MultipartFile.fromPath('assetData', file.path,
        filename: item.name, contentType: MediaType.parse(mime)));
    final res = await http.Response.fromStream(await _client.send(req));
    if (res.statusCode >= 400) throw Exception('Immich ${res.statusCode}: ${res.body}');
    return (jsonDecode(res.body) as Map)['id'] as String;
  }

  /// The Immich album for a Winnow album: remembered id, else one with the same name, else a new one.
  Future<String> ensureAlbum(Album album) async {
    final name = albumTitle(album);
    if (album.immichAlbumId != null) {
      try {
        final found = (await call('GET', '/albums?id=${album.immichAlbumId}') as List).cast<Map>();
        final mine = found.where((a) => a['id'] == album.immichAlbumId).firstOrNull;
        if (mine != null) {
          // Renamed in Winnow while Immich couldn't be reached: catch up.
          if (mine['albumName'] != name) await call('PATCH', '/albums/${album.immichAlbumId}', {'albumName': name});
          return album.immichAlbumId!;
        }
      } catch (_) {}
    }
    final same = await call('GET', '/albums?name=${Uri.encodeQueryComponent(name)}') as List;
    final match = same.cast<Map>().where((a) => a['albumName'] == name).firstOrNull;
    final id = (match ?? await call('POST', '/albums', {'albumName': name}) as Map)['id'] as String;
    album.immichAlbumId = id;
    return id;
  }

  /// Every album the key's owner can see (own and shared with them).
  Future<List<({String id, String name, DateTime? start, DateTime? end})>> albums() async {
    final list = (await call('GET', '/albums') as List).cast<Map>();
    return [
      for (final a in list)
        (
          id: a['id'] as String,
          name: '${a['albumName']}',
          start: DateTime.tryParse('${a['startDate']}')?.toLocal(),
          end: DateTime.tryParse('${a['endDate']}')?.toLocal(),
        ),
    ];
  }

  final _tagIds = <String, String>{};

  /// Creates the tag path if needed (Immich makes the parents) and returns the leaf tag's id.
  Future<String> ensureTag(String path) async {
    final cached = _tagIds[path];
    if (cached != null) return cached;
    final tags = (await call('PUT', '/tags', {
      'tags': [path]
    }) as List)
        .cast<Map>();
    final tag = tags.where((t) => t['value'] == path).firstOrNull ?? tags.lastOrNull;
    if (tag == null) throw Exception('Immich did not return the tag $path');
    return _tagIds[path] = tag['id'] as String;
  }

  Future<void> addToAlbum(String albumId, List<String> assetIds) async {
    for (var i = 0; i < assetIds.length; i += 500) {
      await call('PUT', '/albums/$albumId/assets', {'ids': assetIds.sublist(i, (i + 500).clamp(0, assetIds.length))});
    }
  }

  Future<void> tag(String tagId, List<String> assetIds) async {
    for (var i = 0; i < assetIds.length; i += 500) {
      await call('PUT', '/tags/assets', {
        'tagIds': [tagId],
        'assetIds': assetIds.sublist(i, (i + 500).clamp(0, assetIds.length)),
      });
    }
  }

  void close() {
    _client.close();
    PhotoManager.clearFileCache();
  }
}

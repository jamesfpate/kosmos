import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'immich.dart';
import 'models.dart';
import 'state.dart';

// Explorer's Immich source: the server's photos (all, only those not on this phone, or one album), paged as you
// scroll; add to / move between albums in Immich, or save to the phone.

/// Explorer views for Immich ([AppState.gridView]).
const immichAll = 'immich:all';
const immichOnly = 'immich:only';
const immichAlbumPrefix = 'immich:album:';

bool isImmichView(String v) => v.startsWith('immich:');

class RemoteAsset {
  RemoteAsset({required this.id, required this.name, required this.taken, required this.aspect, required this.isVideo});

  final String id;
  final String name;
  final int taken;
  final double aspect;
  final bool isVideo;

  /// Also on this phone (uploaded by Winnow, or same file name and day as a phone photo).
  bool onPhone = false;

  static RemoteAsset fromJson(Map j) {
    final w = (j['width'] as num?)?.toDouble() ?? 0, h = (j['height'] as num?)?.toDouble() ?? 0;
    final when = DateTime.tryParse('${j['fileCreatedAt']}') ?? DateTime.tryParse('${j['localDateTime']}');
    return RemoteAsset(
      id: j['id'] as String,
      name: '${j['originalFileName']}',
      taken: when?.millisecondsSinceEpoch ?? 0,
      aspect: w > 0 && h > 0 ? (w / h).clamp(0.4, 2.5) : 3 / 4,
      isVideo: j['type'] == 'VIDEO',
    );
  }
}

String _key(String name, int taken) {
  final d = DateTime.fromMillisecondsSinceEpoch(taken);
  return '${name.toLowerCase()}|${d.year}-${d.month}-${d.day}';
}

class ImmichBrowser extends ChangeNotifier {
  ImmichBrowser(this.s, this.view) : api = ImmichApi(s.immich);

  final AppState s;
  final String view;
  final ImmichApi api;

  final assets = <RemoteAsset>[];
  List<({String id, String name, DateTime? start, DateTime? end})> albums = [];
  Set<String> sel = {};
  bool loading = false;
  bool busy = false;
  String error = '';
  String message = '';
  int? _next = 1;
  Set<String> _uploaded = {};
  Set<String> _local = {};
  bool _disposed = false;

  String? get albumId => view.startsWith(immichAlbumPrefix) ? view.substring(immichAlbumPrefix.length) : null;
  bool get onlyRemote => view == immichOnly;
  bool get done => _next == null;

  String get title {
    if (view == immichAll) return 'Everything on Immich';
    if (onlyRemote) return 'Only on Immich';
    return albums.where((a) => a.id == albumId).firstOrNull?.name ?? 'Immich album';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    _uploaded = {for (final j in await s.db.all('uploads')) UploadRecord.fromJson(j).assetId};
    _local = {for (final i in s.items) _key(i.name, i.taken)};
    try {
      albums = (await api.albums())..sort((a, b) => b.name.compareTo(a.name));
    } catch (_) {}
    await more();
  }

  /// The next page (250 photos, newest first). "Only on Immich" keeps loading until it has a screenful.
  Future<void> more() async {
    if (loading || _next == null || _disposed) return;
    loading = true;
    _notify();
    var added = 0;
    try {
      final res = await api.call('POST', '/search/metadata', {
        'page': _next,
        'size': 250,
        'order': 'desc',
        'albumIds': ?(albumId == null ? null : [albumId]),
      }) as Map;
      final page = (res['assets'] as Map);
      for (final j in (page['items'] as List).cast<Map>()) {
        final a = RemoteAsset.fromJson(j)..onPhone = false;
        a.onPhone = _uploaded.contains(a.id) || _local.contains(_key(a.name, a.taken));
        if (onlyRemote && a.onPhone) continue;
        assets.add(a);
        added++;
      }
      _next = int.tryParse('${page['nextPage']}');
      error = '';
    } catch (e) {
      error = '$e'.replaceFirst('Exception: ', '');
      _next = null;
    } finally {
      loading = false;
      _notify();
    }
    if (onlyRemote && added < 40 && _next != null) await more();
  }

  void toggle(String id) {
    sel = sel.contains(id) ? ({...sel}..remove(id)) : {...sel, id};
    _notify();
  }

  void clear() {
    sel = {};
    _notify();
  }

  Album? _winnowAlbum(String immichId) => s.albums.where((a) => a.immichAlbumId == immichId).firstOrNull;

  /// Adds the selected photos to an Immich album; in an album view they move (out of the current album and its tag).
  Future<void> fileInto(String targetId) async {
    if (sel.isEmpty || busy || targetId == albumId) return;
    busy = true;
    _notify();
    final ids = [...sel];
    try {
      await api.addToAlbum(targetId, ids);
      final target = _winnowAlbum(targetId);
      if (target != null) await api.tag(await api.ensureTag(albumTag(target)), ids);
      final from = albumId;
      if (from != null) {
        await api.call('DELETE', '/albums/$from/assets', {'ids': ids});
        final old = _winnowAlbum(from);
        if (old != null) await api.call('DELETE', '/tags/${await api.ensureTag(albumTag(old))}/assets', {'ids': ids});
        assets.removeWhere((a) => ids.contains(a.id));
      }
      final name = albums.where((a) => a.id == targetId).firstOrNull?.name ?? 'the album';
      message = '${from != null ? 'Moved' : 'Added'} ${ids.length} to $name';
      sel = {};
    } catch (e) {
      message = 'Failed: ${'$e'.replaceFirst('Exception: ', '')}';
    } finally {
      busy = false;
      _notify();
    }
  }

  /// Downloads the selected photos into the phone's gallery. They're remembered as already in Immich (and, in an
  /// album view, as filed into that album) so Winnow doesn't upload or ask about them again.
  Future<void> saveToPhone() async {
    if (sel.isEmpty || busy) return;
    busy = true;
    _notify();
    final chosen = assets.where((a) => sel.contains(a.id)).toList();
    final album = albumId == null ? null : _winnowAlbum(albumId!);
    var saved = 0;
    try {
      final tmp = await getTemporaryDirectory();
      for (final a in chosen) {
        message = 'Saving ${saved + 1} of ${chosen.length}…';
        _notify();
        final bytes = Uint8List.fromList(await api.download(a.id));
        AssetEntity entity;
        if (a.isVideo) {
          final f = File('${tmp.path}/${a.name}');
          await f.writeAsBytes(bytes);
          entity = await PhotoManager.editor.saveVideo(f, title: a.name, creationDate: DateTime.fromMillisecondsSinceEpoch(a.taken));
          await f.delete();
        } else {
          entity = await PhotoManager.editor.saveImage(bytes,
              filename: a.name, title: a.name, creationDate: DateTime.fromMillisecondsSinceEpoch(a.taken));
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        await s.db.put('uploads', entity.id,
            UploadRecord(id: entity.id, assetId: a.id, uploadedAt: now, syncedAlbumId: album?.id).toJson());
        if (album != null) {
          await s.db.put('decisions', entity.id,
              DecisionRecord(id: entity.id, decision: Decision.keep, decidedAt: now, albumId: album.id).toJson());
        }
        a.onPhone = true;
        saved++;
      }
      message = 'Saved $saved to the phone';
      sel = {};
      await s.reload();
    } catch (e) {
      message = 'Saved $saved; then failed: ${'$e'.replaceFirst('Exception: ', '')}';
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    api.close();
    super.dispose();
  }
}

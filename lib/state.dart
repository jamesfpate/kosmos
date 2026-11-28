import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'gphotos.dart';
import 'db.dart';
import 'fx.dart';
import 'immich.dart';
import 'media.dart' as media;
import 'media.dart' show Access;
import 'background.dart';
import 'models.dart';
import 'store.dart';
import 'stores.dart';
import 'support.dart';

enum Screen { loading, access, start, cull, grid, explore, trash, settings, immich, store, google, error }

enum Dir { left, right }

typedef UndoEntry = ({Item item, DecisionRecord? prev});

class SyncStatus {
  const SyncStatus({this.running = false, this.pending = 0, this.done = 0, this.error = '', this.waitingWifi = false});

  /// Wi-Fi only is on and the phone isn't on Wi-Fi: uploads start when it is.
  final bool waitingWifi;

  final bool running;

  /// Kept photos not yet in Immich (or not yet in their album there).
  final int pending;
  final int done;
  final String error;
}

/// Id of the month-album chip before that month's album exists.
const monthAlbumId = 'month';
const gapChoices = [2, 5, 10, 30, 60];
const groupMax = 40;
const thumbMin = 72.0;
const thumbMax = 360.0;
const near = 5 * day;

/// All app state and logic. Widgets listen and call methods; every change ends in notifyListeners().
class AppState extends ChangeNotifier {
  Db? _db;
  Db get db => _db!;

  Screen screen = Screen.loading;

  /// The view the mode switch is on; settings and trash return to it.
  Screen mode = Screen.cull;
  Access access = Access.prompt;
  bool askedAccess = false;
  String error = '';

  List<Item> items = [];
  Map<String, Item> byId = {};
  Map<String, DecisionRecord> decided = {};
  List<Album> albums = [];
  int? cutoff;
  List<Item> queue = [];
  final List<List<UndoEntry>> undoStack = [];
  Set<String> restore = {};
  bool busy = false;

  // Settings (meta table).
  int groupGap = 5;
  bool bursts = true;
  bool checkDefault = true;
  bool autoTrash = true;
  bool gridAutoTrash = false;
  bool newestFirst = false;

  /// Bought the Supporter thank-you (Play); [support] talks to the store.
  bool supporter = false;
  final support = Support();

  /// Catch-all albums cover a year ("2026"), else a month ("2026-10").
  bool byYear = true;

  /// Keep / delete animation (trace) before a decision is saved (setting).
  bool animations = true;

  /// Photos playing the trace right now: id -> true (keep) / false (delete). Widgets showing one of them animate.
  Map<String, bool> fx = {};
  bool get animating => fx.isNotEmpty;
  double gridFrac = 0.4;
  double thumbH = 150;
  Set<String> hidden = {};

  // Swipe screen.
  /// Burst photos flipped from the default (all checked, or none, per setting).
  Set<String> flipped = {};
  int focus = 0;

  /// Album picked from the bar for the card on screen; otherwise the suggestion is used.
  String? chosenId;

  /// A burst being worked through stays together (removing a photo can break the time gap between the others).
  Set<String>? pinned;

  // Grid.
  /// What the grid shows: 'unreviewed' (grid mode), or in explorer 'all' (everything on the phone that isn't
  /// deleted), 'reviewed' (filed into an album) or an album id.
  String gridView = 'unreviewed';
  String exploreView = 'all';

  /// File stores' settings (B2, WebDAV, S3, SFTP), by [StoreDef.key].
  Map<String, StoreConfig> stores = {};

  /// The file store whose page is open ([Screen.store]).
  String storeKey = storeDefs.first.key;

  StoreConfig store(String key) => stores[key] ?? const StoreConfig();
  bool storeOn(String key) => store(key).enabled && storeDef(key).ready(store(key));
  GPhotosConfig google = const GPhotosConfig();

  /// Free up space after backup: 'off', 'now' (as soon as every integration has a photo) or '30d' (keep the last 30
  /// days on the phone).
  String freeUp = 'off';

  /// Photos removed from the phone this session (for the status line).
  int freedCount = 0;

  /// Names of Immich albums picked in Explorer (id -> name), for the source chip.
  Map<String, String> immichAlbumNames = {};
  Set<String> gridSel = {};
  String? gridChosenId;

  // Immich.
  ImmichConfig immich = const ImmichConfig();
  SyncStatus sync = const SyncStatus();
  Timer? _syncTimer;
  bool _syncing = false;
  bool _syncAgain = false;

  int _rev = 0;

  /// Loading finished: the loading screen plays its outro (the wordmark traces and fades) before the app shows.
  bool loadDone = false;
  final _memo = <String, (int, Object?)>{};

  /// Derived values are recomputed at most once per change (the UI reads them many times per frame).
  T _cached<T>(String key, T Function() compute) {
    final hit = _memo[key];
    if (hit != null && hit.$1 == _rev) return hit.$2 as T;
    final v = compute();
    _memo[key] = (_rev, v);
    return v;
  }

  /// Shown while the photo library loads (a big library takes a few seconds the first time).
  String loading = '';

  void changed() {
    _rev++;
    notifyListeners();
  }

  // ---------------------------------------------------------------- loading

  Future<void> init() async {
    try {
      _db ??= await Db.open();
      final m = await db.allMeta();
      _loadSettings(m);
      // A folder has no "new since" point: review all of it.
      if (media.useFolders && cutoff == null) {
        cutoff = 0;
        await db.setMeta('cutoff', 0);
      }
      // On a computer "access" is having picked a folder.
      access = media.useFolders ? (folders.isEmpty ? Access.prompt : Access.granted) : await media.getAccess();
      if (access != Access.granted) {
        screen = Screen.access;
        return changed();
      }
      albums = [for (final j in await db.all('albums')) Album.fromJson(j)];
      _catchAll(m);
      await reload();
      mode = switch (m['mode']) { 'grid' => Screen.grid, 'explore' => Screen.explore, _ => Screen.cull };
      exploreView = (m['exploreView'] as String?) ?? 'all';
      immichAlbumNames = ((m['immichAlbumNames'] as Map?) ?? {}).cast<String, String>();
      gridView = mode == Screen.explore ? exploreView : 'unreviewed';
      if (screen == Screen.loading && animations) {
        loadDone = true;
        changed();
        await Future<void>.delayed(Motion.total + const Duration(milliseconds: 80));
      }
      screen = cutoff == null ? Screen.start : mode;
      changed();
      support.start(() {
        if (!supporter) {
          supporter = true;
          _set('supporter', true);
        }
      }).then((_) => changed());
      _reschedule();
      runSync();
    } catch (e) {
      error = '$e';
      screen = Screen.error;
      changed();
    }
  }

  void _loadSettings(Map<String, Object?> m) {
    cutoff = (m['cutoff'] as num?)?.toInt();
    groupGap = (m['groupGap'] as num?)?.toInt() ?? 5;
    bursts = (m['bursts'] as bool?) ?? groupGap != 0;
    if (groupGap == 0) groupGap = 5;
    checkDefault = (m['burstChecked'] as bool?) ?? true;
    autoTrash = (m['autoTrash'] as bool?) ?? true;
    gridAutoTrash = (m['gridAutoTrash'] as bool?) ?? false;
    newestFirst = (m['newestFirst'] as bool?) ?? false;
    supporter = (m['supporter'] as bool?) ?? false;
    animations = (m['animations'] as bool?) ?? true;
    gridFrac = (m['gridFrac'] as num?)?.toDouble() ?? 0.4;
    thumbH = (m['thumbH'] as num?)?.toDouble() ?? 150;
    hidden = ((m['hiddenBuckets'] as List?) ?? []).cast<String>().toSet();
    immich = ImmichConfig.fromJson((m['immich'] as Map?)?.cast<String, Object?>());
    stores = {for (final d in storeDefs) d.key: StoreConfig.fromJson((m[d.key] as Map?)?.cast<String, Object?>())};
    google = GPhotosConfig.fromJson((m['google'] as Map?)?.cast<String, Object?>());
    freeUp = (m['freeUp'] as String?) ?? 'off';
    folders = ((m['folders'] as List?) ?? []).cast<String>();
    if (Platform.isMacOS) media.useFolders = m['source'] != 'library';
    // Apple albums are on unless turned off: filing into albums in Photos is the point on an Apple library.
    if (m['apple'] == null) stores = {...stores, 'apple': stores['apple']!.copyWith(enabled: true)};
  }

  /// The background upload task (no screen): load what's needed and sync once.
  Future<void> backgroundSync() async {
    _db ??= await Db.open();
    // No screen here: photo_manager's permission check needs one (it crashes), so skip it. Without access the photo
    // list comes back empty and nothing uploads.
    await media.skipPermissionCheck();
    final m = await db.allMeta();
    _loadSettings(m);
    if (!anyIntegration) return;
    _background = true;
    albums = [for (final j in await db.all('albums')) Album.fromJson(j)];
    _catchAll(m);
    await reload();
    await runSync();
  }

  /// On a computer: the folders being reviewed (searched with their subfolders).
  List<String> folders = [];

  Future<void> addFolder(String path) async {
    if (folders.contains(path)) return;
    folders = [...folders, path];
    await db.setMeta('folders', folders);
    if (screen == Screen.access) return init();
    await reload();
  }

  Future<void> removeFolder(String path) async {
    folders = folders.where((f) => f != path).toList();
    await db.setMeta('folders', folders);
    if (folders.isEmpty) return init();
    await reload();
  }

  /// Mac: review folders, or the Photos library. Each has its own start point (a library is asked for one).
  Future<void> setSource({required bool folders}) async {
    if (media.useFolders == folders) return;
    media.useFolders = folders;
    await db.setMeta('source', folders ? 'folders' : 'library');
    cutoff = null;
    await db.setMeta('cutoff', null);
    items = [];
    screen = Screen.loading;
    changed();
    await init();
  }

  Future<void> requestAccess() async {
    askedAccess = true;
    access = await media.requestAccess();
    if (access == Access.granted) return init();
    changed();
  }

  int _byOrder(Item a, Item b) => newestFirst ? b.taken.compareTo(a.taken) : a.taken.compareTo(b.taken);

  bool shown(Item i) => !hidden.contains(i.bucket);

  /// Belongs in the swipe queue: not decided, not before the start point, not in a hidden folder.
  bool inCull(Item i) => !decided.containsKey(i.id) && i.taken >= (cutoff ?? 0) && shown(i);

  Future<void> reload() async {
    final all = await media.loadItems(db, folders, onProgress: (status) {
      if (screen != Screen.loading) return;
      loading = status;
      notifyListeners();
    });
    final records = {for (final j in await db.all('decisions')) DecisionRecord.fromJson(j)};
    final map = {for (final r in records) r.id: r};
    final listed = {for (final i in all) i.id};
    // An item marked trashed that is still listed was restored from the system trash: review it again.
    for (final r in records) {
      if (r.decision == Decision.trash && listed.contains(r.id)) {
        map.remove(r.id);
        await db.remove('decisions', r.id);
      }
    }
    all.sort(_byOrder);
    items = all;
    byId = {for (final i in all) i.id: i};
    decided = map;
    final queued = {for (final i in queue) i.id};
    // Keep the current order (including "Later" moves). New photos join at the end oldest-first, at the front newest-first.
    final kept = queue.where((i) => listed.contains(i.id) && inCull(i)).toList();
    final fresh = all.where((i) => !queued.contains(i.id) && inCull(i)).toList();
    queue = newestFirst && kept.isNotEmpty ? [...fresh, ...kept] : [...kept, ...fresh];
    changed();
  }

  Future<void> chooseStart(int from) async {
    cutoff = from;
    await db.setMeta('cutoff', from);
    queue = [];
    await reload();
    screen = mode = Screen.cull;
    changed();
  }

  int countSince(int from) => items.where((i) => i.taken >= from).length;

  // ---------------------------------------------------------------- swipe screen

  List<Item> get group => _cached('group', _group);

  List<Item> _group() {
    final p = pinned;
    if (p != null) {
      final rest = queue.where((i) => p.contains(i.id)).toList();
      if (rest.isNotEmpty) return rest;
    }
    final g = <Item>[];
    for (final item in queue) {
      final last = g.lastOrNull;
      if (last != null &&
          (!bursts || (item.taken - last.taken).abs() > groupGap * 1000 || g.length >= groupMax)) {
        break;
      }
      g.add(item);
    }
    return g;
  }

  Item? get current {
    final g = group;
    if (g.isEmpty) return null;
    return g[focus.clamp(0, g.length - 1)];
  }

  bool get isGroup => group.length > 1;

  /// Checked photos of the burst on screen; empty for a single photo.
  Set<String> get selected => _cached('selected', _selected);

  Set<String> _selected() {
    final g = group;
    if (g.length < 2) return {};
    return {for (final i in g) if (checkDefault != flipped.contains(i.id)) i.id};
  }

  /// Burst buttons: all (or none) checked = the whole burst; else the checked ones, and (setting) the rest the other way.
  bool get burstAll {
    final n = selected.length;
    return isGroup && (n == 0 || n == group.length);
  }

  int get burstRest => isGroup && !burstAll && autoTrash ? group.length - selected.length : 0;

  void toggleCheck(String id) {
    flipped = {...flipped};
    if (!flipped.remove(id)) flipped.add(id);
    changed();
  }

  /// Checks (or unchecks) every photo of the burst on screen.
  void setAllChecked(bool on) {
    final ids = {for (final i in group) i.id};
    flipped = on == checkDefault ? {} : ids;
    changed();
  }

  void setFocus(int i) {
    focus = i;
    changed();
  }

  List<Item> get pendingTrash =>
      _cached('trash', () => [for (final i in items) if (decided[i.id]?.decision == Decision.pendingTrash) i]);

  /// When the photos in each album were taken (for "is this album near the photo's date").
  Map<String, List<int>> get _albumTimes => _cached('albumTimes', () {
        final out = <String, List<int>>{};
        for (final r in decided.values) {
          final t = r.albumId == null ? null : byId[r.id]?.taken;
          if (t != null) out.putIfAbsent(r.albumId!, () => []).add(t);
        }
        return out;
      });

  // ---------------------------------------------------------------- albums

  /// Year or month catch-alls: as set, else by year unless month albums are already in use (an older install).
  void _catchAll(Map<String, Object?> m) =>
      byYear = switch (m['catchAll']) { 'year' => true, 'month' => false, _ => !albums.any((a) => a.monthly) };

  Future<void> setCatchAll({required bool year}) async {
    byYear = year;
    await _set('catchAll', year ? 'year' : 'month');
  }

  int get _monthUsed => albums.where((a) => a.monthly).fold(0, (m, a) => max(m, a.lastUsedAt));

  int _catchStart(int t, bool year) => year ? startOfYear(t) : startOfMonth(t);

  Album? _catchFound(int t, bool year) {
    final start = _catchStart(t, year);
    return albums.where((a) => a.monthly && !a.retired && a.yearly == year && a.start == start).firstOrNull;
  }

  /// The catch-all album for [t] (its year's or month's), or a stand-in (id [monthAlbumId]) until the first photo is
  /// filed into it.
  Album monthChip(int t) =>
      _catchFound(t, byYear) ??
      Album(
          id: monthAlbumId,
          name: '',
          start: _catchStart(t, byYear),
          end: byYear ? endOfYear(t) : endOfMonth(t),
          createdAt: 0,
          lastUsedAt: _monthUsed,
          monthly: true,
          yearly: byYear);

  /// Albums by last use; the month album sits wherever its last use puts it. New, unused albums sort by creation.
  List<Album> recentFor(int? t) {
    final list = albums.where((a) => !a.monthly).toList();
    if (t != null) list.add(monthChip(t));
    int key(Album a) => a.monthly ? _monthUsed : (a.lastUsedAt != 0 ? a.lastUsedAt : a.createdAt);
    list.sort((a, b) => key(b).compareTo(key(a)));
    return list;
  }

  bool _near(Album a, int t) => (_albumTimes[a.id] ?? const []).any((x) => (x - t).abs() <= near);

  /// Default album: a dated album whose range covers the time; else the album used last if it has no dates and holds
  /// a photo from within 5 days; else that month's album.
  Album? suggestFor(int? t) {
    if (t == null) return null;
    final covering = albums
        .where((a) => !a.monthly && a.start != null && a.start! <= t && (a.end == null || t <= a.end!))
        .toList()
      ..sort((a, b) => b.start!.compareTo(a.start!));
    if (covering.isNotEmpty) return covering.first;
    final candidates = [...albums.where((a) => !a.monthly), monthChip(t)]
      ..sort((a, b) => (b.monthly ? _monthUsed : b.lastUsedAt).compareTo(a.monthly ? _monthUsed : a.lastUsedAt));
    final last = candidates.firstOrNull;
    if (last != null && !last.monthly && last.start == null && last.lastUsedAt != 0 && _near(last, t)) return last;
    return monthChip(t);
  }

  Album? get target {
    final g = group;
    if (g.isEmpty) return null;
    final t = g.first.taken;
    if (chosenId == monthAlbumId) return monthChip(t);
    return recentFor(t).where((a) => a.id == chosenId).firstOrNull ?? suggestFor(t);
  }

  /// The chosen album first, then the photo's month album (so it's always in view), then albums that match the
  /// photo's date (their dates cover it, or they hold a photo within 5 days), then the rest by last use.
  List<Album> get barAlbums {
    final t = target;
    final taken = group.firstOrNull?.taken;
    final recent = recentFor(taken);
    final month = recent.where((a) => a.monthly).firstOrNull;
    bool covers(Album a) => taken != null && a.start != null && a.start! <= taken && (a.end == null || taken <= a.end!);
    final matches = taken == null
        ? const <Album>[]
        : [...recent.where((a) => !a.monthly && covers(a)), ...recent.where((a) => !a.monthly && !covers(a) && _near(a, taken))];
    final front = <Album>[];
    for (final a in [?t, ?month, ...matches]) {
      if (!front.any((f) => f.id == a.id)) front.add(a);
    }
    return [...front, ...recent.where((a) => !front.any((f) => f.id == a.id))];
  }

  void choose(String id) {
    chosenId = id;
    changed();
  }

  /// The catch-all album ("2026", or "2026-10" by month) for [t], created on first use.
  Future<Album> monthAlbumFor(int t) => _catchAlbum(t, byYear);

  Future<Album> _catchAlbum(int t, bool year) async {
    final found = _catchFound(t, year);
    if (found != null) return found;
    final start = _catchStart(t, year);
    // Back to months after a merge: the old month album (and its albums in the targets) comes back.
    final old = albums.where((a) => a.monthly && a.retired && a.yearly == year && a.start == start).firstOrNull;
    if (old != null) {
      old.retired = false;
      await db.put('albums', old.id, old.toJson());
      return old;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final a = Album(
        id: _uuid(),
        name: '',
        start: start,
        end: year ? endOfYear(t) : endOfMonth(t),
        createdAt: now,
        lastUsedAt: now,
        monthly: true,
        yearly: year);
    albums = [...albums, a];
    await db.put('albums', a.id, a.toJson());
    return a;
  }

  /// Month albums still in use (for the merge offer).
  int get monthAlbumCount => albums.where((a) => a.monthly && !a.yearly && !a.retired).length;

  /// Moves every photo in a month album into its year's album and retires the month albums; the next sync moves the
  /// photos in each target too (and deletes the emptied month albums in Immich). Returns how many photos moved.
  Future<int> mergeMonths() async {
    final months = {for (final a in albums.where((a) => a.monthly && !a.yearly && !a.retired)) a.id: a};
    if (months.isEmpty) return 0;
    final moved = <DecisionRecord>[];
    for (final j in await db.all('decisions')) {
      final d = DecisionRecord.fromJson(j);
      final m = months[d.albumId];
      if (m == null) continue;
      final year = await _catchAlbum(m.start!, true);
      moved.add(DecisionRecord(id: d.id, decision: d.decision, decidedAt: d.decidedAt, albumId: year.id));
    }
    await db.putAll('decisions', {for (final r in moved) r.id: r.toJson()});
    decided = {...decided, for (final r in moved) if (decided.containsKey(r.id)) r.id: r};
    for (final a in months.values) {
      a.retired = true;
    }
    await db.putAll('albums', {for (final a in months.values) a.id: a.toJson()});
    undoStack.clear();
    changed();
    runSync();
    return moved.length;
  }

  /// Saves an edited album. In Immich the album is renamed and its photos move to the new tag right away when
  /// possible; otherwise they're re-filed on the next sync.
  Future<void> updateAlbum(Album old, Album updated) async {
    final oldTitle = albumTitle(old), oldTag = albumTag(old);
    albums = [for (final a in albums) a.id == old.id ? updated : a];
    await db.put('albums', updated.id, updated.toJson());
    changed();
    final immichId = updated.immichAlbumId;
    if (immichId == null || (oldTitle == albumTitle(updated) && oldTag == albumTag(updated))) {
      runSync();
      return;
    }
    final recs = [
      for (final j in await db.all('uploads'))
        if (UploadRecord.fromJson(j).syncedAlbumId == updated.id) UploadRecord.fromJson(j),
    ];
    final api = ImmichApi(immich);
    try {
      if (!immich.ready) throw Exception('Immich not set up');
      if (oldTitle != albumTitle(updated)) await api.call('PATCH', '/albums/$immichId', {'albumName': albumTitle(updated)});
      if (oldTag != albumTag(updated) && recs.isNotEmpty) {
        final ids = [for (final r in recs) r.assetId];
        await api.call('DELETE', '/tags/${await api.ensureTag(oldTag)}/assets', {'ids': ids});
        await api.tag(await api.ensureTag(albumTag(updated)), ids);
      }
    } catch (_) {
      // Offline or not set up: the next sync renames the album, adds the new tag and removes the old one.
      for (final r in recs) {
        r.syncedAlbumId = null;
        await db.put('uploads', r.id, r.toJson());
      }
      if (oldTag != albumTag(updated) && !updated.staleTags.contains(oldTag)) {
        updated.staleTags = [...updated.staleTags, oldTag];
        await db.put('albums', updated.id, updated.toJson());
      }
    } finally {
      api.close();
    }
    // File stores and Google move or rename on the next sync: run it now.
    runSync();
  }

  Future<void> createAlbum(Album a, {bool fileAfter = false, bool grid = false}) async {
    albums = [...albums, a];
    await db.put('albums', a.id, a.toJson());
    if (grid) {
      if (fileAfter && gridSel.isNotEmpty) {
        await fileGrid(a.id);
      } else {
        gridChosenId = a.id;
      }
    } else {
      chosenId = a.id;
      if (fileAfter) await file(Dir.right, a.id);
    }
    changed();
  }

  // ---------------------------------------------------------------- deciding

  void _nextCard() {
    flipped = {};
    focus = 0;
    chosenId = null;
    pinned = null;
  }

  /// Swipe right / Keep files into the target album; left / Delete trashes.
  Future<void> decide(Dir dir, {bool fx = true}) async {
    final t = target;
    if (t == null) return;
    await file(dir, t.id, fx: fx);
  }

  /// Records a decision for the photo on screen, or for a burst: all (or none) checked = the whole burst; else the
  /// checked ones, plus the rest the opposite way (setting). Leftovers stay on screen (same album) until decided.
  /// [fx]: play the trace first (buttons, not swipes).
  Future<void> file(Dir dir, String albumId, {bool fx = true}) async {
    final g = group;
    var keep = <Item>[], del = <Item>[];
    if (g.length > 1) {
      final sel = selected;
      final picked = g.where((i) => sel.contains(i.id)).toList();
      final others = g.where((i) => !sel.contains(i.id)).toList();
      if (picked.isEmpty || picked.length == g.length) {
        dir == Dir.right ? keep = g : del = g;
      } else if (dir == Dir.right) {
        keep = picked;
        if (autoTrash) del = others;
      } else {
        del = picked;
        if (autoTrash) keep = others;
      }
    } else if (current != null) {
      dir == Dir.right ? keep = [current!] : del = [current!];
    }
    if (keep.isEmpty && del.isEmpty || animating) return;
    if (fx) await _play({for (final i in keep) i.id: true, for (final i in del) i.id: false});
    final done = {for (final i in [...keep, ...del]) i.id};
    final remaining = g.where((i) => !done.contains(i.id)).toList();
    final keepChoice = chosenId;
    final at = focus;
    final now = DateTime.now().millisecondsSinceEpoch;
    final records = <DecisionRecord>[];
    for (final i in keep) {
      final id = albumId == monthAlbumId ? (await monthAlbumFor(i.taken)).id : albumId;
      records.add(DecisionRecord(id: i.id, decision: Decision.keep, decidedAt: now, albumId: id));
    }
    for (final i in del) {
      records.add(DecisionRecord(id: i.id, decision: Decision.pendingTrash, decidedAt: now));
    }
    _nextCard();
    await _commit([...keep, ...del], records);
    if (remaining.isNotEmpty) {
      pinned = {for (final i in remaining) i.id};
      chosenId = keepChoice;
      focus = min(at, max(0, group.length - 1));
    }
    changed();
  }

  /// Plays the trace on these photos (only those on screen actually draw it), then returns so the decision is saved.
  Future<void> _play(Map<String, bool> marks) async {
    if (!animations || marks.isEmpty) return;
    await prepareOutlines([for (final id in marks.keys) if (byId[id] != null) byId[id]!]);
    fx = marks;
    changed();
    await Future<void>.delayed(Motion.total);
    fx = {};
  }

  Future<void> setAnimations(bool on) {
    animations = on;
    return _set('animations', on);
  }

  Future<void> _commit(List<Item> cardItems, List<DecisionRecord> records) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    undoStack.add([for (final i in cardItems) (item: i, prev: decided[i.id])]);
    if (undoStack.length > 50) undoStack.removeAt(0);
    decided = {...decided, for (final r in records) r.id: r};
    final done = {for (final i in cardItems) i.id};
    queue = queue.where((i) => !done.contains(i.id)).toList();
    for (final id in {for (final r in records) r.albumId}) {
      final a = albums.where((a) => a.id == id).firstOrNull;
      if (a != null) {
        // Made before any photo was chosen: its date comes from the first (oldest) photo filed into it.
        if (a.autoDate && a.start == null) {
          final first = records.where((r) => r.albumId == id).map((r) => byId[r.id]?.taken).whereType<int>().fold<int?>(
              null, (m, t) => m == null || t < m ? t : m);
          if (first != null) {
            final d = DateTime.fromMillisecondsSinceEpoch(first);
            a.start = DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
            a.autoDate = false;
          }
        }
        a.lastUsedAt = now;
        await db.put('albums', a.id, a.toJson());
      }
    }
    await db.putAll('decisions', {for (final r in records) r.id: r.toJson()});
    changed();
    scheduleSync();
  }

  Future<void> undo() async {
    if (undoStack.isEmpty) return;
    final last = undoStack.removeLast();
    final next = {...decided};
    for (final e in last) {
      if (e.prev != null) {
        next[e.item.id] = e.prev!;
        await db.put('decisions', e.item.id, e.prev!.toJson());
      } else {
        next.remove(e.item.id);
        await db.remove('decisions', e.item.id);
      }
    }
    decided = next;
    // Undecided again and in range: back to the front of the queue (grid-filed backlog photos return to the grid).
    final again = [for (final e in last) if (inCull(e.item)) e.item];
    final back = {for (final i in again) i.id};
    queue = [...again, ...queue.where((i) => !back.contains(i.id))];
    _nextCard();
    changed();
  }

  void later() {
    final g = group;
    if (queue.length <= g.length) return;
    final moved = {for (final i in g) i.id};
    queue = [...queue.where((i) => !moved.contains(i.id)), ...g];
    _nextCard();
    changed();
  }

  // ---------------------------------------------------------------- grid

  int _backlogRev = -1;
  List<Item> _backlog = [];

  bool _unreviewed(Item i) {
    final d = decided[i.id];
    return d == null || (d.decision == Decision.keep && d.albumId == null);
  }

  /// Photos that still need an album: undecided (any date, e.g. before the start point) or kept without one.
  int get unreviewedCount => _cached('unreviewed', () => items.where((i) => shown(i) && _unreviewed(i)).length);

  /// The grid's photos, per [gridView]: unreviewed, all (kept or unreviewed; not deleted), or one album.
  List<Item> get backlog {
    if (_backlogRev != _rev) {
      _backlog = items.where((i) {
        if (!shown(i)) return false;
        final d = decided[i.id];
        return switch (gridView) {
          'unreviewed' => _unreviewed(i),
          'all' => d == null || d.decision == Decision.keep,
          'reviewed' => d?.decision == Decision.keep && d?.albumId != null,
          _ => d?.decision == Decision.keep && d?.albumId == gridView,
        };
      }).toList();
      if (byAlbum) _sortByAlbum(_backlog);
      _backlogRev = _rev;
    }
    return _backlog;
  }

  /// The gallery (everything, or everything reviewed) is organised by album rather than by month.
  bool get byAlbum => screen == Screen.explore && (gridView == 'all' || gridView == 'reviewed');

  /// The album a kept photo is filed in (null when it isn't).
  String? albumOf(Item i) {
    final d = decided[i.id];
    return d?.decision == Decision.keep ? d!.albumId : null;
  }

  /// Albums in the order of their first photo (newest first when that's the order), each album's photos in date
  /// order; photos not in an album come last. The grid's selection ranges (Fill) follow this order.
  void _sortByAlbum(List<Item> list) {
    final first = <String, int>{};
    for (final i in list) {
      final a = albumOf(i);
      if (a != null && (first[a] == null || i.taken < first[a]!)) first[a] = i.taken;
    }
    final at = {for (final (n, i) in list.indexed) i.id: n};
    int key(Item i) => first[albumOf(i)] ?? (newestFirst ? -1 : 1 << 62);
    list.sort((x, y) {
      final ax = albumOf(x), ay = albumOf(y);
      if ((ax == null) != (ay == null)) return ax == null ? 1 : -1;
      if (ax != ay) {
        final c = newestFirst ? key(y).compareTo(key(x)) : key(x).compareTo(key(y));
        return c != 0 ? c : ax!.compareTo(ay!);
      }
      return at[x.id]!.compareTo(at[y.id]!);
    });
  }

  /// Moves every photo of album [from] into [to] (the gallery's "Move…" on an album).
  Future<void> moveAlbum(String from, String to) async {
    if (from == to) return;
    gridSel = {for (final i in backlog) if (albumOf(i) == from) i.id};
    changed();
    await fileGrid(to);
  }

  void rememberImmichAlbum(String id, String name) {
    immichAlbumNames = {...immichAlbumNames, id: name};
    db.setMeta('immichAlbumNames', immichAlbumNames);
  }

  void setGridView(String v) {
    gridView = v;
    if (screen == Screen.explore) {
      exploreView = v;
      db.setMeta('exploreView', v);
    }
    gridSel = {};
    changed();
  }

  /// Photos per album (for the album picker in the grid).
  Map<String, int> get albumCounts => _cached('albumCounts', () {
        final out = <String, int>{};
        for (final r in decided.values) {
          if (r.decision == Decision.keep && r.albumId != null && byId.containsKey(r.id)) {
            out[r.albumId!] = (out[r.albumId!] ?? 0) + 1;
          }
        }
        return out;
      });

  List<Item> get gridChosen => [for (final i in backlog) if (gridSel.contains(i.id)) i];

  int? get gridOldest {
    int? t;
    for (final i in backlog) {
      if (gridSel.contains(i.id) && (t == null || i.taken < t)) t = i.taken;
    }
    return t;
  }

  /// Nothing selected yet: suggest for the first photo in the grid; the selection takes over after.
  int? get gridBasis => gridOldest ?? backlog.firstOrNull?.taken;

  Album? get gridTarget {
    final t = gridBasis;
    if (gridChosenId == monthAlbumId && t != null) return monthChip(t);
    return recentFor(t).where((a) => a.id == gridChosenId).firstOrNull ?? suggestFor(t);
  }

  List<Album> get gridAlbums {
    final t = gridTarget;
    final recent = recentFor(gridBasis);
    return t == null ? recent : [t, ...recent.where((a) => a.id != t.id)];
  }

  /// The catch-all periods (years or months) the chosen photos fall in.
  Set<String> get gridMonthsChosen =>
      {for (final i in gridChosen) byYear ? '${DateTime.fromMillisecondsSinceEpoch(i.taken).year}' : monthPrefix(i.taken)};

  ({int lo, int hi}) get selSpan {
    var lo = -1, hi = -1;
    final b = backlog;
    for (var i = 0; i < b.length; i++) {
      if (gridSel.contains(b[i].id)) {
        if (lo < 0) lo = i;
        hi = i;
      }
    }
    return (lo: lo, hi: hi);
  }

  int get gapCount {
    final s = selSpan;
    return s.lo < 0 ? 0 : s.hi - s.lo + 1 - gridSel.length;
  }

  /// Deleted along with filing the selection (red border) when that setting is on.
  Set<String> get gridDoomed {
    final s = selSpan;
    // Only when filing unreviewed photos; browsing All or an album never deletes the photos in between.
    if (!gridAutoTrash || s.lo < 0 || gridView != 'unreviewed') return {};
    return {for (final i in backlog.sublist(s.lo, s.hi + 1)) if (!gridSel.contains(i.id)) i.id};
  }

  void toggleGrid(String id) {
    gridSel = {...gridSel};
    if (!gridSel.remove(id)) gridSel.add(id);
    changed();
  }

  void toggleMonth(List<Item> month) {
    final all = month.every((i) => gridSel.contains(i.id));
    gridSel = {...gridSel};
    for (final i in month) {
      all ? gridSel.remove(i.id) : gridSel.add(i.id);
    }
    changed();
  }

  void selectBetween() {
    final s = selSpan;
    gridSel = {...gridSel, for (final i in backlog.sublist(s.lo, s.hi + 1)) i.id};
    changed();
  }

  void clearGrid() {
    gridSel = {};
    changed();
  }

  void chooseGrid(String id) {
    gridChosenId = id;
    changed();
  }

  /// Files the selected photos into an album (month album: each into its own month), or trashes them (albumId null).
  Future<void> fileGrid(String? albumId) async {
    final chosen = gridChosen;
    if (chosen.isEmpty) return;
    final doomedIds = albumId != null ? gridDoomed : <String>{};
    final doomed = [for (final i in backlog) if (doomedIds.contains(i.id)) i];
    if (animating) return;
    await _play({for (final i in chosen) i.id: albumId != null, for (final i in doomed) i.id: false});
    final now = DateTime.now().millisecondsSinceEpoch;
    gridSel = {};
    final records = <DecisionRecord>[];
    for (final i in chosen) {
      final id = albumId == null ? null : (albumId == monthAlbumId ? (await monthAlbumFor(i.taken)).id : albumId);
      records.add(id == null
          ? DecisionRecord(id: i.id, decision: Decision.pendingTrash, decidedAt: now)
          : DecisionRecord(id: i.id, decision: Decision.keep, decidedAt: now, albumId: id));
    }
    for (final i in doomed) {
      records.add(DecisionRecord(id: i.id, decision: Decision.pendingTrash, decidedAt: now));
    }
    await _commit([...chosen, ...doomed], records);
  }

  void openGrid() {
    if (screen != Screen.grid) gridSel = {};
    gridView = 'unreviewed';
    screen = mode = Screen.grid;
    changed();
    db.setMeta('mode', 'grid');
  }

  /// Explorer: browse everything (or reviewed, or one album); select to move or delete.
  void openExplore() {
    if (screen != Screen.explore) gridSel = {};
    gridView = exploreView;
    screen = mode = Screen.explore;
    changed();
    db.setMeta('mode', 'explore');
  }

  void openSingle() {
    screen = mode = Screen.cull;
    changed();
    db.setMeta('mode', 'single');
  }

  /// Settings and trash toggle: tapping again goes back to the current mode.
  void toggleScreen(Screen s) {
    screen = screen == s ? mode : s;
    changed();
  }

  void go(Screen s) {
    screen = s;
    changed();
  }

  // ---------------------------------------------------------------- trash review

  void toggleRestore(String id) {
    restore = {...restore};
    if (!restore.remove(id)) restore.add(id);
    changed();
  }

  Future<void> restoreSelected() async {
    final back = pendingTrash.where((i) => restore.contains(i.id)).toList();
    final next = {...decided};
    for (final i in back) {
      next.remove(i.id);
      await db.remove('decisions', i.id);
    }
    decided = next;
    queue = [...back.where(inCull), ...queue];
    restore = {};
    final ids = {for (final i in back) i.id};
    undoStack.removeWhere((entry) => entry.any((u) => ids.contains(u.item.id)));
    changed();
  }

  Future<void> deleteTrash() async {
    final doomed = pendingTrash.where((i) => !restore.contains(i.id)).toList();
    if (doomed.isEmpty) return;
    busy = true;
    error = '';
    changed();
    try {
      final gone = await media.trash(doomed);
      if (gone.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final records = [
        for (final id in gone) DecisionRecord(id: id, decision: Decision.trash, decidedAt: now),
      ];
      decided = {...decided, for (final r in records) r.id: r};
      await db.putAll('decisions', {for (final r in records) r.id: r.toJson()});
      items = items.where((i) => !gone.contains(i.id)).toList();
      byId.removeWhere((id, _) => gone.contains(id));
      undoStack.removeWhere((entry) => entry.any((u) => gone.contains(u.item.id)));
      // A batch that failed or was declined: those photos stay in the trash to try again.
      final left = doomed.length - gone.length;
      if (left > 0) {
        error = '$left ${left == 1 ? 'photo wasn\'t' : 'photos weren\'t'} deleted. Tap Delete again to retry.';
      } else {
        screen = mode;
      }
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      changed();
    }
  }

  // ---------------------------------------------------------------- settings

  Future<void> _set(String key, Object? value) async {
    changed();
    await db.setMeta(key, value);
  }

  Future<void> setBursts(bool on) {
    bursts = on;
    _nextCard();
    return _set('bursts', on);
  }

  Future<void> setGroupGap(int s) {
    groupGap = s;
    _nextCard();
    return _set('groupGap', s);
  }

  Future<void> setCheckDefault(bool on) {
    checkDefault = on;
    flipped = {};
    return _set('burstChecked', on);
  }

  Future<void> setAutoTrash(bool on) {
    autoTrash = on;
    return _set('autoTrash', on);
  }

  Future<void> setGridAutoTrash(bool on) {
    gridAutoTrash = on;
    return _set('gridAutoTrash', on);
  }

  Future<void> setOrder(bool newest) {
    newestFirst = newest;
    items = [...items]..sort(_byOrder);
    queue = [...queue]..sort(_byOrder);
    _nextCard();
    return _set('newestFirst', newest);
  }

  void setThumbH(double h, {bool save = false}) {
    thumbH = h.clamp(thumbMin, thumbMax);
    changed();
    if (save) db.setMeta('thumbH', thumbH);
  }

  void setGridFrac(double f, {bool save = false}) {
    gridFrac = f.clamp(0.2, 0.6);
    changed();
    if (save) db.setMeta('gridFrac', gridFrac);
  }

  /// Shows or hides a folder's photos. Instant: the queue is rebuilt from what's loaded (no library reload).
  Future<void> toggleFolder(String bucket) async {
    final head = queue.firstOrNull?.id;
    hidden = {...hidden};
    final showing = hidden.remove(bucket);
    if (!showing) hidden.add(bucket);
    if (showing) {
      // Its photos rejoin the queue, as new photos do on a reload.
      final queued = {for (final i in queue) i.id};
      final back = items.where((i) => i.bucket == bucket && !queued.contains(i.id) && inCull(i)).toList();
      queue = newestFirst ? [...back, ...queue] : [...queue, ...back];
    } else {
      queue = queue.where(shown).toList();
    }
    // Only a new card in front loses the album picked for the old one.
    if (queue.firstOrNull?.id != head) _nextCard();
    changed();
    await db.setMeta('hiddenBuckets', hidden.toList());
  }

  List<(String, int)> get buckets {
    final counts = <String, int>{};
    for (final i in items) {
      counts[i.bucket] = (counts[i.bucket] ?? 0) + 1;
    }
    return counts.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  }

  void changeStart() {
    queue = [];
    screen = Screen.start;
    changed();
  }

  // ---------------------------------------------------------------- backup

  /// Everything Winnow stores, as JSON (same shape as the earlier web version, so its backups import here).
  Future<String> exportAll() async {
    final meta = await db.allMeta();
    return jsonEncode({
      'app': 'winnow',
      'version': 1,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'decisions': [for (final r in decided.values) r.toJson()],
      'albums': [for (final a in albums) a.toJson()],
      'meta': [for (final e in meta.entries) [e.key, e.value]],
    });
  }

  /// Merges a backup in (same ids are overwritten). Photo ids are the phone's own, so they hold on the same phone.
  Future<({int decisions, int albums})> importAll(String text) async {
    final b = jsonDecode(text) as Map<String, Object?>;
    if (b['app'] != 'winnow' && b['app'] != 'kosmos') throw Exception('Not a Winnow backup');
    final ds = [for (final j in (b['decisions'] as List)) DecisionRecord.fromJson((j as Map).cast())];
    final as = [for (final j in (b['albums'] as List)) Album.fromJson((j as Map).cast())];
    await db.putAll('decisions', {for (final r in ds) r.id: r.toJson()});
    await db.putAll('albums', {for (final a in as) a.id: a.toJson()});
    for (final e in (b['meta'] as List? ?? [])) {
      final pair = e as List;
      if (pair[0] == 'immich') continue; // The web version's Immich settings: re-enter them here.
      await db.setMeta('${pair[0]}', pair[1]);
    }
    queue = [];
    undoStack.clear();
    await init();
    return (decisions: ds.length, albums: as.length);
  }

  // ---------------------------------------------------------------- Immich

  /// Shares every album already in Immich with the share-with users (new ones are shared as they sync).
  /// Reads an Immich album name the way Winnow writes them: "2026-11 Thanksgiving" (dated), "2026-11" or "2026" (the
  /// month's or year's album) or anything else (undated). Dates come from the album's photos when they fall in that
  /// month.
  Album _fromImmich(String id, String name, DateTime? from, DateTime? to, Album? base) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final y = RegExp(r'^(19|20)\d\d$').hasMatch(name.trim()) ? DateTime(int.parse(name.trim())).millisecondsSinceEpoch : null;
    if (y != null) {
      return Album(
        id: base?.id ?? _uuid(),
        name: '',
        start: y,
        end: endOfYear(y),
        createdAt: base?.createdAt ?? now,
        lastUsedAt: base?.lastUsedAt ?? 0,
        monthly: true,
        yearly: true,
        immichAlbumId: id,
        googleAlbumId: base?.googleAlbumId,
        remoteIds: base?.remoteIds ?? const {},
        syncedTitles: base?.syncedTitles ?? const {},
      );
    }
    final yd = RegExp(r'^((?:19|20)\d\d)\s+(\S.*)$').firstMatch(name.trim());
    if (yd != null && !RegExp(r'^\d{2}\b').hasMatch(yd[2]!)) {
      final y = DateTime(int.parse(yd[1]!)).millisecondsSinceEpoch;
      final inYear = from != null && from.year == int.parse(yd[1]!);
      final keep = base?.start != null && base!.yearly && startOfYear(base.start!) == y;
      return Album(
        id: base?.id ?? _uuid(),
        name: yd[2]!.trim(),
        start: keep ? base.start : (inYear ? DateTime(from.year, from.month, from.day).millisecondsSinceEpoch : y),
        end: keep ? base.end : (inYear && to != null ? DateTime(to.year, to.month, to.day + 1).millisecondsSinceEpoch - 1 : null),
        createdAt: base?.createdAt ?? now,
        lastUsedAt: base?.lastUsedAt ?? 0,
        yearly: true,
        immichAlbumId: id,
        googleAlbumId: base?.googleAlbumId,
        remoteIds: base?.remoteIds ?? const {},
        syncedTitles: base?.syncedTitles ?? const {},
        staleTags: base?.staleTags ?? const [],
      );
    }
    final m = RegExp(r'^(\d{4})-(\d{2})(?:\s+(.+))?$').firstMatch(name.trim());
    int? start, end;
    var label = name.trim();
    var monthly = false;
    if (m != null && int.parse(m[2]!) >= 1 && int.parse(m[2]!) <= 12) {
      final month = DateTime(int.parse(m[1]!), int.parse(m[2]!)).millisecondsSinceEpoch;
      label = m[3]?.trim() ?? '';
      monthly = label.isEmpty;
      final inMonth = from != null && startOfMonth(from.millisecondsSinceEpoch) == month;
      if (monthly) {
        start = month;
        end = endOfMonth(month);
      } else if (base?.start != null && startOfMonth(base!.start!) == month) {
        // Same month as before (a rename): keep Winnow's own dates.
        start = base.start;
        end = base.end;
      } else {
        start = inMonth ? DateTime(from.year, from.month, from.day).millisecondsSinceEpoch : month;
        end = inMonth && to != null ? DateTime(to.year, to.month, to.day + 1).millisecondsSinceEpoch - 1 : null;
      }
    }
    return Album(
      id: base?.id ?? _uuid(),
      name: label,
      start: start,
      end: end,
      createdAt: base?.createdAt ?? now,
      lastUsedAt: base?.lastUsedAt ?? 0,
      monthly: monthly,
      immichAlbumId: id,
      googleAlbumId: base?.googleAlbumId,
      remoteIds: base?.remoteIds ?? const {},
      syncedTitles: base?.syncedTitles ?? const {},
      staleTags: base?.staleTags ?? const [],
    );
  }

  /// One-time import: Immich albums Winnow doesn't have yet become Winnow albums (matched by link, then by title).
  /// Returns (added, linked).
  Future<(int, int)> importImmichAlbums() async {
    final api = ImmichApi(immich);
    var added = 0, linked = 0;
    try {
      for (final r in await api.albums()) {
        if (albums.any((a) => a.immichAlbumId == r.id)) continue;
        final parsed = _fromImmich(r.id, r.name, r.start, r.end, null);
        final same = albums
            .where((a) =>
                a.immichAlbumId == null && !a.retired && albumTitle(a) == albumTitle(parsed) && a.monthly == parsed.monthly)
            .firstOrNull;
        if (same != null) {
          same.immichAlbumId = r.id;
          await db.put('albums', same.id, same.toJson());
          linked++;
        } else {
          albums = [...albums, parsed];
          await db.put('albums', parsed.id, parsed.toJson());
          added++;
        }
      }
    } finally {
      api.close();
      changed();
    }
    return (added, linked);
  }

  /// After a sync: albums renamed in Immich's own app get the new name (and dates) in Winnow, and their photos move to
  /// the new tag.
  Future<void> _pullAlbumNames(ImmichApi api) async {
    final remote = {for (final r in await api.albums()) r.id: r};
    for (final a in [...albums]) {
      final r = remote[a.immichAlbumId];
      if (r == null || r.name.trim() == albumTitle(a)) continue;
      await updateAlbum(a, _fromImmich(r.id, r.name, r.start, r.end, a));
    }
  }

  StreamSubscription<List<ConnectivityResult>>? _net;

  /// Starts a waiting sync when the phone joins Wi-Fi.
  void _watchNetwork() {
    if (media.desktop) return; // a computer uploads on any network (and Linux may have no NetworkManager to ask)
    _net ??= Connectivity().onConnectivityChanged.listen((r) {
      if (sync.waitingWifi && _isWifi(r)) runSync();
    });
  }

  bool _isWifi(List<ConnectivityResult> r) => r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);

  Future<bool> _onWifi() async {
    if (media.desktop) return true;
    try {
      return _isWifi(await Connectivity().checkConnectivity());
    } catch (_) {
      return true;
    }
  }

  /// Saves a file store's settings: [fields] are merged in.
  Future<void> saveStore(
    String key, {
    Map<String, String>? fields,
    String? folder,
    bool? enabled,
    bool? wifiOnly,
    bool? videos,
    String? background,
  }) async {
    final c = store(key);
    stores = {
      ...stores,
      key: c.copyWith(
        fields: fields == null ? null : {...c.fields, for (final e in fields.entries) e.key: e.value.trim()},
        folder: folder?.trim(),
        enabled: enabled,
        wifiOnly: wifiOnly,
        videos: videos,
        background: background,
      ),
    };
    await _set(key, store(key).toJson());
    _reschedule();
    if (enabled == true || wifiOnly != null || videos != null) runSync();
  }

  void openStore(String key) {
    storeKey = key;
    go(Screen.store);
  }

  Future<void> saveGoogle({
    String? email,
    bool? enabled,
    bool? wifiOnly,
    bool? videos,
    String? background,
    bool? backupOffSeen,
  }) async {
    google = google.copyWith(
      email: email,
      enabled: enabled,
      wifiOnly: wifiOnly,
      videos: videos,
      background: background,
      backupOffSeen: backupOffSeen,
    );
    await _set('google', google.toJson());
    _reschedule();
    if (enabled == true || wifiOnly != null || videos != null) runSync();
  }

  Future<void> setFreeUp(String v) async {
    freeUp = v;
    await _set('freeUp', v);
    if (v != 'off') runSync();
  }

  Future<int> shareAllAlbums() async {
    final api = ImmichApi(immich);
    var n = 0;
    try {
      for (final a in albums) {
        if (a.immichAlbumId == null) continue;
        await api.share(a.immichAlbumId!);
        n++;
      }
    } finally {
      api.close();
    }
    return n;
  }

  Future<void> saveImmich(
      {String? server, String? key, bool? enabled, Map<String, String>? shareWith, bool? wifiOnly, bool? videos, String? background}) async {
    immich = immich.copyWith(
        server: server == null ? null : cleanServer(server),
        key: key?.trim(),
        enabled: enabled,
        shareWith: shareWith,
        wifiOnly: wifiOnly,
        videos: videos,
        background: background);
    await _set('immich', immich.toJson());
    _reschedule();
    if (enabled == true || wifiOnly != null || videos != null) runSync();
  }

  /// Uploads start a few seconds after the last decision, so quick culling isn't interrupted.
  void scheduleSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(seconds: 3), runSync);
  }

  List<Item> _pendingUploads(Map<String, UploadRecord> records) => items.where((i) {
        final d = decided[i.id];
        return d != null &&
            d.decision == Decision.keep &&
            d.albumId != null &&
            (immich.videos || !i.isVideo) &&
            records[i.id]?.syncedAlbumId != d.albumId;
      }).toList();

  bool get _immichOn => immich.enabled && immich.ready;
  List<StoreDef> get _storesOn => [for (final d in storeDefs) if (storeOn(d.key)) d];
  bool get _googleOn => google.enabled && google.ready && Platform.isAndroid; // sign-in needs Play Services
  /// The last sync's error for one integration ('' if it went fine), by the name it reports under.
  String errorFor(String name) =>
      sync.error.split('\n').where((l) => l.startsWith('$name: ')).map((l) => l.substring(name.length + 2)).join('\n');

  bool get anyIntegration => _immichOn || _storesOn.isNotEmpty || _googleOn;

  /// What background upload should do: one entry per integration that's on and wants it.
  List<({String bg, bool wifi})> get _bgWants => [
        if (_immichOn && immich.background != 'off') (bg: immich.background, wifi: immich.wifiOnly),
        for (final d in _storesOn)
          if (store(d.key).background != 'off') (bg: store(d.key).background, wifi: store(d.key).wifiOnly),
        if (_googleOn && google.background != 'off') (bg: google.background, wifi: google.wifiOnly),
      ];

  void _reschedule() => scheduleBackground(_bgWants);

  Future<Map<String, FileRecord>> _files(String table) async =>
      {for (final j in await db.all(table)) FileRecord.fromJson(j).id: FileRecord.fromJson(j)};

  Future<Map<String, GRecord>> _gRecords() async =>
      {for (final j in await db.all('gphotos')) GRecord.fromJson(j).id: GRecord.fromJson(j)};

  bool _keptFiled(Item i, bool videos) {
    final d = decided[i.id];
    return d != null && d.decision == Decision.keep && d.albumId != null && (videos || !i.isVideo);
  }

  /// Kept, filed photos a file store doesn't have at their current path yet.
  List<Item> _pendingFiles(Map<String, FileRecord> recs, String prefix, bool videos) => items.where((i) {
        if (!_keptFiled(i, videos)) return false;
        final r = recs[i.id];
        return r == null || !_fileAt(r, i, decided[i.id]!.albumId!, prefix);
      }).toList();

  /// Whether [r] is already where [i] belongs (its album's folder, with or without the clash suffix).
  bool _fileAt(FileRecord r, Item i, String albumId, String prefix) {
    final album = albums.where((a) => a.id == albumId).firstOrNull;
    if (album == null) return true;
    // Any name in the album's folder: the file may carry a clash suffix, or be one that was already there.
    return dirOf(r.fileName) == dirOf(storePath(prefix, album, i.name));
  }

  List<Item> _pendingGoogle(Map<String, GRecord> recs) =>
      items.where((i) => _keptFiled(i, google.videos) && recs[i.id]?.albumId != decided[i.id]!.albumId).toList();

  Future<int> _pendingCount() async {
    var n = 0;
    if (_immichOn) {
      n += _pendingUploads({for (final j in await db.all('uploads')) UploadRecord.fromJson(j).id: UploadRecord.fromJson(j)}).length;
    }
    for (final d in _storesOn) {
      n += d.isAlbums
          ? _pendingAlbums(await _albumRecords(d.key), store(d.key).videos).length
          : _pendingFiles(await _files(d.key), store(d.key).folder, store(d.key).videos).length;
    }
    if (_googleOn) n += _pendingGoogle(await _gRecords()).length;
    return n;
  }

  int _done = 0;
  bool _background = false;

  void _status(int left) {
    sync = SyncStatus(running: true, pending: left, done: _done);
    changed();
  }

  /// Backs up kept photos to each integration that's on (Immich, B2, WebDAV, Google Photos), then frees up space if
  /// that's on. One run at a time; a call during a run schedules another pass.
  Future<void> runSync() async {
    if (_db == null || !anyIntegration) return;
    _watchNetwork();
    final wifi = await _onWifi();
    bool go(bool on, bool wifiOnly) => on && (wifi || !wifiOnly);
    final doImmich = go(_immichOn, immich.wifiOnly);
    // On-device albums need no network; Android's folder moves need the app on screen (a write grant).
    final doStores = [
      for (final d in _storesOn)
        if (d.library ? !(d.device == 'android' && _background) : go(true, store(d.key).wifiOnly)) d,
    ];
    final doGoogle = go(_googleOn, google.wifiOnly);
    final waiting =
        (_immichOn && !doImmich) || doStores.length < _storesOn.length || (_googleOn && !doGoogle);
    if (!doImmich && doStores.isEmpty && !doGoogle) {
      sync = SyncStatus(pending: await _pendingCount(), done: sync.done, waitingWifi: true);
      changed();
      return;
    }
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    _syncing = true;
    _done = 0;
    final errors = <String>[];
    // One failing integration doesn't stop the others.
    Future<void> run(String name, Future<void> Function() f) async {
      try {
        await f();
      } catch (e) {
        errors.add('$name: ${'$e'.replaceFirst('Exception: ', '')}');
      }
    }

    try {
      do {
        _syncAgain = false;
        errors.clear();
        if (doImmich) await run('Immich', _syncImmich);
        for (final d in doStores) {
          await run(d.label, () => d.isAlbums ? _syncAlbums(d) : _syncFiles(d));
        }
        if (doGoogle) await run('Google Photos', _syncGoogle);
      } while (_syncAgain);
      if (errors.isEmpty) await run('Free up space', _freeUp);
      sync = SyncStatus(
        done: _done,
        waitingWifi: waiting,
        pending: waiting || errors.isNotEmpty ? await _pendingCount() : 0,
        error: errors.join('\n'),
      );
    } catch (e) {
      // Never leave a stale "up to date" behind.
      sync = SyncStatus(done: _done, error: [...errors, '$e'.replaceFirst('Exception: ', '')].join('\n'));
    } finally {
      _syncing = false;
      changed();
    }
  }

  /// Uploads kept photos to Immich, then adds them to their album (same name) and tag (Albums/YYYY/MM/name).
  Future<void> _syncImmich() async {
    final api = ImmichApi(immich);
    try {
      final records = {for (final j in await db.all('uploads')) UploadRecord.fromJson(j).id: UploadRecord.fromJson(j)};
      final todo = _pendingUploads(records);
      var here = 0;
      _status(todo.length);
      for (final item in todo) {
        if (records.containsKey(item.id)) continue;
        final assetId = await api.upload(item);
        final rec = UploadRecord(id: item.id, assetId: assetId, uploadedAt: DateTime.now().millisecondsSinceEpoch);
        records[item.id] = rec;
        await db.put('uploads', rec.id, rec.toJson());
      }
      final byAlbum = <String, List<UploadRecord>>{};
      for (final item in todo) {
        byAlbum.putIfAbsent(decided[item.id]!.albumId!, () => []).add(records[item.id]!);
      }
      // Photos moved to another album in Winnow: take them out of the old Immich album and tag first.
      final moved = <String, List<String>>{};
      for (final item in todo) {
        final r = records[item.id]!;
        final old = r.syncedAlbumId;
        if (old != null && old != decided[item.id]!.albumId) moved.putIfAbsent(old, () => []).add(r.assetId);
      }
      final taken = {for (final i in todo) records[i.id]!.assetId: i.taken};
      for (final entry in moved.entries) {
        final old = albums.where((a) => a.id == entry.key).firstOrNull;
        if (old == null) continue;
        if (old.immichAlbumId != null) {
          await api.call('DELETE', '/albums/${old.immichAlbumId}/assets', {'ids': entry.value});
        }
        for (final t in _byTag(old, entry.value, taken).entries) {
          await api.call('DELETE', '/tags/${await api.ensureTag(t.key)}/assets', {'ids': t.value});
        }
      }
      for (final entry in byAlbum.entries) {
        final album = albums.where((a) => a.id == entry.key).firstOrNull;
        if (album == null) continue;
        final immichId = await api.ensureAlbum(album);
        await db.put('albums', album.id, album.toJson());
        await api.share(immichId);
        final ids = [for (final r in entry.value) r.assetId];
        await api.addToAlbum(immichId, ids);
        for (final t in _byTag(album, ids, taken).entries) {
          await api.tag(await api.ensureTag(t.key), t.value);
        }
        if (album.staleTags.isNotEmpty) {
          final all = [
            for (final j in await db.all('uploads'))
              if (UploadRecord.fromJson(j).syncedAlbumId == album.id || entry.value.any((r) => r.id == j['id']))
                UploadRecord.fromJson(j).assetId,
          ];
          for (final t in album.staleTags) {
            await api.call('DELETE', '/tags/${await api.ensureTag(t)}/assets', {'ids': all});
          }
          album.staleTags = [];
          await db.put('albums', album.id, album.toJson());
        }
        for (final r in entry.value) {
          r.syncedAlbumId = album.id;
          await db.put('uploads', r.id, r.toJson());
          _done++;
          here++;
        }
        _status(todo.length - here);
      }
      await _dropRetired(api, records.values);
      await _pullAlbumNames(api);
    } finally {
      api.close();
    }
  }

  /// [ids] by the Immich tag each gets in [a] (a year album tags each photo by its month).
  Map<String, List<String>> _byTag(Album a, List<String> ids, Map<String, int> taken) {
    final out = <String, List<String>>{};
    for (final id in ids) {
      out.putIfAbsent(photoTag(a, taken[id]), () => []).add(id);
    }
    return out;
  }

  /// Deletes the Immich albums of month albums merged into years once nothing is left in them.
  Future<void> _dropRetired(ImmichApi api, Iterable<UploadRecord> records) async {
    for (final a in albums.where((a) => a.retired && a.immichAlbumId != null)) {
      if (records.any((r) => r.syncedAlbumId == a.id)) continue;
      Map? info;
      try {
        info = await api.call('GET', '/albums/${a.immichAlbumId}?withoutAssets=true') as Map?;
      } catch (_) {
        // Already gone.
      }
      // Something else was put in it in Immich: leave it.
      if (info != null && (info['assetCount'] as num? ?? 0) > 0) continue;
      if (info != null) await api.call('DELETE', '/albums/${a.immichAlbumId}');
      a.immichAlbumId = null;
      await db.put('albums', a.id, a.toJson());
    }
  }

  /// A file store's client; values it learns (an SFTP host key) are saved into its settings.
  FileStore _make(StoreDef def) => def.make!(store(def.key), (k, v) => saveStore(def.key, fields: {k: v}));

  /// Albums a service already has under an older title (renamed in Winnow since).
  List<Album> _renamedFor(String key, String? Function(Album) remoteId) => [
        for (final a in albums)
          if (remoteId(a) != null && a.syncedTitles[key] != null && a.syncedTitles[key] != albumTitle(a)) a,
      ];

  Future<void> _markSynced(Album a, String key) async {
    a.syncedTitles = {...a.syncedTitles, key: albumTitle(a)};
    await db.put('albums', a.id, a.toJson());
  }

  AlbumService _makeAlbums(StoreDef def) => def.albums!(store(def.key), (k, v) => saveStore(def.key, fields: {k: v}));

  Future<Map<String, AlbumRecord>> _albumRecords(String table) async =>
      {for (final j in await db.all(table)) AlbumRecord.fromJson(j).id: AlbumRecord.fromJson(j)};

  List<Item> _pendingAlbums(Map<String, AlbumRecord> recs, bool videos) =>
      items.where((i) => _keptFiled(i, videos) && recs[i.id]?.albumId != decided[i.id]!.albumId).toList();

  /// Uploads kept photos to an album service (PhotoPrism, Synology Photos) into albums of the same names; photos
  /// refiled in Winnow move between those albums, renamed albums are renamed there.
  Future<void> _syncAlbums(StoreDef def) async {
    final c = store(def.key);
    final recs = await _albumRecords(def.key);
    final todo = _pendingAlbums(recs, c.videos);
    final renamed = _renamedFor(def.key, (a) => a.remoteIds[def.key]);
    if (todo.isEmpty && renamed.isEmpty) return;
    final api = _makeAlbums(def);
    try {
      await api.authorize();
      for (final a in renamed) {
        final rid = await api.ensureAlbum(albumTitle(a), a.remoteIds[def.key]);
        a.remoteIds = {...a.remoteIds, def.key: rid};
        await _markSynced(a, def.key);
      }
      var here = 0;
      _status(todo.length);
      final byAlbum = <String, List<Item>>{};
      for (final i in todo) {
        byAlbum.putIfAbsent(decided[i.id]!.albumId!, () => []).add(i);
      }
      for (final entry in byAlbum.entries) {
        final album = albums.where((a) => a.id == entry.key).firstOrNull;
        if (album == null) continue;
        final rid = await api.ensureAlbum(albumTitle(album), album.remoteIds[def.key]);
        album.remoteIds = {...album.remoteIds, def.key: rid};
        await _markSynced(album, def.key);
        // Already there, filed elsewhere: out of the old album, into this one.
        final moving = entry.value.where((i) => recs[i.id] != null).toList();
        final byOld = <String, List<String>>{};
        for (final i in moving) {
          final old = albums.where((a) => a.id == recs[i.id]!.albumId).firstOrNull?.remoteIds[def.key];
          if (old != null && old != rid) byOld.putIfAbsent(old, () => []).add(recs[i.id]!.remoteId);
        }
        for (final o in byOld.entries) {
          await api.remove(o.key, o.value);
        }
        if (moving.isNotEmpty) await api.add(rid, [for (final i in moving) recs[i.id]!.remoteId]);
        for (final i in moving) {
          recs[i.id]!.albumId = album.id;
          await db.put(def.key, i.id, recs[i.id]!.toJson());
          _done++;
          _status(todo.length - ++here);
        }
        for (final i in entry.value.where((i) => recs[i.id] == null)) {
          final rec = AlbumRecord(id: i.id, remoteId: await api.upload(i, rid), albumId: album.id);
          recs[i.id] = rec;
          await db.put(def.key, rec.id, rec.toJson());
          _done++;
          _status(todo.length - ++here);
        }
      }
    } finally {
      api.close();
    }
  }

  /// Uploads kept photos to a file store (B2, WebDAV, S3, SFTP) at their album's path; photos whose album changed (or was
  /// renamed) move there.
  Future<void> _syncFiles(StoreDef def) async {
    final c = store(def.key);
    final api = _make(def);
    final table = def.key;
    try {
      final recs = await _files(table);
      final todo = _pendingFiles(recs, c.folder, c.videos);
      if (todo.isEmpty) return;
      await api.authorize();
      final taken = {for (final r in recs.values) r.fileName: r.id};
      // What's already in each destination folder, listed once per sync, by file name.
      final listed = <String, Map<String, RemoteFile>>{};
      Future<Map<String, RemoteFile>> there(String dir) async =>
          listed[dir] ??= {for (final f in await api.list(dir)) f.name: f};
      var here = 0;
      _status(todo.length);
      for (final item in todo) {
        final album = albums.firstWhere((a) => a.id == decided[item.id]!.albumId);
        var name = storePath(c.folder, album, item.name);
        final dir = dirOf(name);
        final inDir = await there(dir);
        final old = recs[item.id];
        String fileId;
        final match = old == null ? await _alreadyThere(api, item, inDir.values, taken) : null;
        if (match != null) {
          // The same file is already there (an earlier upload, another device): keep it, don't upload a copy.
          name = match.path;
          fileId = match.id;
        } else {
          // Never overwrite a different file with the same name.
          bool clash(String n) => inDir.containsKey(n.split('/').last) || (taken[n] != null && taken[n] != item.id);
          if (clash(name)) name = withSuffix(name, clashTag(item.id));
          for (var k = 2; clash(name); k++) {
            name = withSuffix(storePath(c.folder, album, item.name), '${clashTag(item.id)}_$k');
          }
          fileId = old == null ? await api.upload(item, name) : await api.move(old, name);
          if (old != null) listed[dirOf(old.fileName)]?.remove(old.fileName.split('/').last);
          inDir[name.split('/').last] = RemoteFile(name, fileId, -1);
        }
        if (old != null) taken.remove(old.fileName);
        taken[name] = item.id;
        final rec = FileRecord(id: item.id, fileId: fileId, fileName: name, album: albumTitle(album));
        await api.filed(rec, old);
        recs[item.id] = rec;
        await db.put(table, rec.id, rec.toJson());
        _done++;
        _status(todo.length - ++here);
      }
      await api.finish();
    } finally {
      api.close();
    }
  }

  /// A file among [files] with the same bytes as [item] that no other photo's record points at, if any (same name
  /// checked first).
  Future<RemoteFile?> _alreadyThere(FileStore api, Item item, Iterable<RemoteFile> files, Map<String, String> taken) async {
    final local = await item.file();
    if (local == null) return null;
    final size = await local.length();
    final candidates = files.where((f) => f.size == size && (taken[f.path] == null || taken[f.path] == item.id)).toList()
      ..sort((a, b) => (a.name == item.name ? 0 : 1).compareTo(b.name == item.name ? 0 : 1));
    for (final f in candidates) {
      if (await sameFile(api, local, size, f)) return f;
    }
    return null;
  }

  /// Uploads kept photos to Google Photos into albums Winnow makes there (same names); photos refiled in Winnow move
  /// between those albums.
  Future<void> _syncGoogle() async {
    final recs = await _gRecords();
    final todo = _pendingGoogle(recs);
    final renamed = _renamedFor('google', (a) => a.googleAlbumId);
    if (todo.isEmpty && renamed.isEmpty) return;
    final api = await GPhotosApi.connect();
    if (api == null) {
      if (_background) return;
      throw Exception('sign in again (Settings > Google Photos)');
    }
    try {
      for (final a in renamed) {
        await api.ensureAlbum(a);
        await _markSynced(a, 'google');
      }
      var here = 0;
      _status(todo.length);
      final byAlbum = <String, List<Item>>{};
      for (final i in todo) {
        byAlbum.putIfAbsent(decided[i.id]!.albumId!, () => []).add(i);
      }
      for (final entry in byAlbum.entries) {
        final album = albums.where((a) => a.id == entry.key).firstOrNull;
        if (album == null) continue;
        final gid = await api.ensureAlbum(album);
        await _markSynced(album, 'google');
        // Already in Google, filed elsewhere: out of the old album, into this one.
        final moving = entry.value.where((i) => recs[i.id] != null).toList();
        final byOld = <String, List<String>>{};
        for (final i in moving) {
          final old = albums.where((a) => a.id == recs[i.id]!.albumId).firstOrNull?.googleAlbumId;
          if (old != null) byOld.putIfAbsent(old, () => []).add(recs[i.id]!.mediaItemId);
        }
        for (final o in byOld.entries) {
          await api.remove(o.key, o.value);
        }
        if (moving.isNotEmpty) await api.add(gid, [for (final i in moving) recs[i.id]!.mediaItemId]);
        for (final i in moving) {
          recs[i.id]!.albumId = album.id;
          await db.put('gphotos', i.id, recs[i.id]!.toJson());
          _done++;
          _status(todo.length - ++here);
        }
        // New: upload, then create in batches of 50 straight into the album.
        final fresh = entry.value.where((i) => recs[i.id] == null).toList();
        for (var b = 0; b < fresh.length; b += 50) {
          final batch = fresh.sublist(b, (b + 50).clamp(0, fresh.length));
          final uploads = [for (final i in batch) (token: await api.upload(i), name: i.name)];
          final ids = await api.create(uploads, gid);
          for (var k = 0; k < batch.length && k < ids.length; k++) {
            final id = ids[k];
            if (id == null) continue;
            final rec = GRecord(id: batch[k].id, mediaItemId: id, albumId: album.id);
            recs[rec.id] = rec;
            await db.put('gphotos', rec.id, rec.toJson());
            _done++;
            _status(todo.length - ++here);
          }
        }
      }
    } finally {
      api.close();
    }
  }

  /// Free up space: kept photos every integration that's on has filed (checked on the server first) go to the
  /// phone's trash (30 days to restore). Photos restored from there are never removed again. Not in the background:
  /// Android may ask to confirm.
  Future<void> _freeUp() async {
    // Something that holds a copy has to be on (Apple albums are the same photos).
    if (freeUp == 'off' || _background || !(_immichOn || _googleOn || _storesOn.any((d) => d.backup))) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final before = freeUp == '30d' ? now - 30 * day : now;
    final freed = ((await db.getMeta<List>('freed')) ?? []).cast<String>().toSet();
    final ups = {for (final j in await db.all('uploads')) UploadRecord.fromJson(j).id: UploadRecord.fromJson(j)};
    final files = {for (final d in _storesOn) if (!d.isAlbums) d.key: await _files(d.key)};
    final remote = {for (final d in _storesOn) if (d.isAlbums) d.key: await _albumRecords(d.key)};
    final gs = await _gRecords();
    final candidates = items.where((i) {
      if (!_keptFiled(i, true) || freed.contains(i.id) || i.taken >= before) return false;
      final album = decided[i.id]!.albumId!;
      if (_immichOn && ups[i.id]?.syncedAlbumId != album) return false;
      for (final d in _storesOn) {
        if (d.isAlbums) {
          if (remote[d.key]![i.id]?.albumId != album) return false;
          continue;
        }
        final r = files[d.key]![i.id];
        if (r == null || !_fileAt(r, i, album, store(d.key).folder)) return false;
      }
      if (_googleOn && gs[i.id]?.albumId != album) return false;
      return true;
    }).take(300).toList();
    if (candidates.isEmpty) return;
    final safe = <Item>[];
    final immichApi = _immichOn ? ImmichApi(immich) : null;
    final storeApis = {for (final d in _storesOn) if (!d.isAlbums) d.key: _make(d)};
    final albumApis = {for (final d in _storesOn) if (d.isAlbums) d.key: _makeAlbums(d)};
    final gApi = _googleOn ? await GPhotosApi.connect() : null;
    if (_googleOn && gApi == null) return;
    try {
      for (final a in storeApis.values) {
        await a.authorize();
      }
      for (final a in albumApis.values) {
        await a.authorize();
      }
      for (final i in candidates) {
        if (immichApi != null) {
          final a = await immichApi.call('GET', '/assets/${ups[i.id]!.assetId}') as Map;
          if (a['isTrashed'] == true) continue;
        }
        var everywhere = true;
        for (final e in storeApis.entries) {
          if (!await e.value.exists(files[e.key]![i.id]!)) {
            everywhere = false;
            break;
          }
        }
        for (final e in albumApis.entries) {
          if (!everywhere) break;
          if (!await e.value.exists(remote[e.key]![i.id]!.remoteId)) everywhere = false;
        }
        if (!everywhere) continue;
        if (gApi != null && !await gApi.exists(gs[i.id]!.mediaItemId)) continue;
        safe.add(i);
      }
    } finally {
      immichApi?.close();
      for (final a in storeApis.values) {
        a.close();
      }
      for (final a in albumApis.values) {
        a.close();
      }
      gApi?.close();
    }
    if (safe.isEmpty) return;
    final moved = await media.trash(safe);
    if (moved.isEmpty) return;
    await db.setMeta('freed', [...freed, ...moved]);
    freedCount += moved.length;
    await reload();
  }
}

final _rand = Random.secure();

String _uuid() {
  final b = List<int>.generate(16, (_) => _rand.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  final s = [for (var i = 0; i < 16; i++) h(i)].join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

String newId() => _uuid();

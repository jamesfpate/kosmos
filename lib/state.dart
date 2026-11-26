import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'db.dart';
import 'fx.dart';
import 'immich.dart';
import 'media.dart' as media;
import 'media.dart' show Access;
import 'models.dart';

enum Screen { loading, access, start, cull, grid, explore, trash, settings, immich, error }

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
      access = await media.getAccess();
      if (access != Access.granted) {
        screen = Screen.access;
        return changed();
      }
      final m = await db.allMeta();
      cutoff = (m['cutoff'] as num?)?.toInt();
      groupGap = (m['groupGap'] as num?)?.toInt() ?? 5;
      bursts = (m['bursts'] as bool?) ?? groupGap != 0;
      if (groupGap == 0) groupGap = 5;
      checkDefault = (m['burstChecked'] as bool?) ?? true;
      autoTrash = (m['autoTrash'] as bool?) ?? true;
      gridAutoTrash = (m['gridAutoTrash'] as bool?) ?? false;
      newestFirst = (m['newestFirst'] as bool?) ?? false;
      animations = (m['animations'] as bool?) ?? true;
      gridFrac = (m['gridFrac'] as num?)?.toDouble() ?? 0.4;
      thumbH = (m['thumbH'] as num?)?.toDouble() ?? 150;
      hidden = ((m['hiddenBuckets'] as List?) ?? []).cast<String>().toSet();
      immich = ImmichConfig.fromJson((m['immich'] as Map?)?.cast<String, Object?>());
      albums = [for (final j in await db.all('albums')) Album.fromJson(j)];
      await reload();
      mode = switch (m['mode']) { 'grid' => Screen.grid, 'explore' => Screen.explore, _ => Screen.cull };
      exploreView = (m['exploreView'] as String?) ?? 'all';
      gridView = mode == Screen.explore ? exploreView : 'unreviewed';
      if (screen == Screen.loading && animations) {
        loadDone = true;
        changed();
        await Future<void>.delayed(Motion.total + const Duration(milliseconds: 80));
      }
      screen = cutoff == null ? Screen.start : mode;
      changed();
      runSync();
    } catch (e) {
      error = '$e';
      screen = Screen.error;
      changed();
    }
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
    final all = await media.loadItems(onProgress: (n, total) {
      if (screen != Screen.loading) return;
      loading = 'Loading photos… $n of $total';
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

  int get _monthUsed => albums.where((a) => a.monthly).fold(0, (m, a) => max(m, a.lastUsedAt));

  /// That month's album, or a stand-in (id [monthAlbumId]) until the first photo is filed into it.
  Album monthChip(int t) {
    final start = startOfMonth(t);
    return albums.where((a) => a.monthly && a.start == start).firstOrNull ??
        Album(id: monthAlbumId, name: '', start: start, end: endOfMonth(t), createdAt: 0, lastUsedAt: _monthUsed, monthly: true);
  }

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

  List<Album> get barAlbums {
    final t = target;
    final recent = recentFor(group.firstOrNull?.taken);
    return t == null ? recent : [t, ...recent.where((a) => a.id != t.id)];
  }

  void choose(String id) {
    chosenId = id;
    changed();
  }

  /// The catch-all "YYYY-MM" album for the month of [t], created on first use.
  Future<Album> monthAlbumFor(int t) async {
    final start = startOfMonth(t);
    final found = albums.where((a) => a.monthly && a.start == start).firstOrNull;
    if (found != null) return found;
    final now = DateTime.now().millisecondsSinceEpoch;
    final a = Album(
        id: _uuid(), name: '', start: start, end: endOfMonth(t), createdAt: now, lastUsedAt: now, monthly: true);
    albums = [...albums, a];
    await db.put('albums', a.id, a.toJson());
    return a;
  }

  /// Saves an edited album. In Immich the album is renamed and its photos move to the new tag right away when
  /// possible; otherwise they're re-filed on the next sync.
  Future<void> updateAlbum(Album old, Album updated) async {
    final oldTitle = albumTitle(old), oldTag = albumTag(old);
    albums = [for (final a in albums) a.id == old.id ? updated : a];
    await db.put('albums', updated.id, updated.toJson());
    changed();
    final immichId = updated.immichAlbumId;
    if (immichId == null || (oldTitle == albumTitle(updated) && oldTag == albumTag(updated))) return;
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
  Future<void> decide(Dir dir) async {
    final t = target;
    if (t == null) return;
    await file(dir, t.id);
  }

  /// Records a decision for the photo on screen, or for a burst: all (or none) checked = the whole burst; else the
  /// checked ones, plus the rest the opposite way (setting). Leftovers stay on screen (same album) until decided.
  Future<void> file(Dir dir, String albumId) async {
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
    await _play({for (final i in keep) i.id: true, for (final i in del) i.id: false});
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
      _backlogRev = _rev;
    }
    return _backlog;
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

  Set<String> get gridMonthsChosen => {for (final i in gridChosen) monthPrefix(i.taken)};

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
      screen = mode;
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

  Future<void> toggleFolder(String bucket) async {
    hidden = {...hidden};
    if (!hidden.remove(bucket)) hidden.add(bucket);
    queue = queue.where(shown).toList();
    _nextCard();
    await db.setMeta('hiddenBuckets', hidden.toList());
    await reload();
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
  /// Reads an Immich album name the way Winnow writes them: "2026-11 Thanksgiving" (dated), "2026-11" (the month's
  /// album) or anything else (undated). Dates come from the album's photos when they fall in that month.
  Album _fromImmich(String id, String name, DateTime? from, DateTime? to, Album? base) {
    final now = DateTime.now().millisecondsSinceEpoch;
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
            .where((a) => a.immichAlbumId == null && albumTitle(a) == albumTitle(parsed) && a.monthly == parsed.monthly)
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
    _net ??= Connectivity().onConnectivityChanged.listen((r) {
      if (sync.waitingWifi && _isWifi(r)) runSync();
    });
  }

  bool _isWifi(List<ConnectivityResult> r) => r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);

  Future<bool> _onWifi() async {
    try {
      return _isWifi(await Connectivity().checkConnectivity());
    } catch (_) {
      return true;
    }
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
      {String? server, String? key, bool? enabled, Map<String, String>? shareWith, bool? wifiOnly, bool? videos}) async {
    immich = immich.copyWith(
        server: server == null ? null : cleanServer(server),
        key: key?.trim(),
        enabled: enabled,
        shareWith: shareWith,
        wifiOnly: wifiOnly,
        videos: videos);
    await _set('immich', immich.toJson());
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

  /// Uploads kept photos, then adds them to their Immich album (same name) and tag (Albums/YYYY/MM/name). One run at
  /// a time; a call during a run schedules another pass.
  Future<void> runSync() async {
    if (!immich.enabled || !immich.ready || _db == null) return;
    _watchNetwork();
    if (immich.wifiOnly && !await _onWifi()) {
      final records = {for (final j in await db.all('uploads')) UploadRecord.fromJson(j).id: UploadRecord.fromJson(j)};
      sync = SyncStatus(pending: _pendingUploads(records).length, done: sync.done, waitingWifi: true);
      changed();
      return;
    }
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    _syncing = true;
    final api = ImmichApi(immich);
    var done = 0;
    try {
      do {
        _syncAgain = false;
        final records = {for (final j in await db.all('uploads')) UploadRecord.fromJson(j).id: UploadRecord.fromJson(j)};
        final todo = _pendingUploads(records);
        void status() {
          sync = SyncStatus(running: true, pending: todo.length - done, done: done);
          changed();
        }

        status();
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
        for (final entry in moved.entries) {
          final old = albums.where((a) => a.id == entry.key).firstOrNull;
          if (old == null) continue;
          if (old.immichAlbumId != null) {
            await api.call('DELETE', '/albums/${old.immichAlbumId}/assets', {'ids': entry.value});
          }
          await api.call('DELETE', '/tags/${await api.ensureTag(albumTag(old))}/assets', {'ids': entry.value});
        }
        for (final entry in byAlbum.entries) {
          final album = albums.where((a) => a.id == entry.key).firstOrNull;
          if (album == null) continue;
          final immichId = await api.ensureAlbum(album);
          await db.put('albums', album.id, album.toJson());
          await api.share(immichId);
          final ids = [for (final r in entry.value) r.assetId];
          await api.addToAlbum(immichId, ids);
          await api.tag(await api.ensureTag(albumTag(album)), ids);
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
            done++;
          }
          status();
        }
      } while (_syncAgain);
      await _pullAlbumNames(api);
      sync = SyncStatus(done: done);
    } catch (e) {
      final records = {for (final j in await db.all('uploads')) UploadRecord.fromJson(j).id: UploadRecord.fromJson(j)};
      sync = SyncStatus(pending: _pendingUploads(records).length, done: done, error: '$e'.replaceFirst('Exception: ', ''));
    } finally {
      api.close();
      _syncing = false;
      changed();
    }
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

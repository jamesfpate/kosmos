import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../fx.dart';
import '../immich.dart';
import '../info.dart';
import '../media.dart' as media;
import '../models.dart';
import '../remote.dart';
import '../state.dart';
import 'album_sheet.dart';
import 'common.dart';
import 'dupes.dart';
import 'remote.dart';

/// Grid mode: every photo without an album, by month, in justified rows. Built lazily, so only rows near the screen
/// exist (thousands of photos scroll without holding thousands of thumbnails).
class GridScreen extends StatefulWidget {
  const GridScreen(this.s, {super.key});

  final AppState s;

  @override
  State<GridScreen> createState() => _GridScreenState();
}

sealed class _Entry {}

class _Header extends _Entry {
  _Header(this.items);
  final List<Item> items;
}

class _Row extends _Entry {
  _Row(this.h, this.items);
  final double h;
  final List<Item> items;
}

class _GridScreenState extends State<GridScreen> {
  // Two-finger pinch: spread for bigger thumbnails, pinch for smaller.
  final _pointers = <int, Offset>{};
  double? _pinchBase;
  final searching = FocusNode();
  final _scroll = ScrollController();

  /// The photo the keyboard is on (a white ring), and the grid as laid out last: rows with each photo's centre.
  String? _cursor;
  var _rows = <({double top, double h, List<({String id, double cx})> cells})>[];

  /// The row each group (a month, or an album in the gallery) starts at, for Tab / Shift+Tab.
  var _groupStarts = <int>[];

  AppState get s => widget.s;

  @override
  void dispose() {
    searching.dispose();
    _scroll.dispose();
    super.dispose();
  }

  static const _headerH = 40.0;

  /// Remembers where each photo sits, so ↑/↓ can find the one above or below and the view can follow the ring.
  void _remember(List<_Entry> entries) {
    var y = 0.0;
    final rows = <({double top, double h, List<({String id, double cx})> cells})>[];
    final starts = <int>[];
    for (final e in entries) {
      switch (e) {
        case _Header():
          starts.add(rows.length);
          y += _headerH;
        case _Row(:final h, :final items):
          var x = 0.0;
          final cells = <({String id, double cx})>[];
          for (final i in items) {
            final w = i.aspect * h;
            cells.add((id: i.id, cx: x + w / 2));
            x += w + 3;
          }
          rows.add((top: y, h: h, cells: cells));
          y += h + 3;
      }
    }
    _rows = rows;
    _groupStarts = starts;
  }

  /// Arrow keys (and h/j/k/l with Vim keys) move the ring; Enter, Space or x selects; Delete deletes the selection;
  /// Esc clears it. Ignored while typing in the album search.
  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (searching.hasFocus || _rows.isEmpty) return KeyEventResult.ignored;
    final k = e.logicalKey, vim = s.vimKeys;
    bool hit(LogicalKeyboardKey arrow, LogicalKeyboardKey letter) => k == arrow || (vim && k == letter);
    if (hit(LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.keyH)) return _move(0, -1);
    if (hit(LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.keyL)) return _move(0, 1);
    if (hit(LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.keyK)) return _move(-1, 0);
    if (hit(LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.keyJ)) return _move(1, 0);
    // Tab: the first photo of the next month (or album); Shift+Tab: of this one, or the one before.
    if (k == LogicalKeyboardKey.tab) return _group(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.space || (vim && k == LogicalKeyboardKey.keyX)) {
      if (_cursor == null) return _move(0, 0);
      s.toggleGrid(_cursor!);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && s.gridSel.isNotEmpty) {
      s.clearGrid();
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) && s.gridSel.isNotEmpty) {
      s.fileGrid(null);
      return KeyEventResult.handled;
    }
    if (vim && k == LogicalKeyboardKey.keyU && s.undoStack.isNotEmpty) {
      s.undo();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _move(int dRow, int dCol) {
    var r = 0, c = 0;
    final at = _cursor == null ? null : _where(_cursor!);
    if (at != null) {
      (r, c) = at;
      if (dCol != 0) {
        // Left/right run on through the rows, in the grid's order.
        c += dCol;
        if (c < 0 && r > 0) {
          r--;
          c = _rows[r].cells.length - 1;
        } else if (c >= _rows[r].cells.length && r < _rows.length - 1) {
          r++;
          c = 0;
        }
        c = c.clamp(0, _rows[r].cells.length - 1);
      } else if (dRow != 0) {
        // Up/down: the photo in the next row whose centre is nearest.
        final cx = _rows[r].cells[c].cx;
        r = (r + dRow).clamp(0, _rows.length - 1);
        final cells = _rows[r].cells;
        c = 0;
        for (var j = 1; j < cells.length; j++) {
          if ((cells[j].cx - cx).abs() < (cells[c].cx - cx).abs()) c = j;
        }
      }
    }
    setState(() => _cursor = _rows[r].cells[c].id);
    _follow(_rows[r]);
    return KeyEventResult.handled;
  }

  KeyEventResult _group(int dir) {
    if (_groupStarts.isEmpty) return KeyEventResult.handled;
    final at = _cursor == null ? null : _where(_cursor!);
    final row = at?.$1 ?? -1;
    int? to;
    if (dir > 0) {
      to = _groupStarts.where((g) => g > row).firstOrNull ?? (at == null ? _groupStarts.first : null);
    } else {
      final here = _groupStarts.lastWhere((g) => g <= row, orElse: () => 0);
      to = (at != null && (at.$1 != here || at.$2 != 0)) ? here : _groupStarts.lastWhere((g) => g < here, orElse: () => here);
    }
    if (to == null) return KeyEventResult.handled;
    setState(() => _cursor = _rows[to!].cells.first.id);
    _follow(_rows[to]);
    return KeyEventResult.handled;
  }

  (int, int)? _where(String id) {
    for (final (r, row) in _rows.indexed) {
      for (final (c, cell) in row.cells.indexed) {
        if (cell.id == id) return (r, c);
      }
    }
    return null;
  }

  /// Scrolls just enough to show the row with the ring.
  void _follow(({double top, double h, List<({String id, double cx})> cells}) row) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position, top = row.top - _headerH, bottom = row.top + row.h + 8;
    final to = top < p.pixels ? top : (bottom > p.pixels + p.viewportDimension ? bottom - p.viewportDimension : null);
    if (to != null) _scroll.animateTo(to.clamp(0, p.maxScrollExtent), duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
  }

  List<_Entry> _entries(double width) {
    final out = <_Entry>[];
    var month = <Item>[];
    String? key;
    void flush() {
      if (month.isEmpty) return;
      out.add(_Header(month));
      for (final r in justify(month, width, s.thumbH)) {
        out.add(_Row(r.h, r.items));
      }
    }

    for (final i in s.backlog) {
      final k = s.byAlbum ? (s.albumOf(i) ?? '') : monthPrefix(i.taken);
      if (k != key) {
        flush();
        month = [];
        key = k;
      }
      month.add(i);
    }
    flush();
    return out;
  }

  double _dist() {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  @override
  Widget build(BuildContext context) {
    final sel = s.gridSel;
    final target = s.gridTarget;
    final doomed = s.gridDoomed;
    final months = s.gridMonthsChosen.length;
    String chipLabel(Album a) => a.monthly && months > 1 ? '${s.byYear ? 'By year' : 'By month'} ($months)' : albumTitle(a);
    if (s.screen == Screen.explore && s.gridView == 'duplicates') {
      return Column(children: [
        TopBar(s, title: const Logo(tap: true), subtitle: const Text('Duplicates')),
        SourceBar(s),
        _viewBar(context),
        const SizedBox(height: 6),
        Expanded(child: DuplicatesView(s)),
      ]);
    }
    if (s.screen == Screen.explore && isImmichView(s.gridView)) {
      return Column(children: [
        TopBar(s, title: const Logo(tap: true), subtitle: const Text('Immich')),
        _viewBar(context),
        const SizedBox(height: 6),
        Expanded(child: RemoteExplorer(s, key: ValueKey(s.gridView), view: s.gridView)),
      ]);
    }
    return Focus(
      autofocus: true,
      onKeyEvent: _key,
      child: Column(children: [
      TopBar(
        s,
        title: const Logo(tap: true),
        subtitle: Text(
            (s.screen == Screen.explore ? '${s.backlog.length} photos' : '${s.unreviewedCount} unreviewed')),
      ),
      SourceBar(s),
      if (s.screen == Screen.explore) ...[_viewBar(context), const SizedBox(height: 6)],
      // The label, with the selection's actions (fill the gaps, clear) on the same line: no row of its own.
      SizedBox(
        height: 24,
        child: Row(children: [
          Expanded(
            child: Label(sel.isEmpty
                ? (s.gridView == 'unreviewed' ? 'Pick an album, then select photos' : 'Select photos to move or delete them')
                : 'Choose album for ${sel.length}${doomed.isNotEmpty ? ' · deletes ${doomed.length} in red' : ''}'),
          ),
          if (sel.isNotEmpty) _link(Icons.close, 'Clear', s.clearGrid),
        ]),
      ),
      const SizedBox(height: 4),
      AlbumBar(
        albums: s.gridAlbums,
        more: s.quietAlbums,
        label: chipLabel,
        isTarget: (a) => a.id == target?.id,
        onPick: (a) => sel.isNotEmpty
            ? s.fileGrid(a.monthly ? monthAlbumId : a.id)
            : (a.id == target?.id ? editAlbum(context, s, a) : s.chooseGrid(a.monthly ? monthAlbumId : a.id)),
        onEdit: (a) => editAlbum(context, s, a),
        // Dated from the selected photos (oldest); with none selected yet, from the first photo filed into it.
        onNew: (name) => newAlbum(context, s, s.gridOldest, fileAfter: sel.isNotEmpty, grid: true, name: name),
        focus: searching,
      ),
      const SizedBox(height: 4),
      Expanded(
        child: s.backlog.isEmpty
            ? Center(
                child: Text(s.gridView == 'unreviewed' ? 'Everything has an album' : 'Nothing here',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)))
            : Listener(
                onPointerDown: (e) {
                  _pointers[e.pointer] = e.position;
                  if (_pointers.length == 2) _pinchBase = _dist();
                },
                onPointerMove: (e) {
                  _pointers[e.pointer] = e.position;
                  if (_pointers.length == 2 && _pinchBase != null) {
                    final d = _dist();
                    s.setThumbH(s.thumbH * d / _pinchBase!);
                    _pinchBase = d;
                  }
                },
                onPointerUp: (e) => _lift(e.pointer),
                onPointerCancel: (e) => _lift(e.pointer),
                child: LayoutBuilder(builder: (context, box) {
                  final entries = _entries(box.maxWidth);
                  _remember(entries);
                  return ListView.builder(
                    controller: _scroll,
                    itemCount: entries.length,
                    itemBuilder: (context, i) => switch (entries[i]) {
                      // A fixed height, so the keyboard ring can work out where each row is.
                      _Header(:final items) => SizedBox(
                          height: _headerH, child: s.byAlbum ? _albumHeader(items) : _monthHeader(items)),
                      _Row(:final h, :final items) => Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Row(children: [
                            for (final (n, item) in items.indexed) ...[
                              if (n > 0) const SizedBox(width: 3),
                              _cell(item, h, doomed.contains(item.id)),
                            ],
                          ]),
                        ),
                    },
                  );
                }),
              ),
      ),
      SizeSlider(s),
      Row(children: [
        // Undo is just an icon: half the width it had, which leaves room for Fill when there are gaps.
        Expanded(flex: 3, child: Btn('', icon: Icons.undo, onTap: s.undoStack.isEmpty ? null : s.undo)),
        const SizedBox(width: 6),
        if (sel.isNotEmpty && s.gapCount > 0) ...[
          Expanded(flex: 8, child: Btn('Fill ${s.gapCount}', icon: Icons.swap_horiz, color: C.accent, onTap: s.selectBetween)),
          const SizedBox(width: 6),
        ],
        Expanded(
          flex: 13,
          child: Btn(sel.isEmpty ? 'Delete' : 'Delete ${sel.length}', icon: Icons.arrow_back, color: C.trash, onTap: sel.isEmpty ? null : () => s.fileGrid(null)),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 17,
          child: Btn(target == null ? 'Album' : chipLabel(target),
              icon: Icons.arrow_forward,
              bold: true,
              color: C.bg,
              bg: C.keep,
              // With "Delete the gaps" on, filing also deletes the red ones: say so, as the burst buttons do.
              sub: sel.isNotEmpty && doomed.isNotEmpty ? 'keep ${sel.length} · delete ${doomed.length}' : null,
              onTap: sel.isEmpty || target == null ? null : () => s.fileGrid(target.monthly ? monthAlbumId : target.id)),
        ),
      ]),
    ]),
    );
  }

  /// Which photos the grid shows: Unreviewed, All, or one album (an explorer; selecting + an album moves them).
  Widget _viewBar(BuildContext context) {
    final view = s.gridView;
    final album = s.albums.where((a) => a.id == view).firstOrNull;
    Widget chip(String label, bool on, VoidCallback tap) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            label: Text(label),
            selected: on,
            onSelected: (_) => tap(),
            selectedColor: C.accent,
            backgroundColor: C.surface,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            labelStyle: TextStyle(color: on ? C.bg : C.text, fontWeight: on ? FontWeight.w600 : null),
            side: BorderSide(color: on ? C.accent : C.line),
          ),
        );
    return SizedBox(
      height: 40,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        chip('All on ${media.device}', view == 'all', () => s.setGridView('all')),
        chip('Reviewed', view == 'reviewed', () => s.setGridView('reviewed')),
        chip('Duplicates', view == 'duplicates', () => s.setGridView('duplicates')),
        chip(album == null ? 'Albums ▾' : '${albumTitle(album)} ▾', album != null, () => _pickAlbum(context)),
        if (s.immich.ready)
          chip(isImmichView(view) ? '${_immichLabel(view)} ▾' : 'Immich ▾', isImmichView(view), () => _pickImmich(context)),
      ]),
    );
  }

  String _immichLabel(String view) => switch (view) {
        immichAll => 'Immich',
        immichOnly => 'Only on Immich',
        _ => s.immichAlbumNames[view.substring(immichAlbumPrefix.length)] ?? 'Immich album',
      };

  /// Immich as the source: everything, only what isn't on this phone, or one Immich album.
  Future<void> _pickImmich(BuildContext context) async {
    final api = ImmichApi(s.immich);
    final albums = api.albums().then((l) => l..sort((a, b) => b.name.compareTo(a.name))).whenComplete(api.close);
    final view = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: C.surface,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: FutureBuilder(
            future: albums,
            builder: (c, snap) => ListView(shrinkWrap: true, children: [
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('Everything on Immich'),
                onTap: () => Navigator.pop(c, immichAll),
              ),
              ListTile(
                leading: const Icon(Icons.cloud_off_outlined),
                title: const Text('Only on Immich'),
                subtitle: Text('Not on this ${media.device}'),
                onTap: () => Navigator.pop(c, immichOnly),
              ),
              const Divider(),
              if (snap.hasError) ListTile(title: Text("Can't load albums: ${snap.error}")),
              if (!snap.hasData && !snap.hasError) const ListTile(title: Text('Loading albums…')),
              for (final a in snap.data ?? const <({String id, String name, DateTime? start, DateTime? end})>[])
                ListTile(
                  title: Text(a.name),
                  onTap: () {
                    s.rememberImmichAlbum(a.id, a.name);
                    Navigator.pop(c, '$immichAlbumPrefix${a.id}');
                  },
                ),
            ]),
          ),
        ),
      ),
    );
    if (view != null) s.setGridView(view);
  }

  Future<void> _pickAlbum(BuildContext context) async {
    final counts = s.albumCounts;
    final list = [...s.albums.where((a) => (counts[a.id] ?? 0) > 0)]..sort((a, b) => albumTitle(b).compareTo(albumTitle(a)));
    final id = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: C.surface,
      builder: (c) => SafeArea(
        child: list.isEmpty
            ? const Padding(padding: EdgeInsets.all(24), child: Text('No albums with photos yet.'))
            : ListView(shrinkWrap: true, children: [
                for (final a in list)
                  ListTile(
                    title: Text(albumTitle(a)),
                    trailing: Text('${counts[a.id]}', style: const TextStyle(color: C.muted)),
                    onTap: () => Navigator.pop(c, a.id),
                  ),
              ]),
      ),
    );
    if (id != null) s.setGridView(id);
  }

  void _lift(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.length < 2 && _pinchBase != null) {
      _pinchBase = null;
      s.setThumbH(s.thumbH, save: true);
    }
  }

  Widget _link(IconData? icon, String text, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 16, color: C.accent), const SizedBox(width: 3)],
          Text(text, style: const TextStyle(color: C.accent, fontSize: 13)),
        ]),
      );

  Widget _monthHeader(List<Item> items) {
    final all = items.every((i) => s.gridSel.contains(i.id));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(child: Text(fmtMonth.format(DateTime.fromMillisecondsSinceEpoch(items.first.taken)), style: const TextStyle(fontWeight: FontWeight.w700))),
        GestureDetector(
          onTap: () => s.toggleMonth(items),
          child: Text('${all ? 'Clear' : 'Select'} ${items.length}', style: const TextStyle(color: C.accent)),
        ),
      ]),
    );
  }

  /// A gallery section: the album (and when its first photo was taken), Move… for the whole album, Select.
  Widget _albumHeader(List<Item> items) {
    final id = s.albumOf(items.first);
    final album = s.albums.where((a) => a.id == id).firstOrNull;
    final all = items.every((i) => s.gridSel.contains(i.id));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(
          child: Text.rich(
            TextSpan(text: album == null ? 'Not in an album yet' : albumTitle(album), children: [
              if (album != null)
                TextSpan(
                    text: '  ·  ${fmtDay.format(DateTime.fromMillisecondsSinceEpoch(items.map((i) => i.taken).reduce(min)))}',
                    style: const TextStyle(color: C.muted, fontWeight: FontWeight.w400)),
            ]),
            style: const TextStyle(fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (album != null) ...[
          GestureDetector(
            onTap: () async {
              final to = await pickAlbum(context, s.albums.where((a) => a.id != album.id && !a.retired).toList(),
                  title: 'Move ${albumTitle(album)} into');
              if (to != null) await s.moveAlbum(album.id, to.id);
            },
            child: const Text('Move…', style: TextStyle(color: C.accent)),
          ),
          const SizedBox(width: 16),
        ],
        GestureDetector(
          onTap: () => s.toggleMonth(items),
          child: Text('${all ? 'Clear' : 'Select'} ${items.length}', style: const TextStyle(color: C.accent)),
        ),
      ]),
    );
  }

  /// Wraps a photo in the keep/delete trace while it's playing.
  Widget _fx(Item item, Widget child) {
    final f = s.fx[item.id];
    return f == null ? child : TraceFx(item: item, keep: f, child: child);
  }

  Widget _cell(Item item, double h, bool doomed) {
    final checked = s.gridSel.contains(item.id);
    return GestureDetector(
      onTap: () => s.toggleGrid(item.id),
      onLongPress: () => Navigator.of(context).push(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => Viewer(s, start: s.backlog.indexWhere((i) => i.id == item.id)),
      )),
      child: SizedBox(
        width: item.aspect * h,
        height: h,
        child: _fx(item, Stack(fit: StackFit.expand, children: [
          Opacity(opacity: doomed ? 0.55 : 1, child: PhotoThumb(item, height: h)),
          if (item.isVideo) const Positioned(bottom: 6, right: 6, child: VideoBadge()),
          if (checked) const Positioned(top: 5, left: 5, child: CheckBadge()),
          if (checked || doomed)
            IgnorePointer(
              child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: checked ? C.select : C.trash, width: 3))),
            ),
          // The keyboard's place: a white ring (inside any selection border).
          if (item.id == _cursor)
            IgnorePointer(
              child: Padding(
                padding: EdgeInsets.all(checked || doomed ? 3 : 0),
                child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: C.text, width: 2))),
              ),
            ),
        ])),
      ),
    );
  }
}

/// Full-size view from the grid: swipe through neighbours, select, close.
class Viewer extends StatefulWidget {
  const Viewer(this.s, {super.key, required this.start});

  final AppState s;
  final int start;

  @override
  State<Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<Viewer> {
  late final PageController _pages = PageController(initialPage: widget.start);
  late int index = widget.start;
  String? playing;

  /// Pinch zoom (one finger then moves around); pages hold still while zoomed or while two fingers are down.
  final _zoom = TransformationController();
  bool zoomed = false;
  int _fingers = 0;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() {
      final z = _zoom.value.getMaxScaleOnAxis() > 1.01;
      if (z != zoomed) setState(() => zoomed = z);
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _touch(int d) {
    final was = _fingers > 1;
    _fingers = max(0, _fingers + d);
    if (was != _fingers > 1) setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.s,
        builder: (context, _) {
          final s = widget.s;
          final list = s.backlog;
          if (list.isEmpty) return const SizedBox();
          final item = list[index.clamp(0, list.length - 1)];
          final sel = s.gridSel.contains(item.id);
          return pagerKeys(context, _pages, Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        // With photo info on, the date is under the photo.
                        if (infoFields.isEmpty) ...[
                          Text(dayOf(item.taken), style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text('${timeOf(item.taken)} · ${item.bucket}', style: const TextStyle(color: C.muted, fontSize: 13)),
                        ] else
                          Text(item.bucket, style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                    ),
                    Text('${index + 1} of ${list.length}', style: const TextStyle(color: C.muted)),
                  ]),
                  Expanded(
                    child: Listener(
                      onPointerDown: (_) => _touch(1),
                      onPointerUp: (_) => _touch(-1),
                      onPointerCancel: (_) => _touch(-1),
                      child: PageView.builder(
                        controller: _pages,
                        scrollBehavior: pagerScroll,
                        physics: zoomed || _fingers > 1 ? const NeverScrollableScrollPhysics() : null,
                        itemCount: list.length,
                        onPageChanged: (i) => setState(() {
                          index = i;
                          playing = null;
                          _zoom.value = Matrix4.identity();
                        }),
                        itemBuilder: (_, i) => Stack(alignment: Alignment.center, children: [
                          Positioned.fill(
                            child: InteractiveViewer(
                              transformationController: i == index ? _zoom : null,
                              maxScale: 8,
                              child: Center(
                                child: Preview(list[i],
                                    play: playing == list[i].id,
                                    onStop: () => setState(() => playing = null),
                                    caption: !zoomed),
                              ),
                            ),
                          ),
                          if (list[i].isVideo && playing != list[i].id)
                            PlayButton(seconds: list[i].duration, onTap: () => setState(() => playing = list[i].id)),
                        ]),
                      ),
                    ),
                  ),
                  Text(zoomed ? (media.desktop ? 'Scroll out to see the whole photo' : 'Pinch out to see the whole photo') : (media.desktop ? '← → for the next photo · scroll to zoom' : 'Swipe for the next photo · pinch to zoom'),
                      style: const TextStyle(color: C.muted, fontSize: 12.5)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: Btn('Close', icon: Icons.close, onTap: () => Navigator.pop(context))),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Btn(sel ? 'Selected' : 'Select',
                          icon: sel ? Icons.check : null,
                          bold: sel,
                          color: sel ? C.bg : null,
                          bg: sel ? C.select : null,
                          onTap: () => s.toggleGrid(item.id)),
                    ),
                  ]),
                ]),
              ),
            ),
          ));
        },
      );
}

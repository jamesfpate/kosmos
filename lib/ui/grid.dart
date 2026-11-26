import 'package:flutter/material.dart';

import '../fx.dart';
import '../models.dart';
import '../state.dart';
import 'album_sheet.dart';
import 'common.dart';

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

  AppState get s => widget.s;

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
      final k = monthPrefix(i.taken);
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
    String chipLabel(Album a) => a.monthly && months > 1 ? 'By month ($months)' : albumTitle(a);
    return Column(children: [
      TopBar(
        s,
        title: Logo(busy: s.sync.running),
        subtitle: Text(syncStatus(s) ??
            (s.screen == Screen.explore ? '${s.backlog.length} photos' : '${s.unreviewedCount} unreviewed')),
      ),
      if (s.screen == Screen.explore) ...[_viewBar(context), const SizedBox(height: 6)],
      Align(
        alignment: Alignment.centerLeft,
        child: Label(sel.isEmpty
            ? (s.gridView == 'unreviewed' ? 'Pick an album, then select photos' : 'Select photos to move or delete them')
            : 'Choose album for ${sel.length}${doomed.isNotEmpty ? ' · deletes ${doomed.length} in red' : ''}'),
      ),
      const SizedBox(height: 4),
      SizedBox(
        height: 44,
        child: Row(children: [
          Expanded(
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final a in s.gridAlbums)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AlbumChip(
                    label: chipLabel(a),
                    target: a.id == target?.id,
                    onTap: () => sel.isNotEmpty
                        ? s.fileGrid(a.monthly ? monthAlbumId : a.id)
                        : (a.id == target?.id ? editAlbum(context, s, a) : s.chooseGrid(a.monthly ? monthAlbumId : a.id)),
                    onLongPress: () => editAlbum(context, s, a),
                  ),
                ),
            ]),
          ),
          const SizedBox(width: 6),
          AlbumChip(
            label: '+',
            dashed: true,
            // Dated from the selected photos (oldest); with none selected yet, from the first photo filed into it.
            onTap: () => newAlbum(context, s, s.gridOldest, fileAfter: sel.isNotEmpty, grid: true),
          ),
        ]),
      ),
      // Selection, right above the photos: count, select between (fill the gaps), clear.
      SizedBox(
        height: 32,
        child: sel.isEmpty
            ? null
            : Row(children: [
                Text('${sel.length} selected', style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                if (s.gapCount > 0) ...[
                  _link(Icons.swap_horiz, 'Fill ${s.gapCount}', s.selectBetween),
                  const SizedBox(width: 16),
                ],
                _link(Icons.close, 'Clear', s.clearGrid),
              ]),
      ),
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
                  return ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, i) => switch (entries[i]) {
                      _Header(:final items) => _monthHeader(items),
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
        Expanded(flex: 6, child: Btn('', icon: Icons.undo, onTap: s.undoStack.isEmpty ? null : s.undo)),
        const SizedBox(width: 6),
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
              onTap: sel.isEmpty || target == null ? null : () => s.fileGrid(target.monthly ? monthAlbumId : target.id)),
        ),
      ]),
    ]);
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
        chip('All on phone', view == 'all', () => s.setGridView('all')),
        chip('Reviewed', view == 'reviewed', () => s.setGridView('reviewed')),
        chip(album == null ? 'Albums ▾' : '${albumTitle(album)} ▾', album != null, () => _pickAlbum(context)),
      ]),
    );
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.s,
        builder: (context, _) {
          final s = widget.s;
          final list = s.backlog;
          if (list.isEmpty) return const SizedBox();
          final item = list[index.clamp(0, list.length - 1)];
          final sel = s.gridSel.contains(item.id);
          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(dayOf(item.taken), style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${timeOf(item.taken)} · ${item.bucket}', style: const TextStyle(color: C.muted, fontSize: 13)),
                      ]),
                    ),
                    Text('${index + 1} of ${list.length}', style: const TextStyle(color: C.muted)),
                  ]),
                  Expanded(
                    child: PageView.builder(
                      controller: _pages,
                      itemCount: list.length,
                      onPageChanged: (i) => setState(() {
                        index = i;
                        playing = null;
                      }),
                      itemBuilder: (_, i) => Stack(alignment: Alignment.center, children: [
                        Center(child: Preview(list[i], play: playing == list[i].id, onStop: () => setState(() => playing = null))),
                        if (list[i].isVideo && playing != list[i].id)
                          Positioned(
                            bottom: 16,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(backgroundColor: Colors.black54),
                              onPressed: () => setState(() => playing = list[i].id),
                              icon: const Icon(Icons.play_arrow),
                              label: Text('${list[i].entity.duration}s'),
                            ),
                          ),
                      ]),
                    ),
                  ),
                  const Text('Swipe for the next photo', style: TextStyle(color: C.muted, fontSize: 12.5)),
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
          );
        },
      );
}

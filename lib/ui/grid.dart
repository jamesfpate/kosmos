import 'package:flutter/material.dart';

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
        title: sel.isEmpty ? const Logo() : Text('${sel.length} selected'),
        subtitle: sel.isEmpty
            ? Text('${s.backlog.length} without an album')
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (s.gapCount > 0) ...[
                  _link(Icons.swap_horiz, 'Fill ${s.gapCount}', s.selectBetween),
                  const Text('  ·  ', style: TextStyle(color: C.muted)),
                ],
                _link(null, 'Clear', s.clearGrid),
              ]),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: Label(sel.isEmpty
            ? 'Pick an album, then select photos'
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
                    onTap: () => sel.isEmpty ? s.chooseGrid(a.monthly ? monthAlbumId : a.id) : s.fileGrid(a.monthly ? monthAlbumId : a.id),
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
      const SizedBox(height: 4),
      Expanded(
        child: s.backlog.isEmpty
            ? const Center(child: Text('Everything has an album', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)))
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
          flex: 10,
          child: Btn(sel.isEmpty ? 'Delete' : 'Delete ${sel.length}', icon: Icons.arrow_back, color: C.trash, onTap: sel.isEmpty ? null : () => s.fileGrid(null)),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 20,
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
        child: Stack(fit: StackFit.expand, children: [
          Opacity(opacity: doomed ? 0.55 : 1, child: PhotoThumb(item, height: h)),
          if (item.isVideo) const Positioned(bottom: 6, right: 6, child: VideoBadge()),
          if (checked) const Positioned(top: 5, left: 5, child: CheckBadge()),
          if (checked || doomed)
            DecoratedBox(decoration: BoxDecoration(border: Border.all(color: checked ? C.select : C.trash, width: 3))),
        ]),
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

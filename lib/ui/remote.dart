import 'package:flutter/material.dart';

import '../models.dart';
import '../remote.dart';
import '../state.dart';
import 'common.dart';

/// Explorer showing Immich: photos by month, paged in as you scroll. Select, then tap an album to add (or, inside an
/// album, move) them, or save them to the phone. Long-press for full size.
class RemoteExplorer extends StatefulWidget {
  const RemoteExplorer(this.s, {super.key, required this.view});

  final AppState s;
  final String view;

  @override
  State<RemoteExplorer> createState() => _RemoteExplorerState();
}

sealed class _Entry {}

class _Header extends _Entry {
  _Header(this.taken, this.count);
  final int taken;
  final int count;
}

class _Row extends _Entry {
  _Row(this.h, this.items);
  final double h;
  final List<RemoteAsset> items;
}

class _RemoteExplorerState extends State<RemoteExplorer> {
  late final b = ImmichBrowser(widget.s, widget.view)..start();

  @override
  void dispose() {
    b.dispose();
    super.dispose();
  }

  List<_Entry> _entries(double width) {
    final out = <_Entry>[];
    var month = <RemoteAsset>[];
    String? key;
    void flush() {
      if (month.isEmpty) return;
      out.add(_Header(month.first.taken, month.length));
      var row = <RemoteAsset>[];
      var sum = 0.0;
      final h = widget.s.thumbH;
      for (final a in month) {
        row.add(a);
        sum += a.aspect;
        final gaps = (row.length - 1) * 3;
        if (sum * h + gaps >= width) {
          out.add(_Row((width - gaps) / sum, row));
          row = [];
          sum = 0;
        }
      }
      if (row.isNotEmpty) out.add(_Row(h, row));
    }

    for (final a in b.assets) {
      final k = monthPrefix(a.taken);
      if (k != key) {
        flush();
        month = [];
        key = k;
      }
      month.add(a);
    }
    flush();
    return out;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: b,
        builder: (context, _) {
          final sel = b.sel;
          final albums = b.albums.where((a) => a.id != b.albumId).toList();
          return Column(children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Label(sel.isEmpty
                  ? 'Select to ${b.albumId != null ? 'move' : 'add to an album'} or save'
                  : '${b.albumId != null ? 'Move' : 'Add'} ${sel.length} to'),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 44,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final a in albums)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: AlbumChip(label: a.name, onTap: sel.isEmpty || b.busy ? null : () => b.fileInto(a.id)),
                  ),
              ]),
            ),
            SizedBox(
              height: 32,
              child: Row(children: [
                Expanded(
                  child: Text(
                    b.message.isNotEmpty ? b.message : (sel.isEmpty ? '' : '${sel.length} selected'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, color: b.message.isNotEmpty ? C.muted : C.text),
                  ),
                ),
                if (sel.isNotEmpty)
                  GestureDetector(
                    onTap: b.clear,
                    child: const Row(children: [
                      Icon(Icons.close, size: 16, color: C.accent),
                      SizedBox(width: 3),
                      Text('Clear', style: TextStyle(color: C.accent, fontSize: 13)),
                    ]),
                  ),
              ]),
            ),
            Expanded(child: _grid()),
            SizeSlider(widget.s),
            Btn(sel.isEmpty ? 'Save to phone' : 'Save ${sel.length} to phone',
                icon: Icons.download, onTap: sel.isEmpty || b.busy ? null : b.saveToPhone),
          ]);
        },
      );

  Widget _grid() {
    if (b.error.isNotEmpty && b.assets.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text("Can't load Immich: ${b.error}", textAlign: TextAlign.center, style: const TextStyle(color: C.muted)),
        ),
      );
    }
    if (b.assets.isEmpty) {
      return Center(
        child: b.loading
            ? const Logo(size: 28, busy: true)
            : Text(b.onlyRemote ? 'Everything on Immich is on this phone too' : 'Nothing here',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 1500) b.more();
        return false;
      },
      child: LayoutBuilder(builder: (context, box) {
        final entries = _entries(box.maxWidth);
        return ListView.builder(
          itemCount: entries.length + 1,
          itemBuilder: (context, i) {
            if (i == entries.length) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: b.loading
                      ? const Logo(size: 22, busy: true)
                      : Text(b.done ? '${b.assets.length} photos' : '', style: const TextStyle(color: C.muted)),
                ),
              );
            }
            return switch (entries[i]) {
              _Header(:final taken, :final count) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    Expanded(
                      child: Text(fmtMonth.format(DateTime.fromMillisecondsSinceEpoch(taken)),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    Text('$count', style: const TextStyle(color: C.muted)),
                  ]),
                ),
              _Row(:final h, :final items) => Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(children: [
                    for (final (n, a) in items.indexed) ...[
                      if (n > 0) const SizedBox(width: 3),
                      _cell(a, h),
                    ],
                  ]),
                ),
            };
          },
        );
      }),
    );
  }

  Widget _cell(RemoteAsset a, double h) {
    final checked = b.sel.contains(a.id);
    return GestureDetector(
      onTap: () => b.toggle(a.id),
      onLongPress: () => Navigator.of(context).push(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => RemoteViewer(b, start: b.assets.indexOf(a)),
      )),
      child: SizedBox(
        width: a.aspect * h,
        height: h,
        child: Stack(fit: StackFit.expand, children: [
          Image.network(
            b.api.thumbUrl(a.id),
            headers: b.api.imageHeaders,
            fit: BoxFit.cover,
            cacheHeight: (h * MediaQuery.devicePixelRatioOf(context)).round(),
            errorBuilder: (_, _, _) => const ColoredBox(color: C.surface, child: Icon(Icons.broken_image, color: C.muted)),
          ),
          if (a.isVideo) const Positioned(bottom: 6, right: 6, child: VideoBadge()),
          // Not on this phone.
          if (!a.onPhone && !b.onlyRemote)
            const Positioned(
              bottom: 5,
              left: 5,
              child: Icon(Icons.cloud_outlined, size: 18, color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
            ),
          if (checked) const Positioned(top: 5, left: 5, child: CheckBadge()),
          if (checked)
            IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: C.select, width: 3)))),
        ]),
      ),
    );
  }
}

/// Full-size Immich photos (the server's preview size), swipe through, select, close.
class RemoteViewer extends StatefulWidget {
  const RemoteViewer(this.b, {super.key, required this.start});

  final ImmichBrowser b;
  final int start;

  @override
  State<RemoteViewer> createState() => _RemoteViewerState();
}

class _RemoteViewerState extends State<RemoteViewer> {
  late final PageController _pages = PageController(initialPage: widget.start);
  late int index = widget.start;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.b,
        builder: (context, _) {
          final b = widget.b;
          final list = b.assets;
          if (list.isEmpty) return const SizedBox();
          final a = list[index.clamp(0, list.length - 1)];
          final sel = b.sel.contains(a.id);
          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(dayOf(a.taken), style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${timeOf(a.taken)} · ${a.onPhone ? 'on this phone too' : 'only on Immich'}',
                            style: const TextStyle(color: C.muted, fontSize: 13)),
                      ]),
                    ),
                    Text('${index + 1} of ${list.length}', style: const TextStyle(color: C.muted)),
                  ]),
                  Expanded(
                    child: PageView.builder(
                      controller: _pages,
                      itemCount: list.length,
                      onPageChanged: (i) {
                        setState(() => index = i);
                        if (i > list.length - 20) b.more();
                      },
                      itemBuilder: (_, i) => Center(
                        child: AspectRatio(
                          aspectRatio: list[i].aspect,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.network(b.api.thumbUrl(list[i].id, preview: true),
                                headers: b.api.imageHeaders, fit: BoxFit.cover, gaplessPlayback: true),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (a.isVideo)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('Video: save it to the phone to play it', style: TextStyle(color: C.muted, fontSize: 12.5)),
                    ),
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
                          onTap: () => b.toggle(a.id)),
                    ),
                  ]),
                ]),
              ),
            ),
          );
        },
      );
}

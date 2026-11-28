import 'package:flutter/material.dart';

import '../dupes.dart';
import '../models.dart';
import '../state.dart';
import 'common.dart';

/// The gallery's Duplicates view: each group of exact copies or similar shots, the best one kept (blue) and the rest
/// to delete (red). Tap a photo to keep or drop it; long-press to compare at full size. Deletes go to the trash.
class DuplicatesView extends StatefulWidget {
  const DuplicatesView(this.s, {super.key});

  final AppState s;

  @override
  State<DuplicatesView> createState() => _DuplicatesViewState();
}

class _DuplicatesViewState extends State<DuplicatesView> {
  /// Per group (keyed by its best photo): the photos to keep. Starts with just the best one.
  final _keep = <String, Set<String>>{};

  AppState get s => widget.s;

  Set<String> keepOf(DupGroup g) => _keep.putIfAbsent(g.items.first.id, () => {g.items.first.id});

  List<Item> dropOf(DupGroup g) => g.items.where((i) => !keepOf(g).contains(i.id)).toList();

  @override
  Widget build(BuildContext context) {
    final groups = s.dupGroups;
    if (s.dupScanning) {
      return Center(
        child: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Checking ${s.dupDone} of ${s.dupTotal} photos…', style: const TextStyle(color: C.muted)),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: s.dupTotal == 0 ? null : s.dupDone / s.dupTotal, color: C.accent, backgroundColor: C.line),
          ]),
        ),
      );
    }
    if (groups == null || groups.isEmpty) {
      return Center(
        child: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(groups == null ? 'Find duplicates' : 'No duplicates found',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text(
              'Exact copies (the same file twice) and similar shots taken within a few minutes. Everything is checked '
              'on this device; the best of each group is kept for you.',
              textAlign: TextAlign.center,
              style: TextStyle(color: C.muted),
            ),
            const SizedBox(height: 14),
            Btn(groups == null ? 'Scan for duplicates' : 'Scan again', bold: true, color: C.bg, bg: C.accent, onTap: s.scanDuplicates),
          ]),
        ),
      );
    }
    final extra = groups.fold<int>(0, (n, g) => n + dropOf(g).length);
    return Column(children: [
      Row(children: [
        Expanded(
          child: Text('${groups.length} groups · $extra to delete', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        TextButton(onPressed: s.scanDuplicates, child: const Text('Scan again', style: TextStyle(color: C.accent))),
        const SizedBox(width: 8),
        Btn('Delete $extra', icon: Icons.delete_outline, color: C.trash, onTap: extra == 0 ? null : () => s.dropDuplicates([for (final g in groups) ...dropOf(g)])),
      ]),
      const SizedBox(height: 6),
      Expanded(
        child: ListView.separated(
          itemCount: groups.length,
          separatorBuilder: (_, _) => const SizedBox(height: 14),
          itemBuilder: (context, n) => _group(context, groups[n]),
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text('Deleted duplicates go to the trash for review first.', style: TextStyle(color: C.muted, fontSize: 12.5)),
      ),
    ]);
  }

  Widget _group(BuildContext context, DupGroup g) {
    final keep = keepOf(g), drop = dropOf(g);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(g.exact ? Icons.copy_all : Icons.burst_mode_outlined, size: 18, color: C.muted),
          const SizedBox(width: 6),
          Text(g.exact ? 'Exact copies' : 'Similar shots', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Text('${dayOf(g.items.first.taken)} · keep ${keep.length} · delete ${drop.length}', style: const TextStyle(color: C.muted)),
          const Spacer(),
          TextButton(
            onPressed: drop.isEmpty ? null : () => s.dropDuplicates(drop),
            child: Text('Delete ${drop.length}', style: TextStyle(color: drop.isEmpty ? C.muted : C.trash)),
          ),
        ]),
        const SizedBox(height: 6),
        SizedBox(
          height: 130,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final i in g.items)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => setState(() => keep.contains(i.id) ? keep.remove(i.id) : keep.add(i.id)),
                  onLongPress: () => FullView.open(context, g.items, i),
                  child: SizedBox(
                    width: i.aspect * 130,
                    child: Stack(fit: StackFit.expand, children: [
                      Opacity(opacity: keep.contains(i.id) ? 1 : 0.55, child: PhotoThumb(i, height: 130)),
                      IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(border: Border.all(color: keep.contains(i.id) ? C.select : C.trash, width: 3)),
                        ),
                      ),
                      if (keep.contains(i.id)) const Positioned(top: 5, left: 5, child: CheckBadge()),
                      if (i == g.items.first)
                        Positioned(
                          right: 5,
                          bottom: 5,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                            child: const Text('Best', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

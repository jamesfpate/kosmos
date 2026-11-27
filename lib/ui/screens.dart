import 'package:flutter/material.dart';

import '../media.dart' as media;
import '../media.dart' show Access;
import '../models.dart';
import '../state.dart';
import 'common.dart';

Widget _centered(List<Widget> children) => Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    );

Widget _steps(List<String> steps) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (i, t) in steps.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 22, child: Text('${i + 1}.', style: const TextStyle(color: C.muted))),
            Expanded(child: Text(t)),
          ]),
        ),
    ]);

class AccessScreen extends StatelessWidget {
  const AccessScreen(this.s, {super.key});

  final AppState s;

  @override
  Widget build(BuildContext context) {
    if (media.desktop) {
      return _centered([
        const Center(child: Logo(size: 34)),
        const SizedBox(height: 12),
        const Text('Choose a folder of photos and videos to sort. Winnow looks in its subfolders too. Nothing is '
            'uploaded unless you turn on an upload.'),
        const SizedBox(height: 12),
        Btn('Choose folder', bold: true, color: C.bg, bg: C.accent, onTap: () => pickFolder(s)),
      ]);
    }
    final first = s.access == Access.prompt || (s.access == Access.denied && !s.askedAccess);
    if (first) {
      return _centered([
        const Center(child: Logo(size: 34)),
        const SizedBox(height: 12),
        const Text('Winnow needs to see your photos and videos to sort them. Nothing leaves your phone unless you turn on an upload.'),
        const SizedBox(height: 12),
        _steps(['Tap Allow access below.', 'Android asks about photos and videos: choose Allow all, not Select photos.']),
        const SizedBox(height: 12),
        Btn('Allow access', bold: true, color: C.bg, bg: C.accent, onTap: s.requestAccess),
      ]);
    }
    return _centered([
      const Center(child: Logo(size: 34)),
      const SizedBox(height: 12),
      Text(
        '${s.access == Access.limited ? 'Winnow can only see the photos you picked, so it would miss new ones.' : 'Photo access is off.'} Android won\'t ask again, so change it in settings:',
      ),
      const SizedBox(height: 12),
      _steps([
        "Tap Open settings below (Winnow's app info).",
        'Tap Permissions, then Photos and videos.',
        'Choose Always allow all.',
        'Come back here. Winnow notices by itself.',
      ]),
      const SizedBox(height: 12),
      Btn('Open settings', bold: true, color: C.bg, bg: C.accent, onTap: media.openSettings),
      const SizedBox(height: 8),
      Btn('Check again', onTap: s.init),
    ]);
  }
}

class StartScreen extends StatelessWidget {
  const StartScreen(this.s, {super.key});

  final AppState s;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch;
    Widget option(String label, int from, {bool primary = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Btn('$label  ·  ${from == 0 ? s.items.length : s.countSince(from)}',
              bold: primary, color: primary ? C.bg : null, bg: primary ? C.accent : null, onTap: () => s.chooseStart(from)),
        );
    return _centered([
      const Text('Where to start?', textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      const Text("Older photos aren't touched. They wait in the grid for later.", textAlign: TextAlign.center, style: TextStyle(color: C.muted)),
      const SizedBox(height: 16),
      option('From today', now - day, primary: true),
      option('Last 30 days', now - 30 * day),
      option('Everything', 0),
    ]);
  }
}

class TrashScreen extends StatelessWidget {
  const TrashScreen(this.s, {super.key});

  final AppState s;

  @override
  Widget build(BuildContext context) {
    final list = s.pendingTrash;
    return Column(children: [
      TopBar(s, title: const Text('Trash'), subtitle: Text('${list.length} to delete')),
      const Text('Tap a photo to keep it out of the delete.', style: TextStyle(color: C.muted, fontSize: 13)),
      const SizedBox(height: 8),
      Expanded(
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 160, mainAxisSpacing: 3, crossAxisSpacing: 3),
          itemCount: list.length,
          itemBuilder: (_, i) {
            final item = list[i];
            final back = s.restore.contains(item.id);
            return GestureDetector(
              onTap: () => s.toggleRestore(item.id),
              child: Stack(fit: StackFit.expand, children: [
                Opacity(opacity: back ? 1 : 0.85, child: PhotoThumb(item)),
                if (item.isVideo) const Positioned(bottom: 6, right: 6, child: VideoBadge()),
                if (back) ...[
                  DecoratedBox(decoration: BoxDecoration(border: Border.all(color: C.keep, width: 3))),
                  const Positioned(top: 6, left: 6, child: Icon(Icons.restore, color: C.keep)),
                ],
              ]),
            );
          },
        ),
      ),
      if (s.error.isNotEmpty) Text(s.error, style: const TextStyle(color: C.trash)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Btn('Restore ${s.restore.isEmpty ? '' : s.restore.length}', icon: Icons.restore, onTap: s.restore.isEmpty ? null : s.restoreSelected)),
        const SizedBox(width: 8),
        Expanded(
          child: Btn('Delete ${list.length - s.restore.length}',
              color: C.trash, onTap: s.busy || list.length == s.restore.length ? null : s.deleteTrash),
        ),
      ]),
    ]);
  }
}

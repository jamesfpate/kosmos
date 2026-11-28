import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:winnow_native/winnow_native.dart';

import '../immich.dart';
import '../media.dart' as media;
import '../state.dart';
import '../stores.dart';
import '../support.dart';
import '../info.dart';
import 'common.dart';

const _sections = [
  ('general', 'General'),
  ('single', 'Single'),
  ('grid', 'Grid'),
  ('integrations', 'Integrations'),
  ('backup', 'Backup'),
  ('support', 'Support'),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen(this.s, {super.key});

  final AppState s;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _scroll = ScrollController();
  final _keys = {for (final (id, _) in _sections) id: GlobalKey()};
  String _current = 'general';
  DateTime _jumped = DateTime(0);
  String _backupMsg = '';

  AppState get s => widget.s;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_track);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Highlights the section being read: the last heading scrolled past the sticky bar.
  void _track() {
    // A tapped section stays highlighted while the scroll runs (short last sections can't reach the top).
    if (DateTime.now().difference(_jumped).inMilliseconds < 900) return;
    final top = (context.findRenderObject() as RenderBox?)?.localToGlobal(Offset.zero).dy ?? 0;
    var current = _sections.first.$1;
    for (final (id, _) in _sections) {
      final box = _keys[id]!.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.attached && box.localToGlobal(Offset.zero).dy <= top + 120) current = id;
    }
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 4) current = _sections.last.$1;
    if (current != _current) setState(() => _current = current);
  }

  void _jump(String id) {
    final ctx = _keys[id]!.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    setState(() {
      _current = id;
      _jumped = DateTime.now();
    });
  }

  Widget _h2(String id, String text) => Padding(
        key: _keys[id],
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Container(
          padding: const EdgeInsets.only(bottom: 4),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
          child: Text(text.toUpperCase(), style: const TextStyle(color: C.accent, fontSize: 12.5, letterSpacing: 1, fontWeight: FontWeight.w600)),
        ),
      );

  Widget _h3(String text) =>
      Padding(padding: const EdgeInsets.only(top: 14, bottom: 4), child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)));

  Widget _p(String text) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(text, style: const TextStyle(color: C.muted)));

  Future<void> _export() async {
    try {
      final text = await s.exportAll();
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Save Winnow backup',
        fileName: 'winnow-backup-$day.json',
        bytes: Uint8List.fromList(utf8.encode(text)),
        mimeType: 'application/json',
      );
      setState(() => _backupMsg = uri == null ? '' : 'Saved winnow-backup-$day.json');
    } catch (e) {
      setState(() => _backupMsg = 'Export failed: $e');
    }
  }

  Future<void> _merge() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Merge month albums?'),
        content: const Text(
            'Photos in "2026-10"-style albums move into that year\'s album, here and in each target on the next sync. Emptied month albums are deleted in Immich; Apple Photos, Google Photos, PhotoPrism and Synology keep them, empty.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Merge')),
        ],
      ),
    );
    if (ok != true) return;
    final n = await s.mergeMonths();
    if (mounted) toast(context, 'Moved $n photos into year albums');
  }

  Future<void> _import() async {
    try {
      final picked = await FilePicker.pickFile();
      if (picked == null) return;
      final text = utf8.decode(await picked.xFile.readAsBytes());
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Import backup?'),
          content: const Text("Its decisions, albums and settings are merged into what's here."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Import')),
          ],
        ),
      );
      if (ok != true) return;
      final n = await s.importAll(text);
      s.go(Screen.settings);
      setState(() => _backupMsg = 'Imported ${n.decisions} decisions and ${n.albums} albums');
    } catch (e) {
      setState(() => _backupMsg = 'Import failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = s.sync;
    return Column(children: [
      TopBar(s, title: const Text('Settings')),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final (id, label) in _sections)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(label),
                selected: _current == id,
                onSelected: (_) => _jump(id),
                selectedColor: C.accent,
                backgroundColor: C.surface,
                showCheckmark: false,
                labelStyle: TextStyle(color: _current == id ? C.bg : C.text, fontWeight: _current == id ? FontWeight.w600 : null),
                side: BorderSide(color: _current == id ? C.accent : C.line),
              ),
            ),
        ]),
      ),
      Expanded(
        // A plain column (not a lazy list) so every section exists and the jump bar can scroll to it.
        child: SingleChildScrollView(
          controller: _scroll,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _h2('general', 'General'),
          _h3('Order'),
          _p('Which photos come first, everywhere: swiping one by one, bursts and the grid.'),
          Choices(options: const [(false, 'Oldest first'), (true, 'Newest first')], value: s.newestFirst, onPick: s.setOrder),
          _h3('Catch-all album'),
          _p('Where kept photos go when they aren\'t part of an event album: one album a year ("2026") or a month ("2026-10"). In Immich a year album still tags each photo by month.'),
          Choices(options: const [(true, 'Yearly'), (false, 'Monthly')], value: s.byYear, onPick: (v) => s.setCatchAll(year: v)),
          if (s.byYear && s.monthAlbumCount > 0) ...[
            const SizedBox(height: 6),
            Btn('Merge ${s.monthAlbumCount} month album${s.monthAlbumCount == 1 ? '' : 's'} into years', onTap: _merge),
          ],
          if (media.desktop) ...[
            _h3('Keyboard'),
            _p(s.vimKeys
                ? 'Vim keys on. One photo: h delete, l keep, j later, k full size, u undo. Grid: h j k l move, x or Enter selects, u undo. Arrow keys work too.'
                : 'One photo: ← delete, → keep, ↓ later, Space play, Z undo, / search albums. Grid: arrow keys move, Enter or Space selects, Delete deletes the selection, Esc clears it.'),
            Choices(options: const [(false, 'Arrow keys'), (true, 'Arrows + Vim (h j k l)')], value: s.vimKeys, onPick: s.setVimKeys),
          ],
          _h3('Keep / delete animation'),
          _p('The outlines in the photo trace up (keep) or down (delete); deleted photos fade out. Off: decisions are instant.'),
          Choices(options: const [(true, 'On'), (false, 'Off')], value: s.animations, onPick: s.setAnimations),
          if (Platform.isMacOS) ...[
            _h3('Review'),
            _p('Folders on this Mac, or the Photos library (deletes go to Recently Deleted, albums are kept in Photos).'),
            Choices(options: const [(true, 'Folders'), (false, 'Photos library')], value: media.useFolders, onPick: (v) => s.setSource(folders: v)),
          ],
          if (media.useFolders) ...[
            _h3('Photo folders'),
            _p('Winnow reviews the photos and videos in these folders and their subfolders.'),
            for (final f in s.folders)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(f, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: 'Stop reviewing this folder',
                  icon: const Icon(Icons.close, color: C.muted),
                  onPressed: () => s.removeFolder(f),
                ),
              ),
            Btn('Add folder', icon: Icons.create_new_folder_outlined, onTap: () => pickFolder(s, context)),
          ],
          // Apple's library has no folders.
          if (!media.appleLibrary) _h3(media.useFolders ? 'Subfolders' : 'Folders'),
          if (!media.appleLibrary) _p('Unticked folders are skipped when culling and in the grid.'),
          if (!media.appleLibrary)
          for (final (bucket, count) in s.buckets)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: C.accent,
              value: !s.hidden.contains(bucket),
              onChanged: (_) => s.toggleFolder(bucket),
              title: Text(bucket.isEmpty ? '(no folder)' : bucket),
              secondary: Text('$count', style: const TextStyle(color: C.muted)),
            ),
          _h3('Start point'),
          _p('${s.cutoff == null || s.cutoff == 0 ? 'Culling everything.' : 'Culling photos from ${dayOf(s.cutoff!)}.'} Photos already reviewed stay reviewed.'),
          Btn('Change start point', onTap: s.changeStart),
          _h2('single', 'Single'),
          _h3('Review bursts together'),
          _p('Photos taken in quick succession show as one card: keep the best, remove the rest.'),
          Choices(options: const [(true, 'On'), (false, 'Off')], value: s.bursts, onPick: s.setBursts),
          if (s.bursts) ...[
            _h3('Burst gap'),
            _p('Photos taken within this time of the previous one count as the same burst.'),
            Choices(options: [for (final g in gapChoices) (g, '${g}s')], value: s.groupGap, onPick: s.setGroupGap),
            _h3('Check burst photos by default'),
            _p('On: every photo of a burst starts checked, uncheck the odd ones out. Off: start with none.'),
            Choices(options: const [(true, 'On'), (false, 'Off')], value: s.checkDefault, onPick: s.setCheckDefault),
            _h3('Unchecked photos get the opposite'),
            _p('In a burst, Keep 3 also deletes the unchecked ones and Delete 3 keeps them, so one tap finishes the burst. Off: the buttons act only on the checked photos and the rest wait for their own decision.'),
            Choices(options: const [(true, 'On'), (false, 'Off')], value: s.autoTrash, onPick: s.setAutoTrash),
          ],
          _h3('Photo info'),
          _p('What shows at the bottom of each photo. Camera, lens and exposure come from the photo itself.'),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (key, label) in infoChoices)
              FilterChip(
                label: Text(label),
                selected: infoFields.contains(key),
                onSelected: (_) => s.toggleInfo(key),
                selectedColor: C.accent,
                backgroundColor: C.surface,
                showCheckmark: false,
                labelStyle: TextStyle(color: infoFields.contains(key) ? C.bg : C.text, fontWeight: infoFields.contains(key) ? FontWeight.w600 : null),
                side: BorderSide(color: infoFields.contains(key) ? C.accent : C.line),
              ),
          ]),
          _h2('grid', 'Grid'),
          _h3('Delete the gaps'),
          _p('Filing a selection into an album also deletes the unselected photos between your first and last pick (shown with a red border). Deletes go to Trash for review first.'),
          Choices(options: const [(true, 'On'), (false, 'Off')], value: s.gridAutoTrash, onPick: s.setGridAutoTrash),
          _h2('integrations', 'Integrations'),
          _p('Upload kept photos with their albums.'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Immich'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(
                !s.immich.enabled ? 'Off' : (s.errorFor('Immich').isNotEmpty ? 'Error' : (sync.pending > 0 ? '${sync.pending} to upload' : 'Up to date')),
                style: const TextStyle(color: C.muted),
              ),
              const Icon(Icons.chevron_right, color: C.muted),
            ]),
            onTap: () => s.go(Screen.immich),
          ),
          for (final (open, name, key, on) in [
            if (Platform.isAndroid) (() => s.go(Screen.google), 'Google Photos', 'Google Photos', s.google.enabled),
            for (final d in storeDefs.where((d) => d.offered))
              (() => s.openStore(d.key), d.title, d.label, s.store(d.key).enabled),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(name),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(
                  !on ? 'Off' : (s.errorFor(key).isNotEmpty ? 'Error' : (sync.pending > 0 ? '${sync.pending} to upload' : 'Up to date')),
                  style: const TextStyle(color: C.muted),
                ),
                const Icon(Icons.chevron_right, color: C.muted),
              ]),
              onTap: open,
            ),
          _h3('Free up space'),
          _p(media.appleLibrary
              ? 'Once every backup that is on has a kept photo (checked on the server), it moves to Recently Deleted in Photos, where it can be restored for 30 days. Apple Photos albums don\'t count as a backup. Photos you restore are never removed again.'
              : media.useFolders
              ? 'Once every integration that is on has a kept photo (checked on the server), it moves to the Trash, where it can be restored. Photos you restore are never removed again.'
              : 'Once every integration that is on has a kept photo (checked on the server), it moves to the phone\'s trash, where it can be restored for 30 days. Photos you restore are never removed again.'),
          Choices(
            options: const [('off', 'Off'), ('now', 'After backup'), ('30d', 'Keep last 30 days')],
            value: s.freeUp,
            onPick: s.setFreeUp,
          ),
          if (s.freeUp != 'off' && Platform.isAndroid) ...[
            const SizedBox(height: 6),
            FutureBuilder(
              future: media.canManageMedia(),
              builder: (context, snap) => snap.data == true
                  ? const Text('Removes them without asking each time.', style: TextStyle(color: C.muted))
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Android asks to confirm each batch. To skip that, allow media management.',
                          style: TextStyle(color: C.muted)),
                      const SizedBox(height: 6),
                      Btn('Allow media management', onTap: media.openManageMedia),
                    ]),
            ),
          ],
          if (s.freedCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Removed ${s.freedCount} from the ${media.device} this session.', style: const TextStyle(color: C.muted)),
            ),
          _h2('backup', 'Backup'),
          _p('Export or import app settings and albums.'),
          Row(children: [
            Expanded(child: Btn('Export data', onTap: _export)),
            const SizedBox(width: 8),
            Expanded(child: Btn('Import data', onTap: _import)),
          ]),
          if (_backupMsg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_backupMsg, style: const TextStyle(color: C.muted))),
          _h2('support', 'Support Winnow'),
          if (s.supporter)
            _p('You\'re a supporter. Thank you ♥')
          else
            _p('Everything in Winnow is free, with no ads and no tracking. If it saves you time, a one-off supporter purchase keeps it going.'),
          if (!s.supporter && Support.inApp && s.support.product != null) ...[
            Btn('Become a supporter · ${s.support.product!.price}', bold: true, color: C.bg, bg: C.accent, onTap: s.support.buy),
            const SizedBox(height: 8),
          ],
          Btn('Sponsor on GitHub', icon: Icons.favorite_border, onTap: () => WinnowNative.openUrl(Support.sponsorsUrl)),
          // Room to scroll the last section's heading up under the jump bar.
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.5),
          ]),
        ),
      ),
    ]);
  }
}

class ImmichScreen extends StatefulWidget {
  const ImmichScreen(this.s, {super.key});

  final AppState s;

  @override
  State<ImmichScreen> createState() => _ImmichScreenState();
}

class _ImmichScreenState extends State<ImmichScreen> {
  late final _server = TextEditingController(text: widget.s.immich.server);
  late final _key = TextEditingController(text: widget.s.immich.key);
  String _msg = '';

  AppState get s => widget.s;

  Future<void> _test() async {
    await s.saveImmich(server: _server.text, key: _key.text);
    setState(() => _msg = 'Checking…');
    try {
      final r = await ImmichApi(s.immich).test();
      setState(() => _msg = r.missing.isEmpty ? 'Connected · key "${r.name}" has what it needs' : 'Key "${r.name}" is missing: ${r.missing.join(', ')}');
    } catch (e) {
      setState(() => _msg = "Can't connect: $e");
    }
  }

  Future<void> _choose() async {
    await s.saveImmich(server: _server.text, key: _key.text);
    try {
      final users = await ImmichApi(s.immich).users();
      if (!mounted) return;
      final picked = {...s.immich.shareWith};
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => StatefulBuilder(
          builder: (c, set) => AlertDialog(
            title: const Text('Share albums with'),
            content: users.isEmpty
                ? const Text('No other Immich users on this server yet. They appear after logging in once (Pocket ID).')
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final u in users)
                      CheckboxListTile(
                        value: picked.containsKey(u.id),
                        title: Text(u.name),
                        subtitle: Text(u.email),
                        onChanged: (v) => set(() => v == true ? picked[u.id] = u.name : picked.remove(u.id)),
                      ),
                  ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
            ],
          ),
        ),
      );
      if (ok != true) return;
      await s.saveImmich(shareWith: picked);
      if (picked.isNotEmpty) await _shareAll();
    } catch (e) {
      setState(() => _msg = "Can't load users: $e");
    }
  }

  Future<void> _import() async {
    setState(() => _msg = 'Importing albums…');
    try {
      final (added, linked) = await s.importImmichAlbums();
      setState(() => _msg = added + linked == 0
          ? 'No new albums in Immich'
          : 'Added $added album${added == 1 ? '' : 's'}${linked > 0 ? ', linked $linked already in Winnow' : ''}');
    } catch (e) {
      setState(() => _msg = 'Import failed: $e');
    }
  }

  Future<void> _shareAll() async {
    setState(() => _msg = 'Sharing…');
    try {
      final n = await s.shareAllAlbums();
      setState(() => _msg = 'Shared $n album${n == 1 ? '' : 's'} with ${s.immich.shareWith.values.join(', ')}');
    } catch (e) {
      setState(() => _msg = 'Sharing failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = s.sync;
    final ready = s.immich.ready;
    return Column(children: [
      TopBar(s, title: const Text('Immich'), subtitle: Text(s.immich.enabled ? 'Uploading kept photos' : 'Off')),
      Expanded(
        child: ListView(children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: () => s.go(Screen.settings), icon: const Icon(Icons.chevron_left), label: const Text('Settings')),
          ),
          const Text(
            "Kept photos go to your Immich server with their original files and dates, into an album of the same name, tagged Albums/YYYY/MM/name. Deleted photos are never uploaded. Leave backup in Immich's own mobile app off, so photos don't arrive twice.",
            style: TextStyle(color: C.muted),
          ),
          const SizedBox(height: 16),
          const Text('Server', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          TextField(
            controller: _server,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(hintText: 'https://photos.example.com', border: OutlineInputBorder(), isDense: true),
            onSubmitted: (v) => s.saveImmich(server: v),
          ),
          const SizedBox(height: 16),
          const Text('API key', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('In Immich: Account settings → API keys → New. Permissions: ${immichPermissions.join(', ')}. To browse Immich in Explorer, also ${immichBrowsePermissions.join(', ')}.', style: const TextStyle(color: C.muted)),
          const SizedBox(height: 6),
          TextField(
            controller: _key,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(hintText: 'Paste the key', border: OutlineInputBorder(), isDense: true),
            onSubmitted: (v) => s.saveImmich(key: v),
          ),
          const SizedBox(height: 8),
          Btn('Test connection', onTap: _test),
          if (_msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_msg, style: const TextStyle(color: C.muted))),
          const SizedBox(height: 16),
          const Text('Upload', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Choices(
            options: const [(true, 'On'), (false, 'Off')],
            value: s.immich.enabled,
            onPick: (on) async {
              await s.saveImmich(server: _server.text, key: _key.text);
              if (on && !s.immich.ready) return setState(() => _msg = 'Add the server and key first.');
              await s.saveImmich(enabled: on);
            },
          ),
          const SizedBox(height: 12),
          if (!media.desktop) ...[
          const Text('Upload on', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Choices(
            options: const [(false, 'Any network'), (true, 'Wi-Fi only')],
            value: s.immich.wifiOnly,
            onPick: (v) => s.saveImmich(wifiOnly: v),
          ),
          const SizedBox(height: 12),
          ],
          if (media.backgroundUploads) ...[
          const Text('Upload in the background', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Keeps uploading when Winnow is closed, about every 15 minutes.', style: TextStyle(color: C.muted)),
          const SizedBox(height: 6),
          Choices(
            options: const [('off', 'Off'), ('charging', 'While charging'), ('always', 'Always')],
            value: s.immich.background,
            onPick: (v) => s.saveImmich(background: v),
          ),
          const SizedBox(height: 12),
          ],
          const Text('Videos', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Choices(
            options: [(true, 'Upload'), (false, media.desktop ? 'Computer only' : 'Phone only')],
            value: s.immich.videos,
            onPick: (v) => s.saveImmich(videos: v),
          ),
          const SizedBox(height: 16),
          const Text('Share albums with', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Every album Winnow makes in Immich is shared with these people as editors, so they see it and can add their own photos. Needs the key permissions ${immichSharePermissions.join(', ')}.',
            style: const TextStyle(color: C.muted),
          ),
          const SizedBox(height: 6),
          Text(s.immich.shareWith.isEmpty ? 'Nobody yet' : s.immich.shareWith.values.join(', ')),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Btn('Choose people', onTap: ready ? _choose : null)),
            const SizedBox(width: 8),
            Expanded(child: Btn('Share existing albums now', onTap: ready && s.immich.shareWith.isNotEmpty ? _shareAll : null)),
          ]),
          Label('Albums'),
          const Text(
            "Bring in albums you already have in Immich so you can file into them. Names like \"2024-12 Christmas\" become dated albums. Renames you make in Immich come back to Winnow after each sync.",
            style: TextStyle(color: C.muted),
          ),
          const SizedBox(height: 6),
          Btn('Import albums from Immich', onTap: ready ? _import : null),
          if (s.immich.enabled) ...[
            const SizedBox(height: 8),
            Text(
              '${sync.running ? 'Uploading… ${sync.pending} to go' : sync.waitingWifi ? '${sync.pending} waiting for Wi-Fi' : (sync.pending > 0 ? '${sync.pending} waiting' : 'Everything kept is in Immich.')}${sync.done > 0 ? ' · ${sync.done} done this session' : ''}',
              style: const TextStyle(color: C.muted),
            ),
            if (s.errorFor('Immich').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(s.errorFor('Immich'), style: const TextStyle(color: C.trash))),
            const SizedBox(height: 8),
            Btn('Upload now', onTap: sync.running || !ready ? null : s.runSync),
          ],
        ]),
      ),
    ]);
  }
}

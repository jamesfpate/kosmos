import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../immich.dart';
import '../state.dart';
import 'common.dart';

const _sections = [
  ('general', 'General'),
  ('single', 'Single photo'),
  ('grid', 'Grid'),
  ('integrations', 'Integrations'),
  ('backup', 'Backup'),
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
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
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
        child: ListView(controller: _scroll, children: [
          _h2('general', 'General'),
          _h3('Order'),
          _p('Which photos come first, everywhere: swiping one by one, bursts and the grid.'),
          Choices(options: const [(false, 'Oldest first'), (true, 'Newest first')], value: s.newestFirst, onPick: s.setOrder),
          _h3('Folders'),
          _p('Unticked folders are skipped when culling and in the grid.'),
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
          _p('${s.cutoff == null ? 'Culling everything.' : 'Culling photos from ${dayOf(s.cutoff!)}.'} Photos already reviewed stay reviewed.'),
          Btn('Change start point', onTap: s.changeStart),
          _h2('single', 'Single photo'),
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
                !s.immich.enabled ? 'Off' : (sync.error.isNotEmpty ? 'Error' : (sync.pending > 0 ? '${sync.pending} to upload' : 'Up to date')),
                style: const TextStyle(color: C.muted),
              ),
              const Icon(Icons.chevron_right, color: C.muted),
            ]),
            onTap: () => s.go(Screen.immich),
          ),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            enabled: false,
            title: Text('Google Photos'),
            trailing: Text('Coming later', style: TextStyle(color: C.muted)),
          ),
          _h2('backup', 'Backup'),
          _p('Export or import your app settings, albums and photo decisions. They live only on this phone: export saves them to a file, import brings them back after a reinstall or on a new install. Backups from the earlier Winnow work too.'),
          Row(children: [
            Expanded(child: Btn('Export data', onTap: _export)),
            const SizedBox(width: 8),
            Expanded(child: Btn('Import data', onTap: _import)),
          ]),
          if (_backupMsg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_backupMsg, style: const TextStyle(color: C.muted))),
          const SizedBox(height: 40),
        ]),
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
          Text('In Immich: Account settings → API keys → New. Permissions: ${immichPermissions.join(', ')}.', style: const TextStyle(color: C.muted)),
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
          if (s.immich.enabled) ...[
            const SizedBox(height: 8),
            Text(
              '${sync.running ? 'Uploading… ${sync.pending} to go' : (sync.pending > 0 ? '${sync.pending} waiting' : 'Everything kept is in Immich.')}${sync.done > 0 ? ' · ${sync.done} done this session' : ''}',
              style: const TextStyle(color: C.muted),
            ),
            if (sync.error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(sync.error, style: const TextStyle(color: C.trash))),
            const SizedBox(height: 8),
            Btn('Upload now', onTap: sync.running || !ready ? null : s.runSync),
          ],
        ]),
      ),
    ]);
  }
}

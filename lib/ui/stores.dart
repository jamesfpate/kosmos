import 'package:flutter/material.dart';
import 'package:winnow_native/winnow_native.dart';

import '../gphotos.dart';
import '../state.dart';
import '../store.dart';
import '../stores.dart';
import 'common.dart';

// Settings pages for the file stores (Nextcloud / WebDAV, SFTP, S3, B2) and Google Photos.

/// Page frame: top bar, back to Settings, then [children].
Widget _page(AppState s, String title, bool on, String doing, List<Widget> children) => Column(children: [
      TopBar(s, title: Text(title), subtitle: Text(on ? doing : 'Off')),
      Expanded(
        child: ListView(children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => s.go(Screen.settings), icon: const Icon(Icons.chevron_left), label: const Text('Settings')),
          ),
          ...children,
          const SizedBox(height: 24),
        ]),
      ),
    ]);

Widget _muted(String text) =>
    Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(text, style: const TextStyle(color: C.muted)));

Widget _field(String label, TextEditingController c, String hint, VoidCallback save,
        {bool secret = false, TextInputType? type, int lines = 1}) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 14),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      TextField(
        controller: c,
        obscureText: secret,
        autocorrect: false,
        keyboardType: type,
        minLines: lines,
        maxLines: lines,
        decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder(), isDense: true),
        onSubmitted: (_) => save(),
      ),
    ]);

Widget _choice<T>(String label, String? help, List<(T, String)> options, T value, ValueChanged<T> pick) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 14),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      if (help != null) ...[const SizedBox(height: 4), Text(help, style: const TextStyle(color: C.muted))],
      const SizedBox(height: 6),
      Choices(options: options, value: value, onPick: pick),
    ]);

/// The options every integration has: upload on/off, network, background, videos, and its status.
List<Widget> _options(
  AppState s,
  String name, {
  required bool enabled,
  required bool wifiOnly,
  required String background,
  required bool videos,
  required Future<void> Function(bool) setEnabled,
  required ValueChanged<bool> setWifi,
  required ValueChanged<String> setBackground,
  required ValueChanged<bool> setVideos,
}) {
  final sync = s.sync;
  final error = s.errorFor(name);
  return [
    _choice('Upload', null, const [(true, 'On'), (false, 'Off')], enabled, setEnabled),
    _choice('Upload on', null, const [(false, 'Any network'), (true, 'Wi-Fi only')], wifiOnly, setWifi),
    _choice('Upload in the background', 'Keeps uploading when Winnow is closed, about every 15 minutes.',
        const [('off', 'Off'), ('charging', 'While charging'), ('always', 'Always')], background, setBackground),
    _choice('Videos', null, const [(true, 'Upload'), (false, 'Phone only')], videos, setVideos),
    if (enabled) ...[
      const SizedBox(height: 12),
      Text(
        sync.running
            ? 'Uploading… ${sync.pending} to go'
            : sync.waitingWifi
                ? '${sync.pending} waiting for Wi-Fi'
                : (sync.pending > 0 ? '${sync.pending} waiting' : 'Everything kept is backed up.'),
        style: const TextStyle(color: C.muted),
      ),
      if (error.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(error, style: const TextStyle(color: C.trash))),
      const SizedBox(height: 8),
      Btn('Upload now', onTap: sync.running ? null : s.runSync),
    ],
  ];
}

/// A file store's page: its fields, folder, Test connection, and the common options.
class StoreScreen extends StatefulWidget {
  const StoreScreen(this.s, {super.key});

  final AppState s;

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  AppState get s => widget.s;
  StoreDef get def => storeDef(s.storeKey);
  late final _c = {for (final f in def.fields) f.key: TextEditingController(text: s.store(def.key)[f.key])};
  late final _folder = TextEditingController(text: s.store(def.key).folder);
  String _msg = '';

  Future<void> _save() =>
      s.saveStore(def.key, fields: {for (final e in _c.entries) e.key: e.value.text}, folder: _folder.text);

  Future<void> _test() async {
    await _save();
    setState(() => _msg = 'Checking…');
    final api = def.make(s.store(def.key), (k, v) => s.saveStore(def.key, fields: {k: v}));
    try {
      final where = await api.authorize();
      setState(() => _msg = 'Connected · $where');
    } catch (e) {
      setState(() => _msg = "Can't connect: ${'$e'.replaceFirst('Exception: ', '')}");
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = s.store(def.key);
    return _page(s, def.title, c.enabled, 'Backing up kept photos', [
      for (final t in def.intro) _muted(t),
      _muted('Layout: ${c.folder}2026/2026-11 Thanksgiving/IMG_1234.jpg; undated albums under ${c.folder}Albums/.'),
      for (final f in def.fields)
        _field(f.label, _c[f.key]!, f.hint, _save,
            secret: f.secret, type: f.url ? TextInputType.url : (f.lines > 1 ? TextInputType.multiline : null), lines: f.lines),
      _field(def.folderLabel, _folder, 'Photos/', _save),
      if (c['hostKey'].isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Expanded(child: _muted('Server identity: ${c['hostKey']}')),
            TextButton(onPressed: () => s.saveStore(def.key, fields: {'hostKey': ''}), child: const Text('Forget')),
          ]),
        ),
      const SizedBox(height: 8),
      Btn('Test connection', onTap: _test),
      if (_msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: _muted(_msg)),
      ..._options(
        s,
        def.label,
        enabled: c.enabled,
        wifiOnly: c.wifiOnly,
        background: c.background,
        videos: c.videos,
        setEnabled: (on) async {
          await _save();
          if (on && !def.ready(s.store(def.key))) {
            return setState(() => _msg = 'Fill in ${def.fields.where((f) => !f.optional).map((f) => f.label.toLowerCase()).join(', ')} first.');
          }
          await s.saveStore(def.key, enabled: on);
        },
        setWifi: (v) => s.saveStore(def.key, wifiOnly: v),
        setBackground: (v) => s.saveStore(def.key, background: v),
        setVideos: (v) => s.saveStore(def.key, videos: v),
      ),
    ]);
  }
}

class GoogleScreen extends StatefulWidget {
  const GoogleScreen(this.s, {super.key});

  final AppState s;

  @override
  State<GoogleScreen> createState() => _GoogleScreenState();
}

class _GoogleScreenState extends State<GoogleScreen> {
  String _msg = '';

  AppState get s => widget.s;

  Future<void> _signIn() async {
    setState(() => _msg = 'Signing in…');
    try {
      final email = await googleSignIn();
      await s.saveGoogle(email: email);
      setState(() => _msg = '');
    } catch (e) {
      setState(() => _msg = "Couldn't sign in: ${'$e'.replaceFirst('Exception: ', '')}");
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = s.google;
    return _page(s, 'Google Photos', c.enabled, 'Backing up kept photos', [
      if (c.enabled && !c.backupOffSeen)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: C.trash), borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Turn off backup in the Google Photos app',
                style: TextStyle(fontWeight: FontWeight.w700, color: C.trash)),
            const SizedBox(height: 4),
            const Text(
              'Otherwise every photo on the phone, culled or not, also uploads from there. In Google Photos: tap your '
              'profile picture → Photos settings → Backup → off.',
              style: TextStyle(color: C.muted),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Btn('Open Google Photos', onTap: () => WinnowNative.openApp('com.google.android.apps.photos'))),
              const SizedBox(width: 8),
              Expanded(child: Btn("It's off", onTap: () => s.saveGoogle(backupOffSeen: true))),
            ]),
          ]),
        ),
      _muted('Kept photos upload in original quality into albums Winnow makes in Google Photos, named like Winnow\'s. '
          'Moving a photo or renaming an album updates them. Uploads count against your Google storage.'),
      _muted('Google only lets Winnow see and change what it uploaded itself: it can\'t add to albums you made in Google '
          'Photos, and nothing can be deleted from Google through Winnow.'),
      const SizedBox(height: 6),
      if (c.ready) ...[
        Row(children: [
          Expanded(child: Text('Signed in as ${c.email}', style: const TextStyle(fontWeight: FontWeight.w600))),
          TextButton(onPressed: () => s.saveGoogle(email: '', enabled: false), child: const Text('Sign out')),
        ]),
      ] else
        Btn('Sign in with Google', icon: Icons.login, onTap: _signIn),
      if (_msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: _muted(_msg)),
      ..._options(
        s,
        'Google Photos',
        enabled: c.enabled,
        wifiOnly: c.wifiOnly,
        background: c.background,
        videos: c.videos,
        setEnabled: (on) async {
          if (on && !s.google.ready) return setState(() => _msg = 'Sign in first.');
          await s.saveGoogle(enabled: on, backupOffSeen: on ? false : null);
        },
        setWifi: (v) => s.saveGoogle(wifiOnly: v),
        setBackground: (v) => s.saveGoogle(background: v),
        setVideos: (v) => s.saveGoogle(videos: v),
      ),
    ]);
  }
}

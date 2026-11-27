import 'package:flutter/material.dart';
import 'package:winnow_native/winnow_native.dart';

import '../b2.dart';
import '../gphotos.dart';
import '../state.dart';
import '../webdav.dart';
import 'common.dart';

// Settings pages for Backblaze B2, ownCloud / Nextcloud (WebDAV) and Google Photos.

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
        {bool secret = false, TextInputType? type}) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 14),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      TextField(
        controller: c,
        obscureText: secret,
        autocorrect: false,
        keyboardType: type,
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

class B2Screen extends StatefulWidget {
  const B2Screen(this.s, {super.key});

  final AppState s;

  @override
  State<B2Screen> createState() => _B2ScreenState();
}

class _B2ScreenState extends State<B2Screen> {
  late final _keyId = TextEditingController(text: widget.s.b2.keyId);
  late final _appKey = TextEditingController(text: widget.s.b2.appKey);
  late final _bucket = TextEditingController(text: widget.s.b2.bucket);
  late final _prefix = TextEditingController(text: widget.s.b2.prefix);
  String _msg = '';

  AppState get s => widget.s;

  Future<void> _save() => s.saveB2(keyId: _keyId.text, appKey: _appKey.text, bucket: _bucket.text, prefix: _prefix.text);

  Future<void> _test() async {
    await _save();
    setState(() => _msg = 'Checking…');
    final api = B2Api(s.b2);
    try {
      final bucket = await api.authorize();
      setState(() => _msg = 'Connected · bucket "$bucket" is ready');
    } catch (e) {
      setState(() => _msg = "Can't connect: $e");
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = s.b2;
    return _page(s, 'Backblaze B2', c.enabled, 'Backing up kept photos', [
      _muted('Kept photos are copied, original files, into your own B2 bucket by album: Photos/2026/2026-11 '
          'Thanksgiving/, undated albums under Photos/Albums/. Moving a photo or renaming an album moves its files. '
          'Deleted photos are never uploaded.'),
      _muted('In Backblaze: Application Keys → Add a New Application Key, allow access to the bucket, Read and Write. '
          'Set the bucket to keep only the last version so moved files don\'t take up space.'),
      _field('Key ID', _keyId, 'keyID', _save),
      _field('Application key', _appKey, 'applicationKey', _save, secret: true),
      _field('Bucket', _bucket, 'my-photos', _save),
      _field('Folder in the bucket', _prefix, 'Photos/', _save),
      const SizedBox(height: 8),
      Btn('Test connection', onTap: _test),
      if (_msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: _muted(_msg)),
      ..._options(
        s,
        'B2',
        enabled: c.enabled,
        wifiOnly: c.wifiOnly,
        background: c.background,
        videos: c.videos,
        setEnabled: (on) async {
          await _save();
          if (on && !s.b2.ready) return setState(() => _msg = 'Add the key and bucket first.');
          await s.saveB2(enabled: on);
        },
        setWifi: (v) => s.saveB2(wifiOnly: v),
        setBackground: (v) => s.saveB2(background: v),
        setVideos: (v) => s.saveB2(videos: v),
      ),
    ]);
  }
}

class WebDavScreen extends StatefulWidget {
  const WebDavScreen(this.s, {super.key});

  final AppState s;

  @override
  State<WebDavScreen> createState() => _WebDavScreenState();
}

class _WebDavScreenState extends State<WebDavScreen> {
  late final _url = TextEditingController(text: widget.s.webdav.url);
  late final _user = TextEditingController(text: widget.s.webdav.user);
  late final _password = TextEditingController(text: widget.s.webdav.password);
  late final _folder = TextEditingController(text: widget.s.webdav.folder);
  String _msg = '';

  AppState get s => widget.s;

  Future<void> _save() =>
      s.saveWebDav(url: _url.text, user: _user.text, password: _password.text, folder: _folder.text);

  Future<void> _test() async {
    await _save();
    setState(() => _msg = 'Checking…');
    final api = WebDavApi(s.webdav);
    try {
      final root = await api.authorize();
      setState(() => _msg = 'Connected · $root');
    } catch (e) {
      setState(() => _msg = "Can't connect: ${'$e'.replaceFirst('Exception: ', '')}");
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = s.webdav;
    return _page(s, 'WebDAV', c.enabled, 'Backing up kept photos', [
      _muted('Kept photos are copied, original files, into a folder on your server by album: Photos/2026/2026-11 '
          'Thanksgiving/, undated albums under Photos/Albums/. Moving a photo or renaming an album moves its files. '
          'Works with any WebDAV server.'),
      _muted('Use an app password, not your login: Nextcloud → Settings → Security → Devices & sessions; ownCloud → '
          'Settings → Security → App passwords.'),
      _field('Server', _url, 'https://cloud.example.com', _save, type: TextInputType.url),
      _field('User name', _user, 'you', _save),
      _field('App password', _password, 'xxxxx-xxxxx-xxxxx', _save, secret: true),
      _field('Folder', _folder, 'Photos/', _save),
      const SizedBox(height: 8),
      Btn('Test connection', onTap: _test),
      if (_msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: _muted(_msg)),
      ..._options(
        s,
        'WebDAV',
        enabled: c.enabled,
        wifiOnly: c.wifiOnly,
        background: c.background,
        videos: c.videos,
        setEnabled: (on) async {
          await _save();
          if (on && !s.webdav.ready) return setState(() => _msg = 'Add the server, user name and app password first.');
          await s.saveWebDav(enabled: on);
        },
        setWifi: (v) => s.saveWebDav(wifiOnly: v),
        setBackground: (v) => s.saveWebDav(background: v),
        setVideos: (v) => s.saveWebDav(videos: v),
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

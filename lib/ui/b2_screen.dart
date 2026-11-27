import 'package:flutter/material.dart';

import '../b2.dart';
import '../state.dart';
import 'common.dart';

/// Settings > Backblaze B2: key, bucket, folder, on/off, network, videos, background.
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

  Future<void> _save() =>
      s.saveB2(keyId: _keyId.text, appKey: _appKey.text, bucket: _bucket.text, prefix: _prefix.text);

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

  Widget _field(String label, TextEditingController c, String hint, {bool secret = false}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 14),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          obscureText: secret,
          autocorrect: false,
          decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder(), isDense: true),
          onSubmitted: (_) => _save(),
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

  @override
  Widget build(BuildContext context) {
    final c = s.b2;
    final sync = s.sync;
    return Column(children: [
      TopBar(s, title: const Text('Backblaze B2'), subtitle: Text(c.enabled ? 'Backing up kept photos' : 'Off')),
      Expanded(
        child: ListView(children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => s.go(Screen.settings), icon: const Icon(Icons.chevron_left), label: const Text('Settings')),
          ),
          const Text(
            'Kept photos are copied, original files, into your own B2 bucket by album: Photos/2026/2026-11 Thanksgiving/, '
            'undated albums under Photos/Albums/. Moving a photo or renaming an album moves its files. Deleted photos are '
            'never uploaded.',
            style: TextStyle(color: C.muted),
          ),
          const SizedBox(height: 8),
          const Text(
            'In Backblaze: Application Keys → Add a New Application Key, allow access to the bucket, Read and Write.',
            style: TextStyle(color: C.muted),
          ),
          _field('Key ID', _keyId, 'keyID'),
          _field('Application key', _appKey, 'applicationKey', secret: true),
          _field('Bucket', _bucket, 'my-photos'),
          _field('Folder in the bucket', _prefix, 'Photos/'),
          const SizedBox(height: 8),
          Btn('Test connection', onTap: _test),
          if (_msg.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_msg, style: const TextStyle(color: C.muted))),
          _choice('Upload', null, const [(true, 'On'), (false, 'Off')], c.enabled, (on) async {
            await _save();
            if (on && !s.b2.ready) return setState(() => _msg = 'Add the key and bucket first.');
            await s.saveB2(enabled: on);
          }),
          _choice('Upload on', null, const [(false, 'Any network'), (true, 'Wi-Fi only')], c.wifiOnly,
              (v) => s.saveB2(wifiOnly: v)),
          _choice('Upload in the background', 'Keeps uploading when Winnow is closed, about every 15 minutes.',
              const [('off', 'Off'), ('charging', 'While charging'), ('always', 'Always')], c.background,
              (v) => s.saveB2(background: v)),
          _choice('Videos', null, const [(true, 'Upload'), (false, 'Phone only')], c.videos, (v) => s.saveB2(videos: v)),
          if (c.enabled) ...[
            const SizedBox(height: 12),
            Text(
              sync.running
                  ? 'Uploading… ${sync.pending} to go'
                  : sync.waitingWifi
                      ? '${sync.pending} waiting for Wi-Fi'
                      : (sync.pending > 0 ? '${sync.pending} waiting' : 'Everything kept is backed up.'),
              style: const TextStyle(color: C.muted),
            ),
            if (sync.error.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 6), child: Text(sync.error, style: const TextStyle(color: C.trash))),
            const SizedBox(height: 8),
            Btn('Upload now', onTap: sync.running ? null : s.runSync),
          ],
          const SizedBox(height: 24),
        ]),
      ),
    ]);
  }
}

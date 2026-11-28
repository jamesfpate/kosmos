import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'version.dart';

/// A newer release: its version, the download for this computer (and its SHA-256 when the website lists it), and its
/// release page.
typedef Update = ({String version, String url, String? sha256, String page});

/// The platform's key in the website's latest.json, and the end of its release asset's name.
String get _platform => Platform.isMacOS ? 'mac' : Platform.isWindows ? 'windows' : 'linux';
String get _suffix => Platform.isMacOS ? '-mac.zip' : Platform.isWindows ? '-windows.zip' : '-linux.tar.gz';

/// Desktop: is there a newer release than this build? (Phones update through Obtainium or the store.) Asks the website
/// first (winnow.jamespate.net/latest.json, rebuilt after each release), then GitHub. Null when there isn't, on a
/// development build, or when neither can be reached.
Future<Update?> checkForUpdate() async {
  if (version.contains('dev')) return null;
  return await _fromSite() ?? await _fromGitHub();
}

Future<Update?> _fromSite() async {
  try {
    final res = await http.get(Uri.https('winnow.jamespate.net', '/latest.json')).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = '${j['version'] ?? ''}';
    if (!isNewer(latest, version)) return null;
    final d = (j['downloads'] as Map?)?[_platform] as Map?;
    if (d == null) return null;
    return (version: latest, url: '${d['url']}', sha256: d['sha256'] as String?, page: '${j['page'] ?? d['url']}');
  } catch (_) {
    return null;
  }
}

Future<Update?> _fromGitHub() async {
  try {
    final res = await http
        .get(Uri.https('api.github.com', '/repos/jamesfpate/winnow/releases/latest'), headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = (j['tag_name'] as String? ?? '').replaceFirst('v', '');
    if (!isNewer(latest, version)) return null;
    final asset = ((j['assets'] as List?) ?? []).cast<Map>().where((a) => '${a['name']}'.endsWith(_suffix)).firstOrNull;
    final page = '${j['html_url']}';
    return (version: latest, url: '${asset?['browser_download_url'] ?? page}', sha256: null, page: page);
  } catch (_) {
    return null;
  }
}

/// Whether version [a] (x.y.z) is later than [b].
bool isNewer(String a, String b) {
  List<int> parts(String v) => [for (final p in v.split('-').first.split('.')) int.tryParse(p) ?? 0];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p > q;
  }
  return false;
}

/// Where this copy is installed: the Mac's Winnow.app, or the folder holding the Windows / Linux executable.
Directory get _installed {
  final exe = File(Platform.resolvedExecutable);
  // Winnow.app/Contents/MacOS/winnow
  return Platform.isMacOS ? exe.parent.parent.parent : exe.parent;
}

/// Whether this copy can replace itself: a release build (a Mac app bundle), in a folder this user can write to (not
/// a read-only disk image or a system folder). Otherwise the update opens in the browser instead.
Future<bool> canInstall(Update u) async {
  if (!u.url.endsWith(_suffix)) return false;
  if (Platform.isMacOS && !_installed.path.endsWith('.app')) return false;
  try {
    final probe = File('${(Platform.isMacOS ? _installed.parent : _installed).path}${Platform.pathSeparator}.winnow-update-check');
    await probe.writeAsString('');
    await probe.delete();
    return true;
  } catch (_) {
    return false;
  }
}

/// Downloads [u], checks its SHA-256, unpacks it, and starts a small script that waits for Winnow to quit, puts the
/// new version in place of this one and opens it. [progress] gets 0..1 while downloading. The caller quits the app
/// once this returns.
Future<void> installUpdate(Update u, void Function(double) progress) async {
  final sep = Platform.pathSeparator;
  final tmp = await Directory.systemTemp.createTemp('winnow-update-');
  final archive = File('${tmp.path}$sep${Uri.parse(u.url).pathSegments.last}');
  final client = http.Client();
  try {
    final res = await client.send(http.Request('GET', Uri.parse(u.url)));
    if (res.statusCode != 200) throw Exception('download failed (${res.statusCode})');
    final total = res.contentLength ?? 0;
    var got = 0;
    final out = archive.openWrite();
    await for (final chunk in res.stream) {
      out.add(chunk);
      got += chunk.length;
      if (total > 0) progress(got / total);
    }
    await out.close();
  } finally {
    client.close();
  }
  if (u.sha256 != null && '${await sha256.bind(archive.openRead()).first}' != u.sha256!.toLowerCase()) {
    throw Exception('the download is damaged (checksum mismatch); try again');
  }

  final fresh = Directory('${tmp.path}${sep}new')..createSync();
  final unpack = Platform.isMacOS
      ? await Process.run('ditto', ['-x', '-k', archive.path, fresh.path])
      // Windows 10 and later ship bsdtar, which reads zips too.
      : await Process.run('tar', [Platform.isWindows ? '-xf' : '-xzf', archive.path, '-C', fresh.path]);
  if (unpack.exitCode != 0) throw Exception('could not unpack the update: ${unpack.stderr}');
  if (Platform.isMacOS && !Directory('${fresh.path}/Winnow.app').existsSync()) throw Exception('the update has no Winnow.app');

  final target = _installed.path;
  final me = pid;
  if (Platform.isWindows) {
    final script = File('${tmp.path}${sep}update.cmd');
    // Started without a console, so the wait is paced with ping rather than timeout.
    await script.writeAsString([
      '@echo off',
      ':wait',
      'tasklist /FI "PID eq $me" 2>NUL | find "$me" >NUL && (ping -n 2 127.0.0.1 >NUL & goto wait)',
      'robocopy "${fresh.path}" "$target" /E /R:3 /W:1 >NUL',
      'start "" "${Platform.resolvedExecutable}"',
      'rmdir /S /Q "${tmp.path}"',
    ].join('\r\n'));
    await Process.start('cmd', ['/c', script.path], mode: ProcessStartMode.detached);
    return;
  }
  final q = _sh;
  final script = File('${tmp.path}/update.sh');
  await script.writeAsString([
    '#!/bin/sh',
    'while kill -0 $me 2>/dev/null; do sleep 0.3; done',
    if (Platform.isMacOS) ...[
      // Swap the app bundles; the old one goes back if the new one can't go in.
      'old=${q('$target.old')}',
      'rm -rf "\$old"',
      'if mv ${q(target)} "\$old" && mv ${q('${fresh.path}/Winnow.app')} ${q(target)}; then rm -rf "\$old"; '
          'elif [ -d "\$old" ] && [ ! -d ${q(target)} ]; then mv "\$old" ${q(target)}; fi',
      'open ${q(target)}',
    ] else ...[
      'cp -a ${q('${fresh.path}/.')} ${q('$target/')}',
      'nohup ${q(Platform.resolvedExecutable)} >/dev/null 2>&1 &',
    ],
    'rm -rf ${q(tmp.path)}',
  ].join('\n'));
  await Process.start('/bin/sh', [script.path], mode: ProcessStartMode.detached);
}

/// Single-quoted for sh.
String _sh(String s) => "'${s.replaceAll("'", "'\\''")}'";

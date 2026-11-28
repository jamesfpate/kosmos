import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'version.dart';

/// A newer release on GitHub: its version and the download for this computer.
typedef Update = ({String version, String url});

/// Desktop: is there a newer release than this build? (Phones update through Obtainium or the store.) Null when
/// there isn't, on a development build, or when GitHub can't be reached.
Future<Update?> checkForUpdate() async {
  if (version.contains('dev')) return null;
  try {
    final res = await http
        .get(Uri.https('api.github.com', '/repos/jamesfpate/winnow/releases/latest'), headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = (j['tag_name'] as String? ?? '').replaceFirst('v', '');
    if (!_newer(latest, version)) return null;
    final suffix = Platform.isMacOS ? '-mac.zip' : Platform.isWindows ? '-windows.zip' : '-linux.tar.gz';
    final asset = ((j['assets'] as List?) ?? []).cast<Map>().where((a) => '${a['name']}'.endsWith(suffix)).firstOrNull;
    return (version: latest, url: '${asset?['browser_download_url'] ?? j['html_url']}');
  } catch (_) {
    return null;
  }
}

/// Whether version [a] (x.y.z) is later than [b].
bool _newer(String a, String b) {
  List<int> parts(String v) => [for (final p in v.split('-').first.split('.')) int.tryParse(p) ?? 0];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p > q;
  }
  return false;
}

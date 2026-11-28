import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import 'media.dart' as media;
import 'models.dart';

// Duplicates, two ways:
// - exact copies: the same file saved twice (a re-download, a copy between folders). Matched by size and a hash of the
//   file's first and last 64 KB, which tells different photos apart without reading whole files.
// - similar shots: the same moment shot again, or edited and saved again. Each photo gets a 64-bit "difference hash"
//   of its thumbnail (9x8 greys, each bit: is this pixel brighter than the next), which hardly changes with resizing,
//   compression or small edits. Photos taken within ten minutes whose hashes differ in at most a few bits are similar.

/// A photo's fingerprints. [near] is null for videos (only exact copies of those count).
class Prints {
  const Prints(this.exact, this.near, this.bytes);
  final String exact;
  final int? near;
  final int bytes;

  /// Bumped when the fingerprint changes, so older cached ones are worked out again.
  static const version = 2;

  Map<String, Object?> toJson() => {'v': version, 'e': exact, if (near != null) 'n': near!.toRadixString(16), 'b': bytes};
  static Prints fromJson(Map<String, Object?> j) =>
      Prints(j['e'] as String, j['n'] == null ? null : int.parse(j['n'] as String, radix: 16), (j['b'] as num).toInt());
}

Future<Prints?> printsFor(Item i) async {
  try {
    final File? f = i.path != null ? File(i.path!) : await i.entity?.originFile;
    if (f == null) return null;
    final size = await f.length();
    final raf = await f.open();
    final head = await raf.read(65536);
    await raf.setPosition(size > 65536 ? size - 65536 : 0);
    final tail = await raf.read(65536);
    await raf.close();
    final exact = '$size:${sha1.convert([...head, ...tail])}';
    return Prints(exact, i.isVideo ? null : await _dhash(i), size);
  } catch (_) {
    return null;
  }
}

Future<int?> _dhash(Item i) async {
  final Uint8List? bytes = await media.thumbBytes(i, 72, 72);
  if (bytes == null) return null;
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 9, targetHeight: 8);
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (data == null) return null;
  int grey(int x, int y) {
    final o = (y * 9 + x) * 4;
    return data.getUint8(o) * 299 + data.getUint8(o + 1) * 587 + data.getUint8(o + 2) * 114;
  }

  // Nearly flat pictures (sky, a lens cap, a blank wall, solid colour) all hash alike: no "similar" match for them
  // (exact copies still count).
  var lo = 1 << 30, hi = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 9; x++) {
      final g = grey(x, y);
      if (g < lo) lo = g;
      if (g > hi) hi = g;
    }
  }
  if (hi - lo < 24 * 1000) return null;
  var h = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      h = (h << 1) | (grey(x, y) > grey(x + 1, y) ? 1 : 0);
    }
  }
  return h;
}

int _bits(int v) {
  var n = 0;
  while (v != 0) {
    v &= v - 1;
    n++;
  }
  return n;
}

/// A set of duplicates, best first (most pixels, then the biggest file, then the earliest).
typedef DupGroup = ({List<Item> items, bool exact});

/// Groups photos that are exact copies, or similar shots taken within [window] of each other.
List<DupGroup> groupDuplicates(Map<Item, Prints> prints, {Duration window = const Duration(minutes: 10), int maxBits = 5}) {
  final items = prints.keys.toList()..sort((a, b) => a.taken.compareTo(b.taken));
  final parent = List<int>.generate(items.length, (i) => i);
  int find(int i) => parent[i] == i ? i : parent[i] = find(parent[i]);
  void join(int a, int b) => parent[find(a)] = find(b);
  final byExact = <String, int>{};
  final exactPair = <int>{};
  for (var i = 0; i < items.length; i++) {
    final e = prints[items[i]]!.exact;
    final j = byExact[e];
    if (j != null) {
      join(i, j);
      exactPair..add(i)..add(j);
    } else {
      byExact[e] = i;
    }
  }
  final ms = window.inMilliseconds;
  for (var i = 0; i < items.length; i++) {
    final a = prints[items[i]]!.near;
    if (a == null) continue;
    for (var j = i + 1; j < items.length && items[j].taken - items[i].taken <= ms; j++) {
      final b = prints[items[j]]!.near;
      if (b != null && _bits(a ^ b) <= maxBits) join(i, j);
    }
  }
  final groups = <int, List<int>>{};
  for (var i = 0; i < items.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(i);
  }
  final out = <DupGroup>[];
  for (final g in groups.values.where((g) => g.length > 1)) {
    final list = [for (final i in g) items[i]]
      ..sort((x, y) {
        final px = x.width * x.height, py = y.width * y.height;
        if (px != py) return py.compareTo(px);
        final bx = prints[x]!.bytes, by = prints[y]!.bytes;
        if (bx != by) return by.compareTo(bx);
        return x.taken.compareTo(y.taken);
      });
    out.add((items: list, exact: g.every(exactPair.contains) && {for (final i in g) prints[items[i]]!.exact}.length == 1));
  }
  out.sort((a, b) => a.items.first.taken.compareTo(b.items.first.taken));
  return out;
}

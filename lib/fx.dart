import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'models.dart';

/// The keep / delete animation ("trace"): the outlines inside the photo draw themselves (keep from the bottom up in
/// blue→pink, delete from the top down in dark red→orange), then deleted photos fade out in place; kept ones stay.
/// Values tuned in the motion demo.
class Motion {
  static const traceMs = 710.0;
  static const fadeMs = 560.0;

  /// The fade starts this far into the trace.
  static const fadeStart = 0.75;
  static const thickness = 2.4;
  static const glow = 15.0;

  /// Sobel magnitude a pixel needs to count as an outline (on 0-255 grey).
  static const sensitivity = 120.0;
  static const keep = [Color(0xFF60A5FA), Color(0xFFF472B6)];
  static const delete = [Color(0xFF991B1B), Color(0xFFF97316)];

  static Duration get total =>
      Duration(milliseconds: max(traceMs, traceMs * fadeStart + fadeMs).round());
}

/// A photo's outlines as paths, in 0..1 coordinates (so they fit any size the photo is drawn at).
class Outlines {
  const Outlines(this.chains);
  final List<List<Offset>> chains;
}

final _cache = <String, Future<Outlines>>{};
final _ready = <String, Outlines>{};

/// Finds the outlines before the animation starts (so the lines draw from the first frame), waiting at most a moment.
Future<void> prepareOutlines(Iterable<Item> items) async {
  try {
    await Future.wait([
      for (final i in items.take(40)) outlinesFor(i).then((o) => _ready[i.id] = o),
    ]).timeout(const Duration(milliseconds: 200));
  } catch (_) {}
}

/// Finds the outlines of a photo from a small thumbnail (cached; only photos on screen ever ask).
Future<Outlines> outlinesFor(Item item) {
  if (_cache.length > 300) _cache.remove(_cache.keys.first);
  return _cache.putIfAbsent(item.id, () => _compute(item));
}

Future<Outlines> _compute(Item item) async {
  final bytes = await item.entity.thumbnailDataWithSize(const ThumbnailSize(200, 200));
  if (bytes == null) return const Outlines([]);
  final codec = await ui.instantiateImageCodec(bytes);
  final img = (await codec.getNextFrame()).image;
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final w = img.width, h = img.height;
  img.dispose();
  if (data == null || w < 4 || h < 4) return const Outlines([]);
  return Outlines(_trace(data.buffer.asUint8List(), w, h));
}

/// Sobel edges, thinned to one pixel (non-maximum suppression), linked into paths.
List<List<Offset>> _trace(Uint8List px, int w, int h) {
  final g = Float32List(w * h);
  for (var i = 0; i < w * h; i++) {
    g[i] = px[i * 4] * 0.3 + px[i * 4 + 1] * 0.59 + px[i * 4 + 2] * 0.11;
  }
  final mag = Float32List(w * h), ang = Float32List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final gx = -g[i - w - 1] - 2 * g[i - 1] - g[i + w - 1] + g[i - w + 1] + 2 * g[i + 1] + g[i + w + 1];
      final gy = -g[i - w - 1] - 2 * g[i - w] - g[i - w + 1] + g[i + w - 1] + 2 * g[i + w] + g[i + w + 1];
      mag[i] = sqrt(gx * gx + gy * gy);
      ang[i] = atan2(gy, gx);
    }
  }
  final on = Uint8List(w * h);
  final pts = <int>[];
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x, m = mag[i];
      if (m <= Motion.sensitivity) continue;
      final a = ((ang[i] * 180 / pi) + 180) % 180;
      final (dx, dy) = a < 22.5 || a >= 157.5 ? (1, 0) : a < 67.5 ? (1, 1) : a < 112.5 ? (0, 1) : (-1, 1);
      if (m < mag[i + dy * w + dx] || m < mag[i - dy * w - dx]) continue;
      on[i] = 1;
      pts.add(i);
    }
  }
  const nb = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)];
  int count(int x, int y) {
    var n = 0;
    for (final (a, b) in nb) {
      n += on[(y + b) * w + x + a];
    }
    return n;
  }

  final seen = Uint8List(w * h);
  final chains = <List<Offset>>[];
  void walk(int i) {
    var x = i % w, y = i ~/ w;
    final c = <Offset>[];
    while (true) {
      seen[y * w + x] = 1;
      c.add(Offset(x / w, y / h));
      int? nx, ny;
      for (final (a, b) in nb) {
        final xx = x + a, yy = y + b;
        if (xx < 1 || yy < 1 || xx >= w - 1 || yy >= h - 1) continue;
        final j = yy * w + xx;
        if (on[j] == 1 && seen[j] == 0) {
          nx = xx;
          ny = yy;
          break;
        }
      }
      if (nx == null) break;
      x = nx;
      y = ny!;
    }
    if (c.length >= 6) chains.add(c);
  }

  for (final i in pts) {
    if (seen[i] == 0 && count(i % w, i ~/ w) == 1) walk(i);
  }
  for (final i in pts) {
    if (seen[i] == 0) walk(i);
  }
  return chains;
}

double _ease(double x) => x * x * (3 - 2 * x);

/// Plays the trace over [child] (the photo, already sized to its own shape). Kept photos stay; deleted ones fade and
/// go grey.
class TraceFx extends StatefulWidget {
  const TraceFx({super.key, required this.item, required this.keep, required this.child, this.radius = 0});

  final Item item;
  final bool keep;
  final Widget child;
  final double radius;

  @override
  State<TraceFx> createState() => _TraceFxState();
}

class _TraceFxState extends State<TraceFx> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: Motion.total)..forward();
  Outlines? _lines;

  @override
  void initState() {
    super.initState();
    _lines = _ready[widget.item.id];
    outlinesFor(widget.item).then((o) {
      if (mounted) setState(() => _lines = o);
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          final e = _anim.value * Motion.total.inMilliseconds;
          final trace = _ease(min(1, e / Motion.traceMs));
          final fade = _ease(((e - Motion.traceMs * Motion.fadeStart) / Motion.fadeMs).clamp(0, 1));
          Widget photo = child!;
          if (!widget.keep) {
            photo = Opacity(
              opacity: 1 - fade,
              child: ColorFiltered(colorFilter: ColorFilter.matrix(_grey(fade)), child: photo),
            );
          }
          return Stack(fit: StackFit.passthrough, children: [
            photo,
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TracePainter(_lines, widget.keep, trace, 1 - fade, widget.radius),
                ),
              ),
            ),
          ]);
        },
        child: widget.child,
      );
}

/// Colour matrix from full colour (0) to grey (1).
List<double> _grey(double t) {
  final s = 1 - t;
  const r = 0.2126, g = 0.7152, b = 0.0722;
  return [
    r + (1 - r) * s, g - g * s, b - b * s, 0, 0, //
    r - r * s, g + (1 - g) * s, b - b * s, 0, 0,
    r - r * s, g - g * s, b + (1 - b) * s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

class _TracePainter extends CustomPainter {
  _TracePainter(this.lines, this.keep, this.p, this.alpha, this.radius);

  final Outlines? lines;
  final bool keep;
  final double p;
  final double alpha;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (alpha <= 0) return;
    final cols = keep ? Motion.keep : Motion.delete;
    // Colour follows height: the start edge (bottom for keep, top for delete) gets the first colour.
    final from = keep ? Offset(0, size.height) : Offset.zero;
    final to = keep ? Offset.zero : Offset(0, size.height);
    final shader = ui.Gradient.linear(from, to, [cols[0].withValues(alpha: alpha), cols[1].withValues(alpha: alpha)]);
    final glow = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = Motion.thickness * 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = Motion.glow > 0 ? const MaskFilter.blur(BlurStyle.normal, Motion.glow / 2.5) : null;
    final line = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = Motion.thickness
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (final c in lines?.chains ?? const <List<Offset>>[]) {
      // Each outline draws from its lower end (keep) or upper end (delete).
      final reversed = keep ? c.first.dy < c.last.dy : c.first.dy > c.last.dy;
      final n = max(1, (c.length * p).ceil());
      Offset at(int i) {
        final o = reversed ? c[c.length - 1 - i] : c[i];
        return Offset(o.dx * size.width, o.dy * size.height);
      }

      final s = at(0);
      path.moveTo(s.dx, s.dy);
      for (var i = 1; i < n; i++) {
        final o = at(i);
        path.lineTo(o.dx, o.dy);
      }
    }
    // The frame: up both sides from the start edge, closing at the far edge.
    const inset = 1.5;
    final y0 = keep ? size.height - inset : inset, y1 = keep ? inset : size.height - inset;
    final yy = y0 + (y1 - y0) * p;
    path
      ..moveTo(inset, y0)
      ..lineTo(inset, yy)
      ..moveTo(size.width - inset, y0)
      ..lineTo(size.width - inset, yy)
      ..moveTo(inset, y0)
      ..lineTo(size.width - inset, y0);
    if (p >= 0.98) {
      path
        ..moveTo(inset, y1)
        ..lineTo(size.width - inset, y1);
    }
    canvas.save();
    if (radius > 0) canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    canvas.drawPath(path, glow);
    canvas.drawPath(path, line);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TracePainter old) => old.p != p || old.alpha != alpha || old.lines != lines;
}

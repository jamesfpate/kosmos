import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import 'package:winnow_native/winnow_native.dart';

import '../fx.dart';
import '../media.dart' as media;
import '../models.dart';
import '../state.dart';
import '../version.dart';

class C {
  static const bg = Color(0xFF0B0B0F);
  static const text = Color(0xFFE8E6EE);
  static const muted = Color(0xFF8C8899);
  static const surface = Color(0xFF17161D);
  static const line = Color(0xFF2A2833);
  static const accent = Color(0xFF60A5FA);
  static const keep = Color(0xFF4ADE80);
  static const trash = Color(0xFFF87171);

  /// Checked / selected photos (not green: a check isn't "keep").
  static const select = Color(0xFF60A5FA);
}

final fmtDay = DateFormat('EEE, MMM d, y');
final fmtTime = DateFormat.jm();
final fmtMonth = DateFormat('MMMM y');

String dayOf(int ms) => fmtDay.format(DateTime.fromMillisecondsSinceEpoch(ms));
String timeOf(int ms) => fmtTime.format(DateTime.fromMillisecondsSinceEpoch(ms));

/// The top bar on every screen: single/grid switch, title, uploads, trash, settings.
const _integrationPages = {Screen.immich, Screen.store, Screen.google};

class TopBar extends StatelessWidget {
  const TopBar(this.s, {super.key, required this.title, this.subtitle});

  final AppState s;
  final Widget title;
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    final sync = s.sync;
    return SizedBox(
      height: 56,
      child: Row(children: [
        _Modes(s),
        Expanded(
          child: DefaultTextStyle.merge(
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              // Shrinks (rather than overflowing) when the upload pill takes room.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: DefaultTextStyle.merge(style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14), child: title),
              ),
              if (subtitle != null)
                DefaultTextStyle.merge(style: const TextStyle(color: C.muted, fontSize: 13), child: subtitle!),
            ]),
          ),
        ),
        Pill(
          icon: Icons.delete_outline,
          label: '${s.pendingTrash.length}',
          on: s.screen == Screen.trash,
          onTap: s.pendingTrash.isEmpty && s.screen != Screen.trash ? null : () => s.toggleScreen(Screen.trash),
        ),
        Pill(icon: Icons.help_outline, onTap: () => showHelp(context)),
        // A small dot when the last sync had an error (details on the integration's page).
        Pill(
          icon: Icons.settings_outlined,
          dot: sync.error.isNotEmpty,
          on: s.screen == Screen.settings || _integrationPages.contains(s.screen),
          onTap: () => _integrationPages.contains(s.screen) ? s.go(Screen.settings) : s.toggleScreen(Screen.settings),
        ),
      ]),
    );
  }
}

class _Modes extends StatelessWidget {
  const _Modes(this.s);

  final AppState s;

  @override
  Widget build(BuildContext context) {
    Widget seg(IconData icon, bool on, VoidCallback tap, String label) => Semantics(
          label: label,
          button: true,
          child: InkWell(
            onTap: tap,
            child: Container(
              width: 44,
              height: 40,
              color: on ? C.accent : C.surface,
              child: Icon(icon, size: 20, color: on ? C.bg : C.text),
            ),
          ),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          seg(Icons.crop_portrait, s.screen == Screen.cull, s.openSingle, 'Single'),
          seg(Icons.grid_view, s.screen == Screen.grid, s.openGrid, 'Grid'),
          seg(Icons.photo_library_outlined, s.screen == Screen.explore, s.openExplore, 'Explorer'),
        ]),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.icon, this.label, this.onTap, this.on = false, this.color, this.dot = false});

  final IconData icon;
  final String? label;
  final VoidCallback? onTap;
  final bool on;
  final Color? color;

  /// A small amber dot: something to look at (a sync problem), without alarm.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final fg = on ? C.bg : (color ?? C.text);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Material(
          color: on ? C.accent : C.surface,
          shape: StadiumBorder(side: BorderSide(color: on ? C.accent : C.line)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Container(
              height: 40,
              constraints: const BoxConstraints(minWidth: 40),
              padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 10),
              alignment: Alignment.center,
              child: Stack(clipBehavior: Clip.none, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 18, color: fg),
                  if (label != null) ...[const SizedBox(width: 4), Text(label!, style: TextStyle(color: fg))],
                ]),
                if (dot)
                  Positioned(
                    right: -3,
                    top: -3,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: const Color(0xFFFBBF24), shape: BoxShape.circle, border: Border.all(color: C.surface, width: 1.5)),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A full-width-ish button used in bars and settings.
class Btn extends StatelessWidget {
  const Btn(this.label,
      {super.key, this.onTap, this.icon, this.trailingIcon, this.color, this.bg, this.sub, this.flex = 1, this.bold = false});

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final IconData? trailingIcon;
  final Color? color;
  final Color? bg;
  final String? sub;
  final int flex;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? C.text;
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Material(
        color: bg ?? C.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12), side: BorderSide(color: bg ?? C.line)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            alignment: Alignment.center,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 18, color: fg), if (label.isNotEmpty) const SizedBox(width: 4)],
                if (label.isNotEmpty)
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, fontSize: 15)),
                ),
                if (trailingIcon != null) ...[const SizedBox(width: 4), Icon(trailingIcon, size: 18, color: fg)],
              ]),
              if (sub != null) Text(sub!, style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 11.5)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A row of options with the current one highlighted (settings).
class Choices<T> extends StatelessWidget {
  const Choices({super.key, required this.options, required this.value, required this.onPick});

  final List<(T, String)> options;
  final T value;
  final void Function(T) onPick;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (v, label) in options)
          ChoiceChip(
            label: Text(label),
            selected: v == value,
            onSelected: (_) => onPick(v),
            selectedColor: C.accent,
            labelStyle: TextStyle(color: v == value ? C.bg : C.text, fontWeight: v == value ? FontWeight.w600 : null),
            backgroundColor: C.surface,
            side: BorderSide(color: v == value ? C.accent : C.line),
            showCheckmark: false,
          ),
      ]);
}

/// Album chip in the album bars. The target is green with an arrow.
class AlbumChip extends StatelessWidget {
  const AlbumChip(
      {super.key,
      required this.label,
      this.icon,
      this.target = false,
      this.hover = false,
      this.onTap,
      this.onLongPress,
      this.dashed = false});

  final String label;
  final IconData? icon;
  final bool target;
  final bool hover;
  final bool dashed;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final fg = target ? C.bg : (dashed ? C.accent : C.text);
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: AnimatedScale(
      scale: hover ? 1.08 : 1,
      duration: const Duration(milliseconds: 100),
      child: Material(
        color: target ? C.keep : C.surface,
        shape: StadiumBorder(side: BorderSide(color: hover ? C.accent : (target ? C.keep : C.line), width: hover ? 3 : 1)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            height: 40,
            padding: EdgeInsets.symmetric(horizontal: label.isEmpty ? 10 : 14),
            alignment: Alignment.center,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (target) ...[Icon(Icons.arrow_forward, size: 18, color: fg), const SizedBox(width: 4)],
              if (icon != null) Icon(icon, size: 20, color: fg),
              if (label.isNotEmpty) Text(label, style: TextStyle(color: fg, fontWeight: target ? FontWeight.w700 : null)),
            ]),
          ),
        ),
      ),
      ),
    );
  }
}

/// The Winnow wordmark: the two n's offset, one dropped and one raised, like grain being winnowed. With [busy] (loading)
/// the letters ripple in a wave; with [tap], a tap plays one wave.
class Logo extends StatefulWidget {
  const Logo({super.key, this.size = 22, this.busy = false, this.tap = false});

  final double size;

  /// Waves continuously (loading).
  final bool busy;

  /// At rest; a tap plays one wave.
  final bool tap;

  @override
  State<Logo> createState() => _LogoState();
}

class _LogoState extends State<Logo> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    if (widget.busy) _anim.repeat();
  }

  @override
  void didUpdateWidget(Logo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy && !_anim.isAnimating) _anim.repeat();
    if (!widget.busy && _anim.isAnimating) _anim.stop();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = _letters();
    if (!widget.tap) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _anim.isAnimating ? null : _anim.forward(from: 0),
      child: row,
    );
  }

  double _wave(double shift, int i) {
    if (widget.busy) return shift * 1.2 * sin(2 * pi * _anim.value - i * 0.9);
    if (!_anim.isAnimating) return 0;
    // One tap: a single wave that starts and ends at rest.
    final t = _anim.value;
    return shift * 1.2 * sin(pi * t) * sin(2 * pi * t * 1.5 - i * 0.9);
  }

  Widget _letters() {
    final style = TextStyle(fontSize: widget.size, fontWeight: FontWeight.w800, color: C.text, height: 1);
    final accent = style.copyWith(color: C.accent);
    final shift = widget.size * 0.14;
    const letters = ['w', 'i', 'n', 'n', 'o', 'w'];
    // At rest the first n sits low and the second high.
    final base = [0.0, 0.0, shift, -shift, 0.0, 0.0];
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < letters.length; i++)
          Transform.translate(
            offset: Offset(0, base[i] + _wave(shift, i)),
            child: Text(letters[i], style: i == 2 || i == 3 ? accent : style),
          ),
      ]),
    );
  }
}

class Label extends StatelessWidget {
  const Label(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: const TextStyle(color: C.muted, fontSize: 12, letterSpacing: 0.8), maxLines: 1, overflow: TextOverflow.ellipsis);
}

/// A thumbnail sized for its cell (two cached sizes keep scrolling cheap).
class PhotoThumb extends StatelessWidget {
  const PhotoThumb(this.item, {super.key, this.height = 150});

  final Item item;
  final double height;

  @override
  Widget build(BuildContext context) {
    final px = height * MediaQuery.devicePixelRatioOf(context);
    final size = px > 300 ? 512 : 256;
    return Container(
      color: C.surface,
      child: Image(
        image: media.thumbImage(item, size),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            Center(child: Icon(item.isVideo ? Icons.movie_outlined : Icons.broken_image_outlined, color: C.muted)),
      ),
    );
  }
}

/// Large view of a photo, or an inline video player once [play] is set.
class Preview extends StatefulWidget {
  const Preview(this.item,
      {super.key, this.play = false, this.onStop, this.selected = false, this.onCheck, this.caption = false, this.fx});

  /// Playing the keep (true) / delete (false) trace.
  final bool? fx;

  final Item item;
  final bool play;

  /// Checked in a burst: blue border around the photo itself, with the check.
  final bool selected;

  /// In a burst: shows the check circle (filled or empty) on the photo; tapping it toggles.
  final VoidCallback? onCheck;

  /// Date and time overlaid at the bottom of the photo.
  final bool caption;
  final VoidCallback? onStop;

  @override
  State<Preview> createState() => _PreviewState();
}

class _PreviewState extends State<Preview> {
  VideoPlayerController? _video;

  /// The shape of the frame actually shown. Android sometimes reports a video's size unrotated (or not at all), so
  /// the decoded thumbnail decides, not the library's width and height.
  double? _aspect;
  ImageStream? _stream;
  late final _listener = ImageStreamListener((info, _) {
    final w = info.image.width, h = info.image.height;
    if (w > 0 && h > 0 && mounted) setState(() => _aspect = (w / h).clamp(0.4, 2.5));
  });

  ImageProvider get _image => media.thumbImage(widget.item, 1600);

  void _watch() {
    _stream?.removeListener(_listener);
    _stream = _image.resolve(ImageConfiguration.empty)..addListener(_listener);
  }

  @override
  void didUpdateWidget(Preview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.play && _video == null) _start();
    if (!widget.play || oldWidget.item.id != widget.item.id) _stop();
    if (oldWidget.item.id != widget.item.id) {
      _aspect = null;
      _watch();
    }
  }

  @override
  void initState() {
    super.initState();
    _watch();
    if (widget.play) _start();
  }

  Future<void> _start() async {
    final f = await widget.item.playable();
    if (f == null || !mounted) return;
    final c = VideoPlayerController.file(f);
    _video = c;
    await c.initialize();
    if (!mounted || _video != c) return c.dispose();
    c.addListener(() {
      if (c.value.isCompleted) widget.onStop?.call();
    });
    await c.play();
    setState(() {});
  }

  void _stop() {
    final c = _video;
    _video = null;
    c?.dispose();
  }

  @override
  void dispose() {
    _stop();
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    if (widget.play && v != null && v.value.isInitialized) {
      // The reported size is already the upright shape; VideoPlayer turns the picture into it by rotationCorrection.
      final size = v.value.size;
      final ar = size.width > 0 && size.height > 0 ? size.width / size.height : _aspect ?? widget.item.aspect;
      return Column(children: [
        Expanded(
          child: Center(
            child: GestureDetector(
              onTap: () => setState(() => v.value.isPlaying ? v.pause() : v.play()),
              child: AspectRatio(aspectRatio: ar, child: VideoPlayer(v)),
            ),
          ),
        ),
        VideoProgressIndicator(v, allowScrubbing: true, padding: const EdgeInsets.symmetric(vertical: 8)),
      ]);
    }
    // Sized to the photo's own shape, so the border and check sit on the photo, not the empty space around it.
    final photo = Stack(fit: StackFit.expand, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image(
              image: _image,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, e, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text("Can't show ${widget.item.name}\n$e", textAlign: TextAlign.center, style: const TextStyle(color: C.muted)),
              ),
            ),
          ),
          if (widget.selected)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: C.select, width: 4), borderRadius: BorderRadius.circular(12)),
              ),
            ),
          if (widget.onCheck != null)
            Positioned(top: 2, left: 2, child: CheckBadge(size: 36, checked: widget.selected, onTap: widget.onCheck)),
          if (widget.caption)
            Positioned(
              left: 10,
              bottom: 10,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                  child: Text('${dayOf(widget.item.taken)} · ${timeOf(widget.item.taken)}',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
        ]);
    return Center(
      child: AspectRatio(
        aspectRatio: _aspect ?? widget.item.aspect,
        child: widget.fx == null ? photo : TraceFx(item: widget.item, keep: widget.fx!, radius: 12, child: photo),
      ),
    );
  }
}

/// Check circle: filled when [checked], an empty ring otherwise. With [onTap] it toggles directly (no need to tap the
/// photo twice); the hit area is larger than the circle.
class CheckBadge extends StatelessWidget {
  const CheckBadge({super.key, this.size = 24, this.checked = true, this.onTap});

  final double size;
  final bool checked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: checked ? C.select : Colors.black38,
        shape: BoxShape.circle,
        border: Border.all(color: checked ? Colors.black.withValues(alpha: 0.35) : Colors.white70, width: 2),
      ),
      child: checked ? Icon(Icons.check, size: size * 0.62, color: C.bg) : null,
    );
    if (onTap == null) return circle;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.all(8), child: circle),
    );
  }
}

/// Big play button over a video (single mode and the full-size viewer), with its length.
class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.seconds, required this.onTap});

  final int seconds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white70, width: 2),
            ),
            child: const Icon(Icons.play_arrow_rounded, size: 52, color: Colors.white),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
            child: Text(seconds >= 60 ? '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}' : '0:${seconds.toString().padLeft(2, '0')}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ]),
      );
}

class VideoBadge extends StatelessWidget {
  const VideoBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
        child: const Icon(Icons.play_arrow, size: 16, color: Colors.white),
      );
}

/// Justified rows: photos keep their real shape. Full rows are scaled to fill the width exactly (height near [h]);
/// the last row stays at [h].
List<({double h, List<Item> items})> justify(List<Item> list, double width, double h, {double gap = 3}) {
  final rows = <({double h, List<Item> items})>[];
  if (width <= 0) return rows;
  var row = <Item>[];
  var sum = 0.0;
  for (final item in list) {
    row.add(item);
    sum += item.aspect;
    final gaps = (row.length - 1) * gap;
    if (sum * h + gaps >= width) {
      rows.add((h: (width - gaps) / sum, items: row));
      row = [];
      sum = 0;
    }
  }
  if (row.isNotEmpty) rows.add((h: h, items: row));
  return rows;
}

/// Thumbnail size slider (burst grid and grid mode).
class SizeSlider extends StatelessWidget {
  const SizeSlider(this.s, {super.key});

  final AppState s;

  @override
  Widget build(BuildContext context) => Row(children: [
        const Icon(Icons.photo_size_select_small, size: 18, color: C.muted),
        Expanded(
          child: Slider(
            value: s.thumbH,
            min: thumbMin,
            max: thumbMax,
            activeColor: C.accent,
            onChanged: (v) => s.setThumbH(v),
            onChangeEnd: (v) => s.setThumbH(v, save: true),
          ),
        ),
        const Icon(Icons.photo_size_select_large, size: 18, color: C.muted),
      ]);
}

/// Shows an "AlbumSheet"-style message.
void toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

/// Asks for a folder of photos to review (on a computer).
Future<void> pickFolder(AppState s, [BuildContext? context]) async {
  try {
    final dir = await FilePicker.pickDirectory(dialogTitle: 'Folder of photos to review');
    if (dir != null) await s.addFolder(dir.isScheme('file') ? dir.toFilePath() : dir.path);
  } catch (e) {
    // Never a silent button: say what went wrong.
    if (context != null && context.mounted) toast(context, "Couldn't open the folder picker: $e");
  }
}

/// Pages follow a mouse drag too (Flutter's default is touch only).
final pagerScroll = const MaterialScrollBehavior().copyWith(dragDevices: PointerDeviceKind.values.toSet());

/// Keyboard for a full-screen pager: ← / → page, Esc closes.
Widget pagerKeys(BuildContext context, PageController pages, Widget child) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            pages.previousPage(duration: const Duration(milliseconds: 180), curve: Curves.easeOut),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            pages.nextPage(duration: const Duration(milliseconds: 180), curve: Curves.easeOut),
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Focus(autofocus: true, child: child),
    );

/// Full-size view of [items] from the swipe card: pinch or double-tap to zoom, swipe for the next one, tap or Esc to
/// close.
class FullView extends StatefulWidget {
  const FullView(this.items, {super.key, this.start = 0});

  final List<Item> items;
  final int start;

  static Future<void> open(BuildContext context, List<Item> items, Item at) => Navigator.of(context).push(
        MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => FullView(items, start: max(0, items.indexOf(at)))),
      );

  @override
  State<FullView> createState() => _FullViewState();
}

class _FullViewState extends State<FullView> {
  late final PageController _pages = PageController(initialPage: widget.start);
  late int index = widget.start;
  final _zoom = TransformationController();
  bool zoomed = false;
  String? playing;
  TapDownDetails? _tap;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() {
      final z = _zoom.value.getMaxScaleOnAxis() > 1.01;
      if (z != zoomed) setState(() => zoomed = z);
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _doubleTap() {
    if (zoomed) {
      _zoom.value = Matrix4.identity();
      return;
    }
    final p = _tap?.localPosition ?? Offset.zero;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(-p.dx * 1.5, -p.dy * 1.5, 0, 1)
      ..scaleByDouble(2.5, 2.5, 1, 1);
  }

  Widget _page(Item item) {
    if (item.isVideo) {
      return Stack(alignment: Alignment.center, children: [
        Preview(item, play: playing == item.id, onStop: () => setState(() => playing = null)),
        if (playing != item.id) PlayButton(seconds: item.duration, onTap: () => setState(() => playing = item.id)),
      ]);
    }
    return GestureDetector(
      onTap: () => Navigator.maybePop(context),
      onDoubleTapDown: (d) => _tap = d,
      onDoubleTap: _doubleTap,
      child: InteractiveViewer(
        transformationController: _zoom,
        maxScale: 8,
        child: SizedBox.expand(
          child: Image(image: media.thumbImage(item, 4096), fit: BoxFit.contain, gaplessPlayback: true),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[index];
    return pagerKeys(context, _pages, Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(children: [
          PageView.builder(
            controller: _pages,
            scrollBehavior: pagerScroll,
            physics: zoomed ? const NeverScrollableScrollPhysics() : null,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() {
              index = i;
              playing = null;
              _zoom.value = Matrix4.identity();
            }),
            itemBuilder: (_, i) => _page(widget.items[i]),
          ),
          Positioned(
            top: 4,
            left: 12,
            right: 4,
            child: Row(children: [
              Expanded(
                child: Text(
                  '${dayOf(item.taken)} · ${timeOf(item.taken)}${widget.items.length > 1 ? '  ·  ${index + 1} of ${widget.items.length}' : ''}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, shadows: [Shadow(blurRadius: 4)]),
                ),
              ),
              IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.maybePop(context)),
            ]),
          ),
        ]),
      ),
    ));
  }
}

/// Help & feedback: feedback and problem reports go to the issue tracker, with the app version and device filled in.
Future<void> showHelp(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (c) {
        String issue(String title, String body) => Uri.https('github.com', '/jamesfpate/winnow/issues/new', {
              'title': title,
              'body': '$body\n\n---\nWinnow $version · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
            }).toString();
        Future<void> open(String url) async {
          Navigator.pop(c);
          await WinnowNative.openUrl(url);
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Help & feedback', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text(
                'Ideas, questions or something not working? It goes to Winnow\'s issue tracker on GitHub (a free account '
                'is needed to post), with the app version and device filled in. No photos or settings are sent.',
                style: TextStyle(color: C.muted),
              ),
              const SizedBox(height: 14),
              Btn('Send feedback', icon: Icons.chat_bubble_outline,
                  onTap: () => open(issue('Feedback: ', 'What would make Winnow better for you?\n\n'))),
              const SizedBox(height: 8),
              Btn('Report a problem', icon: Icons.bug_report_outlined,
                  onTap: () => open(issue('Problem: ', 'What happened, and what did you expect?\n\nSteps to see it again:\n1. '))),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => open('https://winnow.jamespate.net'),
                child: const Text('How Winnow works', style: TextStyle(color: C.accent)),
              ),
              Center(child: Text('Winnow $version', style: const TextStyle(color: C.muted, fontSize: 12))),
            ]),
          ),
        );
      },
    );

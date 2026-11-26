import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:video_player/video_player.dart';

import '../models.dart';
import '../state.dart';

class C {
  static const bg = Color(0xFF0B0B0F);
  static const text = Color(0xFFE8E6EE);
  static const muted = Color(0xFF8C8899);
  static const surface = Color(0xFF17161D);
  static const line = Color(0xFF2A2833);
  static const accent = Color(0xFFB9A6FF);
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
              DefaultTextStyle.merge(style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14), child: title),
              if (subtitle != null)
                DefaultTextStyle.merge(style: const TextStyle(color: C.muted, fontSize: 13), child: subtitle!),
            ]),
          ),
        ),
        if (s.immich.enabled && (sync.pending > 0 || sync.running || sync.error.isNotEmpty))
          Pill(
            icon: Icons.arrow_upward,
            label: sync.error.isNotEmpty ? '!' : '${sync.pending}',
            color: sync.error.isNotEmpty ? C.trash : null,
            onTap: () => s.go(Screen.immich),
          ),
        Pill(
          icon: Icons.delete_outline,
          label: '${s.pendingTrash.length}',
          on: s.screen == Screen.trash,
          onTap: s.pendingTrash.isEmpty && s.screen != Screen.trash ? null : () => s.toggleScreen(Screen.trash),
        ),
        Pill(
          icon: Icons.settings_outlined,
          on: s.screen == Screen.settings || s.screen == Screen.immich,
          onTap: () => s.screen == Screen.immich ? s.go(Screen.settings) : s.toggleScreen(Screen.settings),
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
              width: 50,
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
          seg(Icons.crop_portrait, s.screen == Screen.cull, s.openSingle, 'Single photo'),
          seg(Icons.grid_view, s.screen == Screen.grid, s.openGrid, 'Grid'),
        ]),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.icon, this.label, this.onTap, this.on = false, this.color});

  final IconData icon;
  final String? label;
  final VoidCallback? onTap;
  final bool on;
  final Color? color;

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
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 18, color: fg),
                if (label != null) ...[const SizedBox(width: 4), Text(label!, style: TextStyle(color: fg))],
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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            alignment: Alignment.center,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 5)],
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
  const AlbumChip({super.key, required this.label, this.target = false, this.hover = false, this.onTap, this.dashed = false});

  final String label;
  final bool target;
  final bool hover;
  final bool dashed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = target ? C.bg : (dashed ? C.accent : C.text);
    return AnimatedScale(
      scale: hover ? 1.08 : 1,
      duration: const Duration(milliseconds: 100),
      child: Material(
        color: target ? C.keep : C.surface,
        shape: StadiumBorder(side: BorderSide(color: hover ? C.accent : (target ? C.keep : C.line), width: hover ? 3 : 1)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (target) ...[Icon(Icons.arrow_forward, size: 18, color: fg), const SizedBox(width: 4)],
              Text(label, style: TextStyle(color: fg, fontWeight: target ? FontWeight.w700 : null)),
            ]),
          ),
        ),
      ),
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
      child: AssetEntityImage(
        item.entity,
        isOriginal: false,
        thumbnailSize: ThumbnailSize.square(size),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
      ),
    );
  }
}

/// Large view of a photo, or an inline video player once [play] is set.
class Preview extends StatefulWidget {
  const Preview(this.item, {super.key, this.play = false, this.onStop});

  final Item item;
  final bool play;
  final VoidCallback? onStop;

  @override
  State<Preview> createState() => _PreviewState();
}

class _PreviewState extends State<Preview> {
  VideoPlayerController? _video;

  @override
  void didUpdateWidget(Preview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.play && _video == null) _start();
    if (!widget.play || oldWidget.item.id != widget.item.id) _stop();
  }

  @override
  void initState() {
    super.initState();
    if (widget.play) _start();
  }

  Future<void> _start() async {
    final f = await widget.item.entity.file;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    if (widget.play && v != null && v.value.isInitialized) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: GestureDetector(
            onTap: () => setState(() => v.value.isPlaying ? v.pause() : v.play()),
            child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
          ),
        ),
        VideoProgressIndicator(v, allowScrubbing: true, padding: const EdgeInsets.symmetric(vertical: 8)),
      ]);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AssetEntityImage(
        widget.item.entity,
        isOriginal: false,
        thumbnailSize: const ThumbnailSize(1600, 1600),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, e, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text("Can't show ${widget.item.name}\n$e", textAlign: TextAlign.center, style: const TextStyle(color: C.muted)),
        ),
      ),
    );
  }
}

class CheckBadge extends StatelessWidget {
  const CheckBadge({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: C.select,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black.withValues(alpha: 0.35), width: 2),
        ),
        child: Icon(Icons.check, size: size * 0.62, color: C.bg),
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

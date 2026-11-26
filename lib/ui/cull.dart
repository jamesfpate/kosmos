import 'dart:math';

import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import 'album_sheet.dart';
import 'common.dart';

/// The swipe screen: one photo (swipe right = keep into the green album, left = delete) or a burst card.
class CullScreen extends StatefulWidget {
  const CullScreen(this.s, {super.key});

  final AppState s;

  @override
  State<CullScreen> createState() => _CullScreenState();
}

class _CullScreenState extends State<CullScreen> {
  final chipKeys = <String, GlobalKey>{};
  final card = GlobalKey<SwipeCardState>();
  String? hover;
  String? playing;

  AppState get s => widget.s;

  /// Album chip under a drag point (chips grow a little vertically so they're easy to hit).
  String? targetAt(Offset p) {
    for (final e in chipKeys.entries) {
      final box = e.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final r = (box.localToGlobal(Offset.zero) & box.size).inflate(24);
      if (r.contains(p)) return e.key;
    }
    return null;
  }

  Future<void> decide(Dir dir) async {
    playing = null;
    await s.decide(dir);
  }

  @override
  Widget build(BuildContext context) {
    final cur = s.current;
    final g = s.group;
    final sel = s.selected;
    final target = s.target;
    return Column(children: [
      TopBar(s,
          title: Text(cur == null ? 'Winnow' : dayOf(cur.taken)),
          subtitle: cur == null ? null : Text('${timeOf(cur.taken)} · ${s.queue.length} left')),
      Align(alignment: Alignment.centerLeft, child: Label(sel.isNotEmpty && !s.burstAll ? 'Choose album for ${sel.length}' : 'Choose album')),
      const SizedBox(height: 4),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final a in s.barAlbums)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: AlbumChip(
                key: chipKeys.putIfAbsent(a.id, GlobalKey.new),
                label: albumTitle(a),
                target: a.id == target?.id,
                hover: hover == a.id,
                onTap: () => s.choose(a.id),
              ),
            ),
          AlbumChip(
            key: chipKeys.putIfAbsent('new', GlobalKey.new),
            label: '+ New album',
            dashed: true,
            hover: hover == 'new',
            onTap: cur == null ? null : () => newAlbum(context, s, g.first.taken),
          ),
        ]),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: cur == null
            ? _caughtUp(context)
            : SwipeCard(
                key: card,
                cardId: '${g.first.id}/${s.queue.length}',
                disabled: s.isGroup,
                keepLabel: s.isGroup ? (s.burstAll ? 'Keep all ${g.length}' : 'Keep ${sel.length}') : 'Keep in ${target == null ? 'a new album' : albumTitle(target)}',
                trashLabel: s.isGroup ? (s.burstAll ? 'Delete all ${g.length}' : 'Delete ${sel.length}') : 'Delete',
                onSwipe: decide,
                onTap: s.isGroup ? () => s.toggleCheck(cur.id) : null,
                onDrag: (p) => setState(() => hover = p == null ? null : targetAt(p)),
                onDrop: (p) {
                  final t = targetAt(p);
                  setState(() => hover = null);
                  if (t == 'new') {
                    newAlbum(context, s, g.first.taken, fileAfter: true);
                    return false;
                  }
                  if (t != null) {
                    s.file(Dir.right, t);
                    return true;
                  }
                  return false;
                },
                child: _cardBody(cur),
              ),
      ),
      if (s.isGroup) ...[
        SizeSlider(s),
        Text(
          s.burstAll
              ? (sel.isEmpty ? 'Nothing checked · tap a photo to view it, again to check it' : 'All checked · tap a photo to view it, again to uncheck it')
              : s.burstRest > 0
                  ? '${sel.length} checked · the other ${s.burstRest} go the opposite way'
                  : '${sel.length} checked · the other ${g.length - sel.length} stay for later',
          style: const TextStyle(color: C.muted, fontSize: 12.5),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
      ],
      _footer(context, cur),
    ]);
  }

  Widget _caughtUp(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('All caught up', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          if (s.pendingTrash.isNotEmpty)
            Btn('Review trash (${s.pendingTrash.length})', color: C.bg, bg: C.accent, onTap: () => s.go(Screen.trash))
          else
            const Text('New photos show up here.', style: TextStyle(color: C.muted)),
          if (s.backlog.isNotEmpty) ...[
            const SizedBox(height: 8),
            Btn('File older photos (${s.backlog.length})', onTap: s.openGrid),
          ],
        ]),
      );

  Widget _cardBody(Item cur) {
    final g = s.group;
    final sel = s.selected;
    final large = Stack(alignment: Alignment.center, children: [
      Positioned.fill(
        child: Container(
          decoration: s.isGroup && sel.contains(cur.id)
              ? BoxDecoration(border: Border.all(color: C.select, width: 4), borderRadius: BorderRadius.circular(14))
              : null,
          alignment: Alignment.center,
          child: Preview(cur, play: playing == cur.id, onStop: () => setState(() => playing = null)),
        ),
      ),
      if (s.isGroup && sel.contains(cur.id)) const Positioned(top: 10, left: 10, child: CheckBadge(size: 36)),
      if (cur.isVideo && playing != cur.id)
        Positioned(
          bottom: 14,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.black54),
            onPressed: () => setState(() => playing = cur.id),
            icon: const Icon(Icons.play_arrow),
            label: Text('${cur.entity.duration}s'),
          ),
        ),
    ]);
    if (!s.isGroup) return large;
    return LayoutBuilder(builder: (context, box) {
      final gridH = box.maxHeight * s.gridFrac;
      return Column(children: [
        Expanded(child: large),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) {
            final local = (context.findRenderObject() as RenderBox).globalToLocal(d.globalPosition);
            s.setGridFrac((box.maxHeight - local.dy) / box.maxHeight);
          },
          onVerticalDragEnd: (_) => s.setGridFrac(s.gridFrac, save: true),
          child: SizedBox(
            height: 28,
            child: Center(
              child: Container(width: 48, height: 5, decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(3))),
            ),
          ),
        ),
        SizedBox(
          height: gridH,
          child: LayoutBuilder(builder: (context, gbox) {
            final rows = justify(g, gbox.maxWidth, s.thumbH);
            return ListView(padding: EdgeInsets.zero, children: [
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(children: [
                    for (final (n, item) in row.items.indexed) ...[
                      if (n > 0) const SizedBox(width: 3),
                      _burstCell(item, row.h, g.indexOf(item)),
                    ],
                  ]),
                ),
            ]);
          }),
        ),
      ]);
    });
  }

  Widget _burstCell(Item item, double h, int i) {
    final checked = s.selected.contains(item.id);
    return GestureDetector(
      onTap: () => i == s.focus ? s.toggleCheck(item.id) : s.setFocus(i),
      child: SizedBox(
        width: item.aspect * h,
        height: h,
        child: Stack(fit: StackFit.expand, children: [
          PhotoThumb(item, height: h),
          if (item.isVideo) const Positioned(bottom: 6, right: 6, child: VideoBadge()),
          if (checked) const Positioned(top: 5, left: 5, child: CheckBadge()),
          if (i == s.focus || checked)
            DecoratedBox(
              decoration: BoxDecoration(border: Border.all(color: checked ? C.select : C.text, width: checked ? 3 : 2)),
            ),
        ]),
      ),
    );
  }

  Widget _footer(BuildContext context, Item? cur) {
    final g = s.group;
    final sel = s.selected;
    final target = s.target;
    final rest = s.burstRest;
    return Row(children: [
      Expanded(flex: 8, child: Btn('Undo', icon: Icons.undo, onTap: s.undoStack.isEmpty ? null : s.undo)),
      const SizedBox(width: 6),
      if (s.isGroup) ...[
        Expanded(
          flex: 15,
          child: Btn(s.burstAll ? 'Delete all ${g.length}' : 'Delete ${sel.length}',
              color: C.trash, sub: rest > 0 ? 'keep $rest' : null, onTap: () => card.currentState?.fling(Dir.left)),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 15,
          child: Btn(s.burstAll ? 'Keep all ${g.length}' : 'Keep ${sel.length}',
              bold: true, color: C.bg, bg: C.keep, sub: rest > 0 ? 'delete $rest' : null, onTap: () => card.currentState?.fling(Dir.right)),
        ),
      ] else ...[
        Expanded(
          flex: 10,
          child: Btn('Delete', icon: Icons.arrow_back, color: C.trash, onTap: cur == null ? null : () => card.currentState?.fling(Dir.left)),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 20,
          child: Btn(target == null ? 'New album' : albumTitle(target),
              icon: Icons.arrow_forward, bold: true, color: C.bg, bg: C.keep, onTap: cur == null ? null : () => card.currentState?.fling(Dir.right)),
        ),
      ],
      const SizedBox(width: 6),
      Expanded(flex: 8, child: Btn('Later', onTap: s.queue.length <= g.length ? null : s.later)),
    ]);
  }
}

/// A card that follows the finger and flies off left/right; an upward drag can drop it on an album chip.
class SwipeCard extends StatefulWidget {
  const SwipeCard({
    super.key,
    required this.cardId,
    required this.child,
    required this.onSwipe,
    this.onTap,
    this.onDrag,
    this.onDrop,
    this.keepLabel = 'Keep',
    this.trashLabel = 'Delete',
    this.disabled = false,
  });

  /// Changes when a new photo or burst comes up; the card starts fresh in the middle.
  final String cardId;
  final Widget child;
  final Future<void> Function(Dir) onSwipe;
  final VoidCallback? onTap;
  final void Function(Offset?)? onDrag;
  final bool Function(Offset)? onDrop;
  final String keepLabel;
  final String trashLabel;

  /// No dragging (bursts are decided with the buttons); taps and fling() still work.
  final bool disabled;

  @override
  State<SwipeCard> createState() => SwipeCardState();
}

class SwipeCardState extends State<SwipeCard> with SingleTickerProviderStateMixin {
  // Touches this close to the screen's left/right edge belong to Android's back gesture.
  static const edge = 28.0;

  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  Offset _pos = Offset.zero;
  Offset _from = Offset.zero;
  Offset _to = Offset.zero;
  bool _dragging = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() => setState(() => _pos = Offset.lerp(_from, _to, Curves.easeOut.transform(_anim.value))!));
  }

  @override
  void didUpdateWidget(SwipeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cardId != widget.cardId) {
      _anim.stop();
      _pos = Offset.zero;
      _leaving = false;
      _dragging = false;
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        final hint = _pos.dy.abs() > _pos.dx.abs() ? 0.0 : min(1.0, _pos.dx.abs() / 120);
        return GestureDetector(
          onTap: widget.onTap,
          onPanStart: (d) {
            final x = d.globalPosition.dx;
            if (widget.disabled || _leaving || x < edge || x > MediaQuery.sizeOf(context).width - edge) return;
            _dragging = true;
          },
          onPanUpdate: (d) {
            if (!_dragging) return;
            setState(() => _pos += d.delta);
            widget.onDrag?.call(d.globalPosition);
          },
          onPanEnd: (d) {
            if (!_dragging) return;
            _dragging = false;
            widget.onDrag?.call(null);
            final v = d.velocity.pixelsPerSecond;
            if (_pos.dy < -60 && _pos.dy.abs() > _pos.dx.abs() && widget.onDrop != null) {
              final global = (context.findRenderObject() as RenderBox).localToGlobal(Offset(w / 2, box.maxHeight / 2) + _pos);
              if (widget.onDrop!(d.globalPosition) || widget.onDrop!(global)) {
                _animate(Offset(_pos.dx, -MediaQuery.sizeOf(context).height));
                _leaving = true;
                return;
              }
              return reset();
            }
            if (_pos.dx.abs() > w * 0.3 || (v.dx.abs() > 800 && _pos.dx.abs() > 40)) {
              fling(_pos.dx > 0 ? Dir.right : Dir.left);
            } else {
              reset();
            }
          },
          child: Transform.translate(
            offset: Offset(_pos.dx, _leaving || _pos.dy < 0 ? _pos.dy : _pos.dy * 0.3),
            child: Transform.rotate(
              angle: _pos.dx / w * 0.25,
              child: Stack(children: [
                Positioned.fill(child: widget.child),
                Positioned(top: 24, left: 20, child: _label(widget.keepLabel, C.keep, -0.2, _pos.dx > 0 ? hint : 0)),
                Positioned(top: 24, right: 20, child: _label(widget.trashLabel, C.trash, 0.2, _pos.dx < 0 ? hint : 0)),
              ]),
            ),
          ),
        );
      });
  }

  Widget _label(String text, Color c, double angle, double opacity) => IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Transform.rotate(
            angle: angle,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black45,
                border: Border.all(color: c, width: 3),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(text,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c, fontSize: 20, fontWeight: FontWeight.w800)),
            ),
          ),
        ),
      );

  void _animate(Offset to) {
    _from = _pos;
    _to = to;
    _anim.forward(from: 0);
  }

  /// Animate the card off screen, then report the decision. Also used by the buttons.
  Future<void> fling(Dir dir) async {
    if (_leaving) return;
    _leaving = true;
    final w = MediaQuery.sizeOf(context).width;
    _animate(Offset((dir == Dir.right ? 1 : -1) * w * 1.4, _pos.dy));
    await Future<void>.delayed(const Duration(milliseconds: 180));
    await widget.onSwipe(dir);
    if (mounted) reset();
  }

  void reset() {
    _leaving = false;
    _animate(Offset.zero);
  }
}

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../fx.dart';
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

  Future<void> decide(Dir dir, bool fx) async {
    playing = null;
    await s.decide(dir, fx: fx);
  }

  /// Keyboard (computers): ← / → like the Delete / Keep buttons but with the swipe's speed, ↓ Later, Space plays a
  /// video, Z or ⌘Z / Ctrl+Z undoes.
  @override
  Widget build(BuildContext context) {
    void fling(Dir dir) {
      if (s.current != null) card.currentState?.fling(dir, fx: false);
    }

    void later() {
      if (s.queue.length > s.group.length) s.later();
    }

    void undo() {
      if (s.undoStack.isNotEmpty) s.undo();
    }

    void play() {
      final cur = s.current;
      if (cur != null && cur.isVideo) setState(() => playing = playing == cur.id ? null : cur.id);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => fling(Dir.left),
        const SingleActivator(LogicalKeyboardKey.backspace): () => fling(Dir.left),
        const SingleActivator(LogicalKeyboardKey.delete): () => fling(Dir.left),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => fling(Dir.right),
        const SingleActivator(LogicalKeyboardKey.enter): () => fling(Dir.right),
        const SingleActivator(LogicalKeyboardKey.arrowDown): later,
        const SingleActivator(LogicalKeyboardKey.space): play,
        const SingleActivator(LogicalKeyboardKey.keyZ): undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): undo,
      },
      child: Focus(autofocus: true, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final cur = s.current;
    final g = s.group;
    final sel = s.selected;
    final target = s.target;
    return Column(children: [
      TopBar(s,
          title: const Logo(tap: true),
          subtitle: Text(cur == null ? 'All caught up' : '${s.queue.length} left')),
      Align(alignment: Alignment.centerLeft, child: Label(sel.isNotEmpty && !s.burstAll ? 'Choose album for ${sel.length}' : 'Choose album')),
      const SizedBox(height: 4),
      SizedBox(
        height: 44,
        // The new-album chip sits outside the scrolling list, so it's always in view.
        child: Row(children: [
          if (s.barAlbums.isNotEmpty)
            Flexible(
              child: ListView(scrollDirection: Axis.horizontal, shrinkWrap: true, children: [
                for (final a in s.barAlbums)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: AlbumChip(
                      key: chipKeys.putIfAbsent(a.id, GlobalKey.new),
                      label: albumTitle(a),
                      target: a.id == target?.id,
                      hover: hover == a.id,
                      // Tap picks it; tapping the current album again (or a long press) edits it.
                      onTap: () => a.id == target?.id ? editAlbum(context, s, a) : s.choose(a.id),
                      onLongPress: () => editAlbum(context, s, a),
                    ),
                  ),
              ]),
            ),
          if (s.barAlbums.isNotEmpty) const SizedBox(width: 6),
          AlbumChip(
            key: chipKeys.putIfAbsent('new', GlobalKey.new),
            label: s.barAlbums.isEmpty ? '+ New album' : '+ New',
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
                onLongPress: () => FullView.open(context, g, cur),
                onDrag: (p) => setState(() => hover = p == null ? null : targetAt(p)),
                onDrop: (p) {
                  final t = targetAt(p);
                  setState(() => hover = null);
                  if (t == 'new') {
                    newAlbum(context, s, g.first.taken, fileAfter: true);
                    return false;
                  }
                  if (t != null) {
                    s.file(Dir.right, t, fx: false);
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
              ? (sel.isEmpty ? 'Nothing checked · tap a circle to check a photo' : 'All checked · tap a circle to uncheck a photo')
              : '${sel.length} checked · ${g.length - sel.length} unchecked',
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
        child: Preview(cur,
            play: playing == cur.id,
            onStop: () => setState(() => playing = null),
            selected: s.isGroup && sel.contains(cur.id),
            fx: s.fx[cur.id],
            caption: true,
            onCheck: s.isGroup ? () => s.toggleCheck(cur.id) : null),
      ),
      if (cur.isVideo && playing != cur.id)
        PlayButton(seconds: cur.duration, onTap: () => setState(() => playing = cur.id)),
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
            height: 36,
            width: double.infinity,
            child: Stack(alignment: Alignment.center, children: [
              Container(width: 48, height: 5, decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(3))),
              Positioned(
                left: 0,
                child: Text('${sel.length} of ${g.length} selected', style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              // Check / uncheck the whole burst.
              Positioned(
                right: 0,
                child: TextButton.icon(
                  onPressed: () => s.setAllChecked(sel.length != g.length),
                  icon: Icon(sel.length == g.length ? Icons.remove_done : Icons.done_all, size: 18),
                  label: Text(sel.length == g.length ? 'Uncheck all' : 'Check all'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: C.accent),
                ),
              ),
            ]),
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
      onLongPress: () => FullView.open(context, s.group, item),
      child: SizedBox(
        width: item.aspect * h,
        height: h,
        child: _fx(item, Stack(fit: StackFit.expand, children: [
          PhotoThumb(item, height: h),
          if (item.isVideo) const Positioned(bottom: 6, right: 6, child: VideoBadge()),
          if (i == s.focus || checked)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: checked ? C.select : C.text, width: checked ? 3 : 2)),
              ),
            ),
          // Last, so it's on top of the frame and gets the tap.
          Positioned(top: -3, left: -3, child: CheckBadge(checked: checked, onTap: () => s.toggleCheck(item.id))),
        ])),
      ),
    );
  }

  /// Wraps a photo in the keep/delete trace while it's playing.
  Widget _fx(Item item, Widget child) {
    final f = s.fx[item.id];
    return f == null ? child : TraceFx(item: item, keep: f, child: child);
  }

  Widget _footer(BuildContext context, Item? cur) {
    final g = s.group;
    final sel = s.selected;
    final target = s.target;
    final rest = s.burstRest;
    return Row(children: [
      Expanded(flex: 6, child: Btn('', icon: Icons.undo, onTap: s.undoStack.isEmpty ? null : s.undo)),
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
          flex: 13,
          child: Btn('Delete', icon: Icons.arrow_back, color: C.trash, onTap: cur == null ? null : () => card.currentState?.fling(Dir.left)),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 16,
          child: Btn(target == null ? 'New album' : albumTitle(target),
              icon: Icons.arrow_forward, bold: true, color: C.bg, bg: C.keep, onTap: cur == null ? null : () => card.currentState?.fling(Dir.right)),
        ),
      ],
      const SizedBox(width: 6),
      Expanded(flex: 7, child: Btn('Later', onTap: s.queue.length <= g.length ? null : s.later)),
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
    this.onLongPress,
    this.onDrag,
    this.onDrop,
    this.keepLabel = 'Keep',
    this.trashLabel = 'Delete',
    this.disabled = false,
  });

  /// Changes when a new photo or burst comes up; the card starts fresh in the middle.
  final String cardId;
  final Widget child;
  /// [fx]: play the trace (buttons); a swipe already flew the card off.
  final Future<void> Function(Dir, bool fx) onSwipe;
  final VoidCallback? onTap;

  /// Full-size view (a press that doesn't move; moving first is a swipe).
  final VoidCallback? onLongPress;
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
  double _w = 0;
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
        final w = _w = box.maxWidth;
        final hint = _pos.dy.abs() > _pos.dx.abs() ? 0.0 : min(1.0, _pos.dx.abs() / 120);
        return GestureDetector(
          onTap: widget.onTap,
          onLongPress: _leaving ? null : widget.onLongPress,
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
              fling(_pos.dx > 0 ? Dir.right : Dir.left, fx: false);
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

  /// Reports the decision. A swipe ([fx] false) flies the card off first; the buttons settle it in place and the
  /// trace plays on the photo.
  Future<void> fling(Dir dir, {bool fx = true}) async {
    if (_leaving) return;
    _leaving = true;
    if (fx) {
      _animate(Offset.zero);
    } else {
      _from = _pos;
      _to = Offset((dir == Dir.right ? 1 : -1) * _w * 1.4, _pos.dy);
      await _anim.forward(from: 0);
    }
    await widget.onSwipe(dir, fx);
    if (!mounted) return;
    if (fx) return reset();
    _anim.stop();
    setState(() {
      _pos = Offset.zero;
      _leaving = false;
    });
  }

  void reset() {
    _leaving = false;
    _animate(Offset.zero);
  }
}

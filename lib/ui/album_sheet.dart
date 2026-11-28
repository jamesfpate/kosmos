import 'dart:math';

import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import 'common.dart';

// The date prefix is added automatically; flag names that start with a year, month or YYYY-MM anyway.
final _dateStart = RegExp(
  r'^\s*((19|20)\d\d([-/. ]\d{1,2})?|jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?)\b[\s,.-]*',
  caseSensitive: false,
);

/// New album: optional dates (start = the photo's day), a fixed YYYY-MM prefix, and the name.
/// [photoDate] null: no photo chosen yet, so a dated album takes its date from the first photo filed into it.
/// With [existing]: edit that album (name, dates, end) instead. [name] starts the name field off.
Future<Album?> showAlbumSheet(BuildContext context, int? photoDate, {Album? existing, String? name}) =>
    showModalBottomSheet<Album>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _AlbumSheet(photoDate, existing, name),
    );

class _AlbumSheet extends StatefulWidget {
  const _AlbumSheet(this.photoDate, this.existing, this.name);

  final int? photoDate;
  final Album? existing;
  final String? name;

  @override
  State<_AlbumSheet> createState() => _AlbumSheetState();
}

class _AlbumSheetState extends State<_AlbumSheet> {
  bool dated = true;
  late DateTime start;
  DateTime? end;

  /// The name starts with the year ("2026 Kids school") rather than the month ("2026-07 Hawaii").
  bool byYear = false;
  final name = TextEditingController();

  Album? get existing => widget.existing;

  @override
  void initState() {
    super.initState();
    final e = existing;
    final d = DateTime.fromMillisecondsSinceEpoch(e?.start ?? widget.photoDate ?? DateTime.now().millisecondsSinceEpoch);
    start = DateTime(d.year, d.month, d.day);
    if (e != null) {
      name.text = e.name;
      dated = e.start != null || e.autoDate;
      byYear = e.yearly;
      if (e.end != null) {
        final x = DateTime.fromMillisecondsSinceEpoch(e.end!);
        end = DateTime(x.year, x.month, x.day);
      }
    }
    if (widget.name != null) name.text = widget.name!;
    name.addListener(() => setState(() {}));
  }

  bool get later => dated && (existing == null ? widget.photoDate == null : existing!.start == null && existing!.autoDate);
  String get prefix => !dated
      ? ''
      : later
          ? (byYear ? 'YYYY' : 'YYYY-MM')
          : (byYear ? '${start.year}' : monthPrefix(start.millisecondsSinceEpoch));
  bool get dateTyped => dated && _dateStart.hasMatch(name.text);
  bool get valid => name.text.trim().isNotEmpty;

  Future<void> pick(bool isStart) async {
    final d = await showDatePicker(
      context: context,
      initialDate: isStart ? start : (end ?? start),
      firstDate: isStart ? DateTime(1990) : start,
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      if (isStart) {
        start = d;
        if (end != null && end!.isBefore(start)) end = null;
      } else {
        end = d;
      }
    });
  }

  void create() {
    if (!valid) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final e = existing;
    Navigator.pop(
      context,
      Album(
        id: e?.id ?? newId(),
        name: name.text.trim(),
        start: dated && !later ? start.millisecondsSinceEpoch : null,
        end: dated && !later && end != null ? end!.millisecondsSinceEpoch + day - 1 : null,
        autoDate: later,
        yearly: dated && byYear,
        createdAt: e?.createdAt ?? now,
        // Not "used" until a photo goes in, so creating an album doesn't change the default.
        lastUsedAt: e?.lastUsedAt ?? 0,
        immichAlbumId: e?.immichAlbumId,
        googleAlbumId: e?.googleAlbumId,
        remoteIds: e?.remoteIds ?? const {},
        syncedTitles: e?.syncedTitles ?? const {},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = name.text.trim().isEmpty ? '…' : (prefix.isEmpty ? name.text.trim() : '$prefix ${name.text.trim()}');
    final laterNote = later ? ' (the date comes from the first photo you put in)' : '';
    Widget dateField(String label, DateTime? d, bool isStart) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 4),
            OutlinedButton(
              onPressed: () => pick(isStart),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44), side: const BorderSide(color: C.line)),
              child: Text(d == null ? 'Ongoing' : fmtDay.format(d), style: const TextStyle(color: C.text)),
            ),
          ]),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(existing == null ? 'New album' : 'Edit album', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Dates'),
          value: dated,
          activeThumbColor: C.accent,
          onChanged: (v) => setState(() => dated = v),
        ),
        if (later)
          const Text('No photo chosen yet: the date comes from the first photo you put in.', style: TextStyle(color: C.muted, fontSize: 13))
        else if (dated) ...[
          Row(children: [dateField('Start', start, true), const SizedBox(width: 10), dateField('End', end, false)]),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (end != null) TextButton(onPressed: () => setState(() => end = null), child: const Text('Ongoing')),
            // Closes an ongoing album: later photos stop being suggested into it.
            TextButton(
              onPressed: () => setState(() {
                final t = DateTime.now();
                end = DateTime(t.year, t.month, t.day);
                if (end!.isBefore(start)) end = start;
              }),
              child: const Text('End today'),
            ),
          ]),
          const SizedBox(height: 6),
          const Text("Photos taken between these dates are suggested into this album. Leave End empty while it's ongoing.",
              style: TextStyle(color: C.muted, fontSize: 13)),
        ],
        const SizedBox(height: 10),
        Row(children: [
          // The date the name starts with: the month (2026-07) or just the year (2026). Tap to switch.
          if (prefix.isNotEmpty) ...[
            Container(
              decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.all(3),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final year in [false, true])
                  GestureDetector(
                    onTap: () => setState(() => byYear = year),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
                      decoration: BoxDecoration(color: byYear == year ? C.surface : null, borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        later
                            ? (year ? 'YYYY' : 'YYYY-MM')
                            : (year ? '${start.year}' : monthPrefix(start.millisecondsSinceEpoch)),
                        style: TextStyle(color: byYear == year ? C.text : C.muted, fontWeight: byYear == year ? FontWeight.w600 : null),
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: TextField(
              controller: name,
              autofocus: existing == null,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => create(),
              decoration: InputDecoration(
                hintText: dated ? 'Hawaii' : 'Kids school',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                isDense: true,
              ),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        if (dateTyped)
          Row(children: [
            const Expanded(child: Text('The date is added for you.', style: TextStyle(color: Color(0xFFFBBF24), fontSize: 13))),
            TextButton(
              onPressed: () => name.text = name.text.replaceFirst(_dateStart, ''),
              child: const Text('Remove it from the name'),
            ),
          ])
        else
          Text(
            dated
                ? 'Name only, the date is added for you.'
                : 'No dates: for things that span years (Kids school). Yearly events like Thanksgiving should keep dates so each year is its own album.',
            style: const TextStyle(color: C.muted, fontSize: 13),
          ),
        const SizedBox(height: 8),
        Text.rich(TextSpan(text: 'Album: ', children: [
          TextSpan(text: preview, style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: laterNote, style: const TextStyle(color: C.muted)),
        ])),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Btn('Cancel', onTap: () => Navigator.pop(context))),
          const SizedBox(width: 8),
          Expanded(child: Btn(existing == null ? 'Create' : 'Save', bold: true, color: C.bg, bg: C.accent, onTap: valid ? create : null)),
        ]),
      ]),
    );
  }
}

/// Edits an album (month albums follow their month and can't be edited).
Future<void> editAlbum(BuildContext context, AppState s, Album a) async {
  if (a.monthly || a.id == monthAlbumId) {
    toast(context, 'Month albums are named after their month');
    return;
  }
  final updated = await showAlbumSheet(context, null, existing: a);
  if (updated != null) await s.updateAlbum(a, updated);
}

/// Opens the sheet and creates the album (filing into it right after when asked).
Future<void> newAlbum(BuildContext context, AppState s, int? photoDate,
    {bool fileAfter = false, bool grid = false, String? name}) async {
  final a = await showAlbumSheet(context, photoDate, name: name);
  if (a != null) await s.createAlbum(a, fileAfter: fileAfter, grid: grid);
}

/// The album bar, two rows. Top: search, the photo's month album and + New. Below: the other albums (chosen first,
/// then date matches, then by last use). Typing in search drops a list of matching albums over the photo, with a
/// "New album" entry when nothing has that name; picking one closes it.
class AlbumBar extends StatefulWidget {
  const AlbumBar({
    super.key,
    required this.albums,
    required this.label,
    required this.isTarget,
    required this.onPick,
    required this.onEdit,
    required this.onNew,
    required this.focus,
    this.newLabel = '+ New',
    this.chipKey,
    this.hover,
    this.more = const [],
  });

  /// Every album in bar order; the month album goes on the top row.
  final List<Album> albums;

  /// Found by search only (albums from integrations not used yet).
  final List<Album> more;
  final String Function(Album) label;
  final bool Function(Album) isTarget;
  final void Function(Album) onPick;
  final void Function(Album) onEdit;

  /// New album, named from the search when there is one; null when there's nothing to file.
  final void Function(String? name)? onNew;
  final String newLabel;

  /// The search field's focus (the swipe screen turns its keyboard shortcuts off while it's typing).
  final FocusNode focus;

  /// Keys for the chips, so a photo can be dragged onto one ('new' is + New).
  final GlobalKey Function(String id)? chipKey;
  final String? hover;

  @override
  State<AlbumBar> createState() => _AlbumBarState();
}

class _AlbumBarState extends State<AlbumBar> {
  final query = TextEditingController();

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  List<Object> hits(String text) {
    final typed = text.trim();
    if (typed.isEmpty) return const [];
    final words = typed.toLowerCase().split(RegExp(r'\s+'));
    final found = [
      for (final a in [...widget.albums, ...widget.more.where((m) => !widget.albums.any((a) => a.id == m.id))])
        if (words.every(widget.label(a).toLowerCase().contains)) a,
    ];
    final exact = found.any((a) => a.name.toLowerCase() == typed.toLowerCase() || widget.label(a).toLowerCase() == typed.toLowerCase());
    return [...found, if (!exact && widget.onNew != null) typed];
  }

  void picked(Object o) {
    query.clear();
    widget.focus.unfocus();
    o is Album ? widget.onPick(o) : widget.onNew?.call(o as String);
  }

  Widget chip(Album a) => AlbumChip(
        key: widget.chipKey?.call(a.id),
        label: widget.label(a),
        target: widget.isTarget(a),
        hover: widget.hover == a.id,
        onTap: () => widget.onPick(a),
        onLongPress: () => widget.onEdit(a),
      );

  @override
  Widget build(BuildContext context) {
    final month = widget.albums.where((a) => a.monthly).firstOrNull;
    final rest = widget.albums.where((a) => !a.monthly).toList();
    return Column(children: [
      SizedBox(
        height: 44,
        child: Row(children: [
          Expanded(child: _search(context)),
          if (month != null) ...[const SizedBox(width: 6), chip(month)],
          const SizedBox(width: 6),
          AlbumChip(
            key: widget.chipKey?.call('new'),
            label: widget.newLabel,
            dashed: true,
            hover: widget.hover == 'new',
            onTap: widget.onNew == null ? null : () => widget.onNew!(null),
          ),
        ]),
      ),
      if (rest.isNotEmpty) ...[
        const SizedBox(height: 6),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final a in rest) Padding(padding: const EdgeInsets.only(right: 6), child: chip(a)),
          ]),
        ),
      ],
    ]);
  }

  Widget _search(BuildContext context) => RawAutocomplete<Object>(
        textEditingController: query,
        focusNode: widget.focus,
        optionsBuilder: (v) => hits(v.text),
        displayStringForOption: (_) => '',
        onSelected: picked,
        fieldViewBuilder: (context, controller, focus, submit) => TextField(
          controller: controller,
          focusNode: focus,
          onSubmitted: (_) => submit(),
          onTapOutside: (_) => focus.unfocus(),
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Search albums',
            prefixIcon: const Icon(Icons.search, size: 20),
            prefixIconConstraints: const BoxConstraints(minWidth: 36),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      controller.clear();
                      focus.unfocus();
                    }),
            filled: true,
            fillColor: C.surface,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: C.line)),
            enabledBorder:
                OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: C.line)),
          ),
        ),
        optionsViewBuilder: (context, onSelected, options) {
          final list = options.toList();
          final hi = AutocompleteHighlightedOption.of(context);
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              color: C.surface,
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: 320, maxWidth: min(420, MediaQuery.sizeOf(context).width - 32)),
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final o = list[i];
                    final a = o is Album ? o : null;
                    return ListTile(
                      dense: true,
                      selected: i == hi,
                      selectedTileColor: C.line,
                      leading: Icon(
                          a == null
                              ? Icons.add
                              : a.monthly
                                  ? Icons.calendar_month
                                  : (a.start == null ? Icons.label_outline : Icons.photo_album_outlined),
                          color: a == null ? C.accent : C.muted),
                      title: Text(a == null ? 'New album “$o”' : widget.label(a),
                          style: TextStyle(color: a == null ? C.accent : C.text)),
                      onTap: () => onSelected(o),
                    );
                  },
                ),
              ),
            ),
          );
        },
      );
}

/// Picks an album (searchable), e.g. where to move a whole album to.
Future<Album?> pickAlbum(BuildContext context, List<Album> albums, {required String title}) => showModalBottomSheet<Album>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _PickAlbum(albums, title),
    );

class _PickAlbum extends StatefulWidget {
  const _PickAlbum(this.albums, this.title);

  final List<Album> albums;
  final String title;

  @override
  State<_PickAlbum> createState() => _PickAlbumState();
}

class _PickAlbumState extends State<_PickAlbum> {
  final query = TextEditingController();

  @override
  void initState() {
    super.initState();
    query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final words = query.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final found = [
      for (final a in widget.albums)
        if (words.every(albumTitle(a).toLowerCase().contains)) a,
    ]..sort((a, b) => albumTitle(a).toLowerCase().compareTo(albumTitle(b).toLowerCase()));
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 12),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          TextField(
            controller: query,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Search albums',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(children: [
              for (final a in found)
                ListTile(
                  dense: true,
                  leading: Icon(a.monthly ? Icons.calendar_month : Icons.photo_album_outlined, color: C.muted),
                  title: Text(albumTitle(a)),
                  onTap: () => Navigator.pop(context, a),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

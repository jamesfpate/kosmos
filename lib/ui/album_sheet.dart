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
      if (e.end != null) {
        final x = DateTime.fromMillisecondsSinceEpoch(e.end!);
        end = DateTime(x.year, x.month, x.day);
      }
    }
    if (widget.name != null) name.text = widget.name!;
    name.addListener(() => setState(() {}));
  }

  bool get later => dated && (existing == null ? widget.photoDate == null : existing!.start == null && existing!.autoDate);
  String get prefix => !dated ? '' : (later ? 'YYYY-MM' : monthPrefix(start.millisecondsSinceEpoch));
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
          const Text('No photo chosen yet: the YYYY-MM comes from the first photo you put in.', style: TextStyle(color: C.muted, fontSize: 13))
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
          if (prefix.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(10)),
              child: Text(prefix, style: const TextStyle(color: C.muted)),
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

/// What the album search chose: an album, or a name to start a new one with.
typedef Found = ({Album? album, String? create});

/// Album search: every album in [albums] (already in bar order), narrowed as you type; each word has to appear in the
/// title. With no exact match, the typed text can start a new album.
Future<Found?> findAlbum(BuildContext context, List<Album> albums, {String Function(Album)? label}) =>
    showModalBottomSheet<Found>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _FindAlbum(albums, label ?? albumTitle),
    );

class _FindAlbum extends StatefulWidget {
  const _FindAlbum(this.albums, this.label);

  final List<Album> albums;
  final String Function(Album) label;

  @override
  State<_FindAlbum> createState() => _FindAlbumState();
}

class _FindAlbumState extends State<_FindAlbum> {
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

  List<Album> get hits {
    final words = query.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    return [
      for (final a in widget.albums)
        if (words.every(albumTitle(a).toLowerCase().contains)) a,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final found = hits;
    final typed = query.text.trim();
    final exact = found.any((a) => a.name.toLowerCase() == typed.toLowerCase() || albumTitle(a).toLowerCase() == typed.toLowerCase());
    final h = MediaQuery.sizeOf(context).height;
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.viewInsetsOf(context).bottom + 12),
      child: SizedBox(
        height: h * 0.6,
        child: Column(children: [
          TextField(
            controller: query,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (found.isNotEmpty) {
                Navigator.pop(context, (album: found.first, create: null));
              } else if (typed.isNotEmpty) {
                Navigator.pop(context, (album: null, create: typed));
              }
            },
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
                  leading: Icon(a.monthly ? Icons.calendar_month : (a.start == null ? Icons.label_outline : Icons.photo_album_outlined),
                      color: C.muted),
                  title: Text(widget.label(a)),
                  onTap: () => Navigator.pop(context, (album: a, create: null)),
                ),
              if (typed.isNotEmpty && !exact)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add, color: C.accent),
                  title: Text('New album “$typed”', style: const TextStyle(color: C.accent)),
                  onTap: () => Navigator.pop(context, (album: null, create: typed)),
                ),
              if (found.isEmpty && typed.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Text('No albums yet', style: TextStyle(color: C.muted))),
            ]),
          ),
        ]),
      ),
    );
  }
}

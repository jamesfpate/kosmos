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
Future<Album?> showAlbumSheet(BuildContext context, int photoDate) => showModalBottomSheet<Album>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _AlbumSheet(photoDate),
    );

class _AlbumSheet extends StatefulWidget {
  const _AlbumSheet(this.photoDate);

  final int photoDate;

  @override
  State<_AlbumSheet> createState() => _AlbumSheetState();
}

class _AlbumSheetState extends State<_AlbumSheet> {
  bool dated = true;
  late DateTime start;
  DateTime? end;
  final name = TextEditingController();

  @override
  void initState() {
    super.initState();
    final d = DateTime.fromMillisecondsSinceEpoch(widget.photoDate);
    start = DateTime(d.year, d.month, d.day);
    name.addListener(() => setState(() {}));
  }

  String get prefix => dated ? monthPrefix(start.millisecondsSinceEpoch) : '';
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
    Navigator.pop(
      context,
      Album(
        id: newId(),
        name: name.text.trim(),
        start: dated ? start.millisecondsSinceEpoch : null,
        end: dated && end != null ? end!.millisecondsSinceEpoch + day - 1 : null,
        createdAt: now,
        // Not "used" until a photo goes in, so creating an album doesn't change the default.
        lastUsedAt: 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = name.text.trim().isEmpty ? '…' : (prefix.isEmpty ? name.text.trim() : '$prefix ${name.text.trim()}');
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
        const Text('New album', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Dates'),
          value: dated,
          activeThumbColor: C.accent,
          onChanged: (v) => setState(() => dated = v),
        ),
        if (dated) ...[
          Row(children: [dateField('Start', start, true), const SizedBox(width: 10), dateField('End', end, false)]),
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
              autofocus: true,
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
        Text.rich(TextSpan(text: 'Album: ', children: [TextSpan(text: preview, style: const TextStyle(fontWeight: FontWeight.w700))])),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Btn('Cancel', onTap: () => Navigator.pop(context))),
          const SizedBox(width: 8),
          Expanded(child: Btn('Create', bold: true, color: C.bg, bg: C.accent, onTap: valid ? create : null)),
        ]),
      ]),
    );
  }
}

/// Opens the sheet and creates the album (filing into it right after when asked).
Future<void> newAlbum(BuildContext context, AppState s, int photoDate, {bool fileAfter = false, bool grid = false}) async {
  final a = await showAlbumSheet(context, photoDate);
  if (a != null) await s.createAlbum(a, fileAfter: fileAfter, grid: grid);
}

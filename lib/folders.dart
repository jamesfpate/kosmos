import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:winnow_native/winnow_native.dart';

import 'db.dart';
import 'media.dart';
import 'models.dart';

// On a computer: the photos and videos in the folders the user picked. What a file needs reading for (when it was
// taken, its size, a video's length) is cached in the `files` table by path, and read again when its size or
// modification time changes.

const _table = 'files';

/// Folders never worth walking: hidden ones, the Photos app's library, NAS thumbnail and recycle folders.
bool _skipDir(String name) =>
    name.startsWith('.') ||
    name.endsWith('.photoslibrary') ||
    name == '@eaDir' ||
    name == '#recycle' ||
    name == r'$RECYCLE.BIN' ||
    name == 'node_modules';

Future<List<String>> _walk(String root) async {
  final out = <String>[];
  final dirs = [Directory(root)];
  while (dirs.isNotEmpty) {
    final dir = dirs.removeLast();
    try {
      await for (final e in dir.list(followLinks: false)) {
        final name = p.basename(e.path);
        if (e is Directory) {
          if (!_skipDir(name)) dirs.add(e);
        } else if (e is File && !name.startsWith('.') && isMediaPath(name)) {
          out.add(e.path);
        }
      }
    } on FileSystemException {
      // Unreadable folder: skip it.
    }
  }
  return out;
}

/// Every photo and video under [roots], oldest first.
Future<List<Item>> scanFolders(List<String> roots, Db db, {void Function(String status)? onProgress}) async {
  final cache = {for (final j in await db.all(_table)) j['id'] as String: j};
  final paths = <String>{};
  for (final r in roots) {
    onProgress?.call('Looking in ${p.basename(r)}…');
    paths.addAll(await _walk(r));
  }
  final stats = <String, FileStat>{};
  final stale = <String>[];
  for (final f in paths) {
    final st = await FileStat.stat(f);
    stats[f] = st;
    final c = cache[f];
    if (c == null || c['size'] != st.size || c['mtime'] != st.modified.millisecondsSinceEpoch) stale.add(f);
  }
  // Read what's new or changed, in batches.
  for (var i = 0; i < stale.length; i += 40) {
    onProgress?.call('Reading photos… $i of ${stale.length}');
    final batch = stale.sublist(i, min(i + 40, stale.length));
    final probed = await _probe(batch);
    final rows = <String, Object?>{};
    for (final (j, f) in batch.indexed) {
      final st = stats[f]!;
      final row = {
        'id': f,
        'size': st.size,
        'mtime': st.modified.millisecondsSinceEpoch,
        ...?probed[j],
      };
      cache[f] = row;
      rows[f] = row;
    }
    await db.putAll(_table, rows);
  }
  final gone = cache.keys.where((f) => !paths.contains(f)).toList();
  if (gone.isNotEmpty) await db.removeAll(_table, gone);

  final out = <Item>[];
  for (final f in paths) {
    final c = cache[f]!;
    out.add(Item.file(
      f,
      taken: _taken(f, (c['taken'] as num?)?.toInt(), c['mtime'] as int),
      bucket: p.basename(p.dirname(f)),
      width: (c['w'] as num?)?.toInt() ?? 0,
      height: (c['h'] as num?)?.toInt() ?? 0,
      duration: (c['dur'] as num?)?.toInt() ?? 0,
    ));
  }
  out.sort((a, b) => a.taken.compareTo(b.taken));
  return out;
}

/// The camera's date; else a date in the file name; else when the file was last modified (copies keep that).
/// As on the phone, a name date more than a day and a half from the camera's wins (a misset clock).
int _taken(String path, int? exif, int mtime) {
  final fromName = dateFromName(p.basename(path));
  if (exif == null) return fromName ?? mtime;
  if (fromName != null && (fromName - exif).abs() > 36 * 60 * 60 * 1000) return fromName;
  return exif;
}

Future<List<Map<String, Object?>?>> _probe(List<String> paths) async {
  if (Platform.isMacOS) {
    try {
      return await WinnowNative.probe(paths);
    } catch (_) {}
  }
  return [for (final f in paths) await _probeDart(f)];
}

/// Without the Mac's decoders: EXIF from the start of the file (JPEG, HEIC, TIFF-based RAW), else the image header.
Future<Map<String, Object?>?> _probeDart(String path) async {
  if (isVideoPath(path)) return {'dur': 0};
  Uint8List head;
  try {
    final raf = await File(path).open();
    head = await raf.read(512 * 1024);
    await raf.close();
  } catch (_) {
    return null;
  }
  final out = <String, Object?>{'dur': 0};
  try {
    final tags = await readExifFromBytes(head);
    final raw = (tags['EXIF DateTimeOriginal'] ?? tags['EXIF DateTimeDigitized'] ?? tags['Image DateTime'])?.printable;
    final t = raw == null ? null : _exifDate(raw);
    if (t != null) out['taken'] = t;
    var w = int.tryParse(tags['EXIF ExifImageWidth']?.printable ?? '') ?? 0;
    var h = int.tryParse(tags['EXIF ExifImageLength']?.printable ?? '') ?? 0;
    final o = tags['Image Orientation']?.values.firstAsInt() ?? 1;
    if (w > 0 && h > 0) {
      if (o >= 5) (w, h) = (h, w);
      out['w'] = w;
      out['h'] = h;
      return out;
    }
  } catch (_) {}
  try {
    final buf = await ui.ImmutableBuffer.fromUint8List(head);
    final d = await ui.ImageDescriptor.encoded(buf);
    out['w'] = d.width;
    out['h'] = d.height;
    d.dispose();
    buf.dispose();
  } catch (_) {}
  return out;
}

/// EXIF "2024:10:05 12:34:56" in local time.
int? _exifDate(String s) {
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})').firstMatch(s.trim());
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
  if (v[0] < 1900 || v[1] < 1) return null;
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]).millisecondsSinceEpoch;
}

/// Moves files to the computer's trash. Returns the paths moved.
Future<Set<String>> trashFiles(List<String> paths) async {
  if (Platform.isMacOS) return (await WinnowNative.trash(paths)).toSet();
  if (Platform.isWindows) {
    // The Recycle Bin, through .NET (no Dart API); a few dozen per PowerShell run keeps the command short.
    for (var i = 0; i < paths.length; i += 40) {
      final cmds = [
        for (final f in paths.sublist(i, min(i + 40, paths.length)))
          "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('${f.replaceAll("'", "''")}', 'OnlyErrorDialogs', 'SendToRecycleBin')",
      ];
      await Process.run('powershell', ['-NoProfile', '-Command', 'Add-Type -AssemblyName Microsoft.VisualBasic; ${cmds.join('; ')}']);
    }
  } else {
    for (final f in paths) {
      final r = await Process.run('gio', ['trash', f]);
      if (r.exitCode != 0) await _homeTrash(f);
    }
  }
  return {for (final f in paths) if (!await File(f).exists()) f};
}

/// The desktop's trash folder (freedesktop.org spec), for when gio can't (another drive with no trash of its own):
/// the file moves (or is copied, across drives) into ~/.local/share/Trash with the note file managers restore from.
Future<void> _homeTrash(String path) async {
  try {
    final data = Platform.environment['XDG_DATA_HOME'] ?? p.join(Platform.environment['HOME'] ?? '', '.local', 'share');
    final files = Directory(p.join(data, 'Trash', 'files'));
    final info = Directory(p.join(data, 'Trash', 'info'));
    await files.create(recursive: true);
    await info.create(recursive: true);
    var name = p.basename(path);
    for (var n = 2; await File(p.join(files.path, name)).exists(); n++) {
      name = '${p.basenameWithoutExtension(path)}.$n${p.extension(path)}';
    }
    final now = DateTime.now().toIso8601String().substring(0, 19);
    await File(p.join(info.path, '$name.trashinfo'))
        .writeAsString('[Trash Info]\nPath=${Uri.file(path).path}\nDeletionDate=$now\n');
    final dest = p.join(files.path, name);
    try {
      await File(path).rename(dest);
    } on FileSystemException {
      await File(path).copy(dest);
      await File(path).delete();
    }
  } catch (_) {
    // Left in place: it stays listed and comes back for review.
  }
}

/// Encoded thumbnail bytes for a file: the Mac's decoders make a real thumbnail; elsewhere the original's bytes
/// (decoded at the size asked for by the caller). Null for videos off the Mac.
Future<Uint8List?> fileThumbBytes(String path, int size) async {
  if (Platform.isMacOS) {
    try {
      return await WinnowNative.thumb(path, size);
    } catch (_) {
      return null;
    }
  }
  if (isVideoPath(path)) return null;
  return File(path).readAsBytes();
}

/// A file's thumbnail as an image, at most [size] px on its long side, kept in Flutter's image cache.
@immutable
class FileThumb extends ImageProvider<FileThumb> {
  const FileThumb(this.path, this.size);

  final String path;
  final int size;

  @override
  Future<FileThumb> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(FileThumb key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1, debugLabel: path);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await fileThumbBytes(path, size);
    if (bytes == null) throw StateError('No preview for ${p.basename(path)}');
    final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buf, getTargetSize: (w, h) {
      if (w <= size && h <= size) return ui.TargetImageSize(width: w, height: h);
      return w >= h ? ui.TargetImageSize(width: size) : ui.TargetImageSize(height: size);
    });
  }

  @override
  bool operator ==(Object other) => other is FileThumb && other.path == path && other.size == size;

  @override
  int get hashCode => Object.hash(path, size);
}

// Desktop checks on a real machine (CI runs it on macOS): the native metadata, thumbnail and Trash calls, and a
// folder scan. Samples come from SAMPLES (made by the workflow: a JPEG and HEIC dated 2024-10-05 12:34:56 with
// EXIF, 4000x3000, and a 3 s 640x360 MP4).
//   flutter test integration_test/desktop_test.dart -d macos --dart-define SAMPLES=/path

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:winnow/db.dart';
import 'package:winnow/folders.dart';
import 'package:winnow_native/winnow_native.dart';

const samples = String.fromEnvironment('SAMPLES');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final taken = DateTime(2024, 10, 5, 12, 34, 56).millisecondsSinceEpoch;

  Future<(int, int)> size(List<int> bytes) async {
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final img = (await codec.getNextFrame()).image;
    return (img.width, img.height);
  }

  testWidgets('probe reads size, date and length', (_) async {
    final r = await WinnowNative.probe([
      p.join(samples, 'photo.jpg'),
      p.join(samples, 'photo.heic'),
      p.join(samples, 'clip.mp4'),
      p.join(samples, 'missing.jpg'),
    ]);
    expect(r[0]!['w'], 4000);
    expect(r[0]!['h'], 3000);
    expect(r[0]!['taken'], taken);
    expect(r[1]!['w'], 4000);
    expect(r[1]!['taken'], taken);
    expect(r[2]!['dur'], 3);
    expect(r[2]!['w'], 640);
    expect(r[2]!['h'], 360);
    expect(r[3], isNull);
  });

  testWidgets('thumbnails for JPEG, HEIC and video', (_) async {
    for (final f in ['photo.jpg', 'photo.heic', 'clip.mp4']) {
      final bytes = await WinnowNative.thumb(p.join(samples, f), 256);
      expect(bytes, isNotNull, reason: f);
      final (w, h) = await size(bytes!);
      expect(w <= 256 && h <= 256 && (w == 256 || h == 256), isTrue, reason: '$f is ${w}x$h');
    }
  });

  testWidgets('folder scan uses EXIF dates and skips hidden files', (_) async {
    final db = await Db.open();
    final items = await scanFolders([samples], db);
    final names = {for (final i in items) p.basename(i.id)};
    expect(names, containsAll(['photo.jpg', 'photo.heic', 'clip.mp4']));
    expect(names.contains('.hidden.jpg'), isFalse);
    expect(items.firstWhere((i) => i.id.endsWith('photo.heic')).taken, taken);
    expect(items.firstWhere((i) => i.id.endsWith('clip.mp4')).duration, 3);
  });

  testWidgets('trash moves the file away', (_) async {
    final f = await File(p.join(samples, 'photo.jpg')).copy(p.join(samples, 'to-trash.jpg'));
    final moved = await trashFiles([f.path]);
    expect(moved, {f.path});
    expect(await f.exists(), isFalse);
  });
}

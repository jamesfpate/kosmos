import 'dart:io';

import 'package:exif/exif.dart';

import 'models.dart';

/// What the caption under a photo shows (Settings > Single > Photo info).
const infoChoices = [
  ('date', 'Date'),
  ('time', 'Time'),
  ('camera', 'Camera'),
  ('lens', 'Lens'),
  ('exposure', 'Exposure'),
  ('file', 'File name'),
  ('size', 'Size'),
  ('folder', 'Folder'),
];

/// The fields on (kept in step with the setting by AppState).
var infoFields = <String>{'date', 'time'};

/// What a photo's file says about it: its camera, lens and exposure (from EXIF) and its file size.
class PhotoInfo {
  const PhotoInfo({this.camera, this.lens, this.exposure, this.bytes});
  final String? camera;
  final String? lens;
  final String? exposure;
  final int? bytes;
}

final _cache = <String, Future<PhotoInfo>>{};

bool get infoNeedsFile => infoFields.any((f) => f == 'camera' || f == 'lens' || f == 'exposure' || f == 'size');

/// Reads a photo's info once (only the start of the file, where EXIF lives).
Future<PhotoInfo> infoFor(Item i) => _cache[i.id] ??= _read(i);

Future<PhotoInfo> _read(Item i) async {
  try {
    final File? f = i.path != null ? File(i.path!) : await i.entity?.originFile;
    if (f == null) return const PhotoInfo();
    final bytes = await f.length();
    if (i.isVideo) return PhotoInfo(bytes: bytes);
    final t = await readExifFromFile(f, details: false);
    String? s(String k) {
      final v = t[k]?.printable.trim();
      return v == null || v.isEmpty || v == '0' ? null : v;
    }

    double? n(String k) {
      final v = s(k);
      if (v == null) return null;
      final p = v.split('/');
      return p.length == 2 ? (double.tryParse(p[0]) ?? 0) / (double.tryParse(p[1]) ?? 1) : double.tryParse(v);
    }

    final make = s('Image Make'), model = s('Image Model');
    // "Canon Canon EOS R6" reads better as "Canon EOS R6".
    final camera = model == null ? make : (make != null && !model.toLowerCase().startsWith(make.split(' ').first.toLowerCase()) ? '$make $model' : model);
    final f2 = n('EXIF FNumber'), t2 = n('EXIF ExposureTime'), iso = s('EXIF ISOSpeedRatings'), mm = n('EXIF FocalLength');
    final shutter = t2 == null || t2 <= 0 ? null : (t2 >= 1 ? '${t2.toStringAsFixed(t2 < 10 ? 1 : 0)}s' : '1/${(1 / t2).round()}s');
    final exposure = [
      if (f2 != null && f2 > 0) 'ƒ/${f2.toStringAsFixed(f2 < 10 ? 1 : 0).replaceFirst(RegExp(r'\.0$'), '')}',
      ?shutter,
      if (iso != null) 'ISO $iso',
      if (mm != null && mm > 0) '${mm.round()}mm',
    ].join(' · ');
    return PhotoInfo(camera: camera, lens: s('EXIF LensModel'), exposure: exposure.isEmpty ? null : exposure, bytes: bytes);
  } catch (_) {
    return const PhotoInfo();
  }
}

String _size(int b) => b >= 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : '${(b / 1024).round()} KB';

/// The caption's two lines: when (date · time), then what (camera, lens, exposure, file, size, folder).
(String, String) captionLines(Item i, PhotoInfo? info, {required String day, required String time}) {
  final when = [if (infoFields.contains('date')) day, if (infoFields.contains('time')) time].join(' · ');
  final what = [
    if (infoFields.contains('camera') && info?.camera != null) info!.camera!,
    if (infoFields.contains('lens') && info?.lens != null) info!.lens!,
    if (infoFields.contains('exposure') && info?.exposure != null) info!.exposure!,
    if (infoFields.contains('file')) i.name,
    if (infoFields.contains('size')) [if (i.width > 0) '${i.width}×${i.height}', if (info?.bytes != null) _size(info!.bytes!)].join(' · '),
    if (infoFields.contains('folder') && i.bucket.isNotEmpty) i.bucket,
  ].where((x) => x.isNotEmpty).join(' · ');
  return (when, what);
}

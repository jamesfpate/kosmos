import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:winnow_native/winnow_native.dart';

import 'db.dart';
import 'folders.dart';
import 'models.dart';

/// On a computer Winnow reviews folders the user picks instead of a phone's photo library.
final desktop = Platform.isMacOS || Platform.isLinux || Platform.isWindows;

/// What to call the device in the UI.
final device = desktop ? 'computer' : 'phone';

enum Access { granted, limited, prompt, denied }

// Photos and videos, plus media location so uploads keep GPS (Android redacts it otherwise).
const _option = PermissionRequestOption(
  androidPermission: AndroidPermission(type: RequestType.common, mediaLocation: true),
);

Access _map(PermissionState s) => switch (s) {
      PermissionState.authorized => Access.granted,
      PermissionState.limited => Access.limited,
      PermissionState.notDetermined => Access.prompt,
      _ => Access.denied,
    };

Future<Access> getAccess() async => _map(await PhotoManager.getPermissionState(requestOption: _option));

Future<Access> requestAccess() async => _map(await PhotoManager.requestPermissionExtend(requestOption: _option));

Future<void> openSettings() => PhotoManager.openSetting();

/// Android's "media management" special access: trash without a confirm dialog each time.
Future<bool> canManageMedia() => WinnowNative.canManageMedia();

Future<void> openManageMedia() => WinnowNative.openManageMedia();

/// For the background task (no activity): don't ask Android for the permission state before each call.
Future<void> skipPermissionCheck() => PhotoManager.setIgnorePermissionCheck(true);

// YYYYMMDD, optionally _HHMMSS / -HHMMSS (PXL_20241005_123456789, IMG-20240827-WA0000, 20240827_123456).
final _nameDate = RegExp(r'(20\d{2})(\d{2})(\d{2})(?:[_-](\d{2})(\d{2})(\d{2}))?');

int? dateFromName(String? name) {
  final m = name == null ? null : _nameDate.firstMatch(name);
  if (m == null) return null;
  final mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final t = DateTime(int.parse(m[1]!), mo, d, int.parse(m[4] ?? '12'), int.parse(m[5] ?? '0'), int.parse(m[6] ?? '0'))
      .millisecondsSinceEpoch;
  return t <= DateTime.now().millisecondsSinceEpoch + day ? t : null;
}

/// When the photo was taken. Android reports DATE_TAKEN, or the date the file reached the phone when that's missing
/// (WhatsApp and copied files). A date in the file name that disagrees by more than a day and a half wins.
int _taken(AssetEntity e) {
  final t = e.createDateTime.millisecondsSinceEpoch;
  final fromName = dateFromName(e.title);
  if (fromName != null && (fromName - t).abs() > 36 * 60 * 60 * 1000) return fromName;
  return t;
}

String _bucket(AssetEntity e) {
  final rel = e.relativePath ?? '';
  final parts = rel.split('/').where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? '' : parts.last;
}

/// Every image and video on the device (or in [folders], on a computer), oldest first.
Future<List<Item>> loadItems(Db db, List<String> folders, {void Function(String status)? onProgress}) async {
  if (desktop) return scanFolders(folders, db, onProgress: onProgress);
  final paths = await PhotoManager.getAssetPathList(
    onlyAll: true,
    type: RequestType.common,
    filterOption: FilterOptionGroup(
      imageOption: const FilterOption(needTitle: true),
      videoOption: const FilterOption(needTitle: true),
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: true)],
    ),
  );
  if (paths.isEmpty) return [];
  final all = paths.first;
  final count = await all.assetCountAsync;
  final out = <Item>[];
  for (var i = 0; i < count; i += 1000) {
    final page = await all.getAssetListRange(start: i, end: i + 1000 > count ? count : i + 1000);
    for (final e in page) {
      out.add(Item(e, _taken(e), _bucket(e)));
    }
    onProgress?.call('Loading photos… ${out.length} of $count');
  }
  out.sort((a, b) => a.taken.compareTo(b.taken));
  return out;
}

/// Moves items to the system trash (Android 11+: one system confirm, recoverable for 30 days). Returns the ids moved.
Future<Set<String>> trash(List<Item> items) async {
  if (items.isEmpty) return {};
  if (desktop) return trashFiles([for (final i in items) i.path!]);
  final entities = [for (final i in items) i.entity!];
  final ids = Platform.isAndroid
      ? await PhotoManager.editor.android.moveToTrash(entities)
      : await PhotoManager.editor.deleteWithIds([for (final e in entities) e.id]);
  return ids.toSet();
}

/// A thumbnail at most [size] px on its long side (square crop on the phone, the photo's own shape on a computer).
ImageProvider thumbImage(Item item, int size) => item.entity != null
    ? AssetEntityImageProvider(item.entity!, isOriginal: false, thumbnailSize: ThumbnailSize.square(size))
    : FileThumb(item.path!, size);

/// Encoded thumbnail bytes about [w] x [h] (for the keep / delete trace).
Future<Uint8List?> thumbBytes(Item item, int w, int h) => item.entity != null
    ? item.entity!.thumbnailDataWithSize(ThumbnailSize(w, h))
    : fileThumbBytes(item.path!, w > h ? w : h);

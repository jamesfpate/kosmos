import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import 'models.dart';

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

// YYYYMMDD, optionally _HHMMSS / -HHMMSS (PXL_20241005_123456789, IMG-20240827-WA0000, 20240827_123456).
final _nameDate = RegExp(r'(20\d{2})(\d{2})(\d{2})(?:[_-](\d{2})(\d{2})(\d{2}))?');

int? _dateFromName(String? name) {
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
  final fromName = _dateFromName(e.title);
  if (fromName != null && (fromName - t).abs() > 36 * 60 * 60 * 1000) return fromName;
  return t;
}

String _bucket(AssetEntity e) {
  final rel = e.relativePath ?? '';
  final parts = rel.split('/').where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? '' : parts.last;
}

/// Every image and video on the device, oldest first.
Future<List<Item>> loadItems() async {
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
  for (var i = 0; i < count; i += 2000) {
    final page = await all.getAssetListRange(start: i, end: i + 2000 > count ? count : i + 2000);
    for (final e in page) {
      out.add(Item(e, _taken(e), _bucket(e)));
    }
  }
  out.sort((a, b) => a.taken.compareTo(b.taken));
  return out;
}

/// Moves items to the system trash (Android 11+: one system confirm, recoverable for 30 days). Returns the ids moved.
Future<Set<String>> trash(List<Item> items) async {
  if (items.isEmpty) return {};
  final entities = [for (final i in items) i.entity];
  final ids = Platform.isAndroid
      ? await PhotoManager.editor.android.moveToTrash(entities)
      : await PhotoManager.editor.deleteWithIds([for (final e in entities) e.id]);
  return ids.toSet();
}

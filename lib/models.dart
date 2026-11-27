import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

/// A photo or video: on the phone (a photo_manager [entity]) or, on a computer, a file at [path].
class Item {
  Item(AssetEntity this.entity, this.taken, this.bucket)
      : path = null,
        width = entity.orientatedWidth,
        height = entity.orientatedHeight,
        duration = entity.duration;

  Item.file(String this.path, {required this.taken, required this.bucket, this.width = 0, this.height = 0, this.duration = 0})
      : entity = null;

  final AssetEntity? entity;
  final String? path;

  /// When it was taken, epoch ms (see media.dart and folders.dart for the fallbacks).
  final int taken;

  /// Folder it lives in ("Camera", "WhatsApp Images", ...); '' when unknown.
  final String bucket;

  /// Size as displayed (0 when unknown); a video's length in seconds.
  final int width, height, duration;

  String get id => entity?.id ?? path!;
  bool get isVideo => entity != null ? entity!.type == AssetType.video : isVideoPath(path!);
  String get name => entity != null ? entity!.title ?? '$id${isVideo ? '.mp4' : '.jpg'}' : p.basename(path!);

  String? get mimeType => entity != null ? entity!.mimeType : mimeFor(path!);

  /// The original file, for upload. On the phone a cached copy ([clearFileCache] drops them).
  Future<File?> file() async => entity != null ? entity!.originFile : File(path!);

  /// The file to play a video from.
  Future<File?> playable() async => entity != null ? entity!.file : File(path!);

  /// Display aspect (width / height), clamped so panoramas and odd sizes stay usable in a grid.
  double get aspect {
    if (width <= 0 || height <= 0) return 3 / 4;
    return (width / height).clamp(0.4, 2.5);
  }
}

/// Drops the copies [Item.file] made on the phone.
void clearFileCache() {
  if (Platform.isAndroid || Platform.isIOS) PhotoManager.clearFileCache();
}

const imageTypes = {'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif', 'tif', 'tiff', 'avif', 'dng', 'cr2', 'cr3', 'nef', 'arw', 'raf', 'orf', 'rw2'};
const videoTypes = {'mp4', 'mov', 'm4v', '3gp', 'avi', 'mkv', 'mts', 'm2ts', 'webm'};

String _ext(String path) => p.extension(path).replaceFirst('.', '').toLowerCase();

bool isVideoPath(String path) => videoTypes.contains(_ext(path));

bool isMediaPath(String path) => imageTypes.contains(_ext(path)) || videoTypes.contains(_ext(path));

String? mimeFor(String path) => switch (_ext(path)) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'tif' || 'tiff' => 'image/tiff',
      'avif' => 'image/avif',
      'dng' => 'image/x-adobe-dng',
      'mp4' || 'm4v' => 'video/mp4',
      'mov' => 'video/quicktime',
      '3gp' => 'video/3gpp',
      'avi' => 'video/x-msvideo',
      'mkv' => 'video/x-matroska',
      'webm' => 'video/webm',
      'mts' || 'm2ts' => 'video/mp2t',
      _ => null,
    };

enum Decision { keep, pendingTrash, trash }

class DecisionRecord {
  DecisionRecord({required this.id, required this.decision, required this.decidedAt, this.albumId});

  final String id;
  final Decision decision;
  final int decidedAt;

  /// Album a kept photo was filed into.
  final String? albumId;

  Map<String, Object?> toJson() => {
        'id': id,
        'decision': switch (decision) {
          Decision.keep => 'keep',
          Decision.pendingTrash => 'pending_trash',
          Decision.trash => 'trash',
        },
        'decidedAt': decidedAt,
        if (albumId != null) 'albumId': albumId,
      };

  static DecisionRecord fromJson(Map<String, Object?> j) => DecisionRecord(
        id: '${j['id']}',
        decision: switch (j['decision']) {
          'keep' => Decision.keep,
          'trash' => Decision.trash,
          _ => Decision.pendingTrash,
        },
        decidedAt: (j['decidedAt'] as num?)?.toInt() ?? 0,
        albumId: j['albumId'] as String?,
      );
}

/// One concept: an album, optionally with dates. Dated albums are named "YYYY-MM name"; month albums just "YYYY-MM".
class Album {
  Album({
    required this.id,
    required this.name,
    this.start,
    this.end,
    required this.createdAt,
    required this.lastUsedAt,
    this.monthly = false,
    this.immichAlbumId,
    this.googleAlbumId,
    this.remoteIds = const {},
    this.syncedTitles = const {},
    this.autoDate = false,
    this.staleTags = const [],
  });

  final String id;
  final String name;

  /// Start of the first day (local) for dated albums.
  int? start;

  /// End of the last day (local); open-ended while null.
  int? end;

  /// Dated, but made before any photo was chosen: [start] is set from the first photo filed into it.
  bool autoDate;

  /// Immich tags from before a rename that still need removing from its photos (done on the next sync).
  List<String> staleTags;
  final int createdAt;

  /// When a photo last went in (0 = never used; creating an album doesn't count).
  int lastUsedAt;

  /// The month's catch-all album (empty name, dates = the month), created on first use.
  final bool monthly;

  /// The matching Immich album, once created or found.
  String? immichAlbumId;

  /// The Google Photos album Winnow made for it.
  String? googleAlbumId;

  /// Its album in each album service (PhotoPrism, Synology Photos), by service key.
  Map<String, String> remoteIds;

  /// The title each album service (and Google, as 'google') last got for it: a different title now means a rename.
  Map<String, String> syncedTitles;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        if (start != null) 'start': start,
        if (end != null) 'end': end,
        'createdAt': createdAt,
        'lastUsedAt': lastUsedAt,
        if (monthly) 'monthly': true,
        if (immichAlbumId != null) 'immichAlbumId': immichAlbumId,
        if (googleAlbumId != null) 'googleAlbumId': googleAlbumId,
        if (remoteIds.isNotEmpty) 'remoteIds': remoteIds,
        if (syncedTitles.isNotEmpty) 'syncedTitles': syncedTitles,
        if (autoDate) 'autoDate': true,
        if (staleTags.isNotEmpty) 'staleTags': staleTags,
      };

  static Album fromJson(Map<String, Object?> j) => Album(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        start: (j['start'] as num?)?.toInt(),
        end: (j['end'] as num?)?.toInt(),
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        lastUsedAt: (j['lastUsedAt'] as num?)?.toInt() ?? 0,
        monthly: j['monthly'] == true || j['everyday'] == true,
        immichAlbumId: j['immichAlbumId'] as String?,
        googleAlbumId: j['googleAlbumId'] as String?,
        remoteIds: ((j['remoteIds'] as Map?) ?? {}).cast<String, String>(),
        syncedTitles: ((j['syncedTitles'] as Map?) ?? {}).cast<String, String>(),
        autoDate: j['autoDate'] == true,
        staleTags: ((j['staleTags'] as List?) ?? []).cast<String>(),
      );
}

/// A photo uploaded to Immich, and which Winnow album it was last filed into there.
class UploadRecord {
  UploadRecord({required this.id, required this.assetId, required this.uploadedAt, this.syncedAlbumId});

  final String id;
  final String assetId;
  final int uploadedAt;
  String? syncedAlbumId;

  Map<String, Object?> toJson() => {
        'id': id,
        'assetId': assetId,
        'uploadedAt': uploadedAt,
        if (syncedAlbumId != null) 'syncedAlbumId': syncedAlbumId,
      };

  static UploadRecord fromJson(Map<String, Object?> j) => UploadRecord(
        id: '${j['id']}',
        assetId: j['assetId'] as String,
        uploadedAt: (j['uploadedAt'] as num?)?.toInt() ?? 0,
        syncedAlbumId: j['syncedAlbumId'] as String?,
      );
}

String two(int n) => n.toString().padLeft(2, '0');

String monthPrefix(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${two(d.month)}';
}

String albumTitle(Album a) {
  if (a.start == null) return a.name;
  return a.name.isEmpty ? monthPrefix(a.start!) : '${monthPrefix(a.start!)} ${a.name}';
}

/// Immich tag: Albums/2026/11/Thanksgiving; undated Albums/Kids school; month albums Albums/2026/11.
String albumTag(Album a) {
  if (a.start == null) return 'Albums/${a.name}';
  final d = DateTime.fromMillisecondsSinceEpoch(a.start!);
  return ['Albums', '${d.year}', two(d.month), if (a.name.isNotEmpty) a.name].join('/');
}

int startOfMonth(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime(d.year, d.month).millisecondsSinceEpoch;
}

int endOfMonth(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime(d.year, d.month + 1).millisecondsSinceEpoch - 1;
}

const day = 24 * 60 * 60 * 1000;

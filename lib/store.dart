import 'models.dart';

// File stores (Backblaze B2, WebDAV / Nextcloud, S3-compatible, SFTP): kept photos are copied into the same folder
// layout, and move when their album changes. Each store is a [StoreDef]: its settings fields and how to talk to it.

/// A photo in a file store: where it is now ([fileId] is the store's id for it; path-based stores use the path), and
/// the album it was filed under (for stores that also keep albums, like Nextcloud Photos).
class FileRecord {
  FileRecord({required this.id, required this.fileId, required this.fileName, this.album});

  final String id;
  final String fileId;
  final String fileName;
  final String? album;

  Map<String, Object?> toJson() =>
      {'id': id, 'fileId': fileId, 'fileName': fileName, if (album != null) 'album': album};

  static FileRecord fromJson(Map<String, Object?> j) => FileRecord(
        id: '${j['id']}',
        fileId: j['fileId'] as String,
        fileName: j['fileName'] as String,
        album: j['album'] as String?,
      );
}

abstract class FileStore {
  /// Signs in / checks the connection. Returns a short description of where files go.
  Future<String> authorize();

  /// Uploads the original file to [path]. Returns the store's id for it.
  Future<String> upload(Item item, String path);

  /// Moves a file to [path]. Returns the new id.
  Future<String> move(FileRecord r, String path);

  /// Whether the file is still there (before freeing up space).
  Future<bool> exists(FileRecord r);

  /// After a photo was uploaded or moved into album [now] (it was in [before]): stores with albums file it there.
  Future<void> filed(FileRecord now, FileRecord? before) async {}

  /// End of a sync (e.g. remove albums left empty).
  Future<void> finish() async {}

  void close();
}

/// Settings of one file store: its own fields (keys, server, ...) plus the options every integration has.
class StoreConfig {
  const StoreConfig({
    this.fields = const {},
    this.folder = 'Photos/',
    this.enabled = false,
    this.wifiOnly = false,
    this.videos = true,
    this.background = 'off',
  });

  final Map<String, String> fields;

  /// Folder everything goes under.
  final String folder;
  final bool enabled;
  final bool wifiOnly;
  final bool videos;
  final String background;

  String operator [](String key) => fields[key] ?? '';

  StoreConfig copyWith({
    Map<String, String>? fields,
    String? folder,
    bool? enabled,
    bool? wifiOnly,
    bool? videos,
    String? background,
  }) =>
      StoreConfig(
        fields: fields ?? this.fields,
        folder: folder ?? this.folder,
        enabled: enabled ?? this.enabled,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        videos: videos ?? this.videos,
        background: background ?? this.background,
      );

  Map<String, Object?> toJson() => {
        ...fields,
        'folder': folder,
        'enabled': enabled,
        'wifiOnly': wifiOnly,
        'videos': videos,
        'background': background,
      };

  static const _own = {'folder', 'prefix', 'background'};

  static StoreConfig fromJson(Map<String, Object?>? j) => j == null
      ? const StoreConfig()
      : StoreConfig(
          fields: {
            for (final e in j.entries)
              if (e.value is String && !_own.contains(e.key)) e.key: e.value as String,
          },
          // B2 used to call it prefix.
          folder: (j['folder'] as String?) ?? (j['prefix'] as String?) ?? 'Photos/',
          enabled: j['enabled'] == true,
          wifiOnly: j['wifiOnly'] == true,
          videos: j['videos'] != false,
          background: (j['background'] as String?) ?? 'off',
        );
}

class FieldDef {
  const FieldDef(this.key, this.label, this.hint, {this.secret = false, this.url = false, this.lines = 1, this.optional = false});

  final String key;
  final String label;
  final String hint;
  final bool secret;
  final bool url;

  /// More than 1: a multi-line box (e.g. a private key).
  final int lines;
  final bool optional;
}

class StoreDef {
  const StoreDef({
    required this.key,
    required this.title,
    required this.label,
    required this.intro,
    required this.fields,
    required this.make,
    this.folderLabel = 'Folder',
  });

  /// Settings key, database table and error label.
  final String key;

  /// Shown in Settings and on its page.
  final String title;

  /// Short name for status and errors.
  final String label;
  final List<String> intro;
  final List<FieldDef> fields;
  final String folderLabel;

  /// [remember] saves a value into the store's settings (e.g. a server's host key, the first time).
  final FileStore Function(StoreConfig c, void Function(String key, String value) remember) make;

  bool ready(StoreConfig c) => fields.every((f) => f.optional || c[f.key].trim().isNotEmpty);
}

/// Where a photo filed into [album] goes: `folder/YYYY/YYYY-MM name/file` (dated) or `folder/Albums/name/file`.
String storePath(String folder, Album album, String fileName) {
  var p = folder.trim();
  if (p.isNotEmpty && !p.endsWith('/')) p = '$p/';
  final safe = albumTitle(album).replaceAll('/', '-').trim();
  final dir = album.start == null ? 'Albums/$safe' : '${DateTime.fromMillisecondsSinceEpoch(album.start!).year}/$safe';
  return '$p$dir/${fileName.replaceAll('/', '-')}';
}

/// Object-store key for a path (no leading slash).
String objectKey(String path) => path.replaceFirst(RegExp(r'^/+'), '');

/// Inserts a suffix before the extension: `IMG_1.jpg` -> `IMG_1_tag.jpg`.
String withSuffix(String path, String tag) {
  final dot = path.lastIndexOf('.');
  final slash = path.lastIndexOf('/');
  if (dot <= slash) return '${path}_$tag';
  return '${path.substring(0, dot)}_$tag${path.substring(dot)}';
}

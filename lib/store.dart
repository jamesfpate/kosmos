import 'models.dart';

// File stores (Backblaze B2, WebDAV): the same folder layout, and photos move when their album changes.

/// A photo in a file store: where it is now ([fileId] is the store's id for it; WebDAV uses the path).
class FileRecord {
  FileRecord({required this.id, required this.fileId, required this.fileName});

  final String id;
  final String fileId;
  final String fileName;

  Map<String, Object?> toJson() => {'id': id, 'fileId': fileId, 'fileName': fileName};

  static FileRecord fromJson(Map<String, Object?> j) =>
      FileRecord(id: '${j['id']}', fileId: j['fileId'] as String, fileName: j['fileName'] as String);
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

  void close();
}

/// Where a photo filed into [album] goes: `prefix/YYYY/YYYY-MM name/file` (dated) or `prefix/Albums/name/file`.
String storePath(String prefix, Album album, String fileName) {
  var p = prefix.trim();
  if (p.startsWith('/')) p = p.substring(1);
  if (p.isNotEmpty && !p.endsWith('/')) p = '$p/';
  final safe = albumTitle(album).replaceAll('/', '-').trim();
  final folder = album.start == null ? 'Albums/$safe' : '${DateTime.fromMillisecondsSinceEpoch(album.start!).year}/$safe';
  return '$p$folder/${fileName.replaceAll('/', '-')}';
}

/// Inserts a suffix before the extension: `IMG_1.jpg` -> `IMG_1_tag.jpg`.
String withSuffix(String path, String tag) {
  final dot = path.lastIndexOf('.');
  final slash = path.lastIndexOf('/');
  if (dot <= slash) return '${path}_$tag';
  return '${path.substring(0, dot)}_$tag${path.substring(dot)}';
}

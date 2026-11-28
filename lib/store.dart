import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'media.dart' as media;
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

/// Album-based services (PhotoPrism, Synology Photos): upload, then file into albums of the same names.
abstract class AlbumService {
  /// Signs in. Returns a short description of the account / server.
  Future<String> authorize();

  /// Uploads the original into the service, straight into [albumId] when it can. Returns the photo's id there.
  Future<String> upload(Item item, String albumId);

  /// The service's album for [title]: [known] (renamed to [title] if needed) when it still exists, else a new one.
  Future<String> ensureAlbum(String title, String? known);

  Future<void> add(String albumId, List<String> ids);
  Future<void> remove(String albumId, List<String> ids);
  Future<bool> exists(String id);

  /// The albums already there (made in the service's own app, or by an earlier install). Empty when it can't list them.
  Future<List<RemoteAlbum>> albums() async => const [];
  void close();
}

/// An album already in an integration: its id there, its title, and the dates of its first and last photo when known.
typedef RemoteAlbum = ({String id, String name, DateTime? start, DateTime? end});

/// A photo in an album service and the Winnow album it was last filed into there.
class AlbumRecord {
  AlbumRecord({required this.id, required this.remoteId, this.albumId});

  final String id;
  final String remoteId;
  String? albumId;

  Map<String, Object?> toJson() => {'id': id, 'remoteId': remoteId, if (albumId != null) 'albumId': albumId};

  static AlbumRecord fromJson(Map<String, Object?> j) =>
      AlbumRecord(id: '${j['id']}', remoteId: j['remoteId'] as String, albumId: j['albumId'] as String?);
}

/// A file already in a file store, from a folder listing. [path] is in the form [FileStore.upload] takes; [id] is what
/// [FileStore.upload] would have returned for it. The hashes are the store's own, when it keeps one (lowercase hex).
class RemoteFile {
  const RemoteFile(this.path, this.id, this.size, {this.sha1, this.md5, this.dropbox});

  final String path;
  final String id;
  final int size;
  final String? sha1;
  final String? md5;
  final String? dropbox;

  String get name => path.split('/').last;
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

  /// The files directly in folder [dir] (paths in the same form as [upload]'s), none when it doesn't exist yet.
  Future<List<RemoteFile>> list(String dir);

  /// The names of the folders directly in [dir], none when it doesn't exist (or the store can't list folders).
  Future<List<String>> folders(String dir) async => const [];

  /// The first [n] bytes of [f] (fewer if it's shorter).
  Future<Uint8List> head(RemoteFile f, int n);

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
    this.pullAlbums = true,
  });

  final Map<String, String> fields;

  /// Use the albums already there (made in its own app, or by hand): they become Winnow albums to file into.
  final bool pullAlbums;

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
    bool? pullAlbums,
  }) =>
      StoreConfig(
        fields: fields ?? this.fields,
        folder: folder ?? this.folder,
        enabled: enabled ?? this.enabled,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        videos: videos ?? this.videos,
        background: background ?? this.background,
        pullAlbums: pullAlbums ?? this.pullAlbums,
      );

  Map<String, Object?> toJson() => {
        ...fields,
        'pullAlbums': pullAlbums,
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
          pullAlbums: j['pullAlbums'] != false,
        );
}

class FieldDef {
  const FieldDef(this.key, this.label, this.hint,
      {this.secret = false, this.url = false, this.lines = 1, this.optional = false, this.hidden = false});

  final String key;
  final String label;
  final String hint;
  final bool secret;
  final bool url;

  /// More than 1: a multi-line box (e.g. a private key).
  final int lines;
  final bool optional;

  /// Kept in the settings but not shown (e.g. a sign-in's refresh token).
  final bool hidden;
}

/// What a sign-in flow can ask of the screen.
abstract class SignInUi {
  /// Show [code] to type in at [url] (opened for the user); the flow carries on by itself.
  Future<void> showCode(String code, String url);

  /// Open [url] and ask the user to paste the code it shows. Null if they cancel.
  Future<String?> askCode(String url);

  /// The flow ended (dismiss whatever [showCode] put up).
  void done();
}

class StoreDef {
  const StoreDef({
    required this.key,
    required this.title,
    required this.label,
    required this.intro,
    required this.fields,
    this.make,
    this.albums,
    this.signIn,
    this.available = true,
    this.folderLabel = 'Folder',
    this.library = false,
    this.device,
    this.backup = true,
  });

  /// Works on the device's own photo library (albums on the phone or Mac, nothing uploaded).
  final bool library;

  /// Which device library: 'apple' (offered when reviewing an Apple Photos library) or 'android'.
  final String? device;

  /// Holds a copy of the photos. False for Apple albums: they're the same photos, so Free up space doesn't count them.
  final bool backup;

  /// False when this build can't offer it (OneDrive/Dropbox without their app ids): hidden from Settings.
  final bool available;

  /// Sign-in flow (OneDrive, Dropbox) instead of typed credentials: returns the fields to save (tokens, account).
  final Future<Map<String, String>> Function(SignInUi ui)? signIn;

  /// Settings key, database table and error label.
  final String key;

  /// Shown in Settings and on its page.
  final String title;

  /// Short name for status and errors.
  final String label;
  final List<String> intro;
  final List<FieldDef> fields;
  final String folderLabel;

  /// A folder-based store's client. [remember] saves a value into its settings (e.g. a server's host key).
  final FileStore Function(StoreConfig c, void Function(String key, String value) remember)? make;

  /// An album-based service's client (instead of [make]).
  final AlbumService Function(StoreConfig c, void Function(String key, String value) remember)? albums;

  bool get isAlbums => albums != null;

  /// Signs in / checks the connection, whichever kind it is.
  Future<String> test(StoreConfig c, void Function(String, String) remember) async {
    if (albums != null) {
      final a = albums!(c, remember);
      try {
        return await a.authorize();
      } finally {
        a.close();
      }
    }
    final f = make!(c, remember);
    try {
      return await f.authorize();
    } finally {
      f.close();
    }
  }

  /// Can be used here: its build settings are in and it fits what's being reviewed.
  bool get offered =>
      available &&
      switch (device) {
        'apple' => media.appleLibrary,
        'android' => Platform.isAndroid,
        _ => true,
      };

  bool ready(StoreConfig c) => offered && fields.every((f) => f.optional || c[f.key].trim().isNotEmpty);
}

/// Where a photo filed into [album] goes: `folder/YYYY/YYYY-MM name/file` (dated) or `folder/Albums/name/file`.
String storePath(String folder, Album album, String fileName) {
  var p = folder.trim();
  if (p.isNotEmpty && !p.endsWith('/')) p = '$p/';
  final safe = albumTitle(album).replaceAll('/', '-').trim();
  // A year's catch-all is the year folder itself, next to that year's event folders.
  final dir = album.start == null
      ? 'Albums/$safe'
      : (album.monthly && album.yearly ? safe : '${DateTime.fromMillisecondsSinceEpoch(album.start!).year}/$safe');
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

/// A short tag for [id] to tell apart two photos with the same name (ids can be long, or paths on a computer).
String clashTag(String id) => RegExp(r'^[A-Za-z0-9]{1,12}$').hasMatch(id) ? id : '${sha1.convert(id.codeUnits)}'.substring(0, 8);

/// The folder part of a store path (no trailing slash).
String dirOf(String path) => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

/// The first [n] bytes of a stream; stops reading (and cancels it) once it has them.
Future<Uint8List> takeBytes(Stream<List<int>> s, int n) async {
  final b = BytesBuilder(copy: false);
  await for (final c in s) {
    b.add(c);
    if (b.length >= n) break;
  }
  final out = b.takeBytes();
  return out.length > n ? Uint8List.sublistView(out, 0, n) : out;
}

/// Dropbox's content hash: SHA-256 of the SHA-256s of each 4 MB block.
Future<String> dropboxHash(File f) async {
  final blocks = <int>[];
  final raf = await f.open();
  try {
    while (true) {
      final b = await raf.read(4 * 1024 * 1024);
      if (b.isEmpty) break;
      blocks.addAll(sha256.convert(b).bytes);
    }
  } finally {
    await raf.close();
  }
  return '${sha256.convert(blocks)}';
}

/// Whether [r] holds the same bytes as [local] ([size] long): by the store's hash when it has one, else the first 64 KB.
Future<bool> sameFile(FileStore api, File local, int size, RemoteFile r) async {
  if (r.size != size) return false;
  if (r.sha1 != null) return '${await sha1.bind(local.openRead()).first}' == r.sha1;
  if (r.md5 != null) return '${await md5.bind(local.openRead()).first}' == r.md5;
  if (r.dropbox != null) return await dropboxHash(local) == r.dropbox;
  final n = min(size, 64 * 1024);
  final mine = await takeBytes(local.openRead(0, n), n);
  final theirs = await api.head(r, n);
  if (theirs.length != mine.length) return false;
  for (var i = 0; i < n; i++) {
    if (mine[i] != theirs[i]) return false;
  }
  return true;
}

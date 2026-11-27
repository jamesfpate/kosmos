import 'package:winnow_native/winnow_native.dart';

import 'media.dart' as media;
import 'models.dart';
import 'store.dart';

// Apple Photos albums: on an iPhone, or a Mac reviewing its Photos library, kept photos are filed into albums of the
// same names in the library itself (iCloud Photos syncs them to the user's other devices). Nothing is copied: the
// photos are the library's own. Re-filing moves a photo between albums; renaming an album renames it in Photos.

const appleDef = StoreDef(
  key: 'apple',
  title: 'Apple Photos albums',
  label: 'Apple Photos',
  intro: [
    'Kept photos go into albums of the same names in your Photos library: the photos themselves, not copies. With '
        'iCloud Photos on, the albums show on your other Apple devices too. Moving a photo or renaming an album '
        'changes it in Photos.',
    'This isn\'t a backup (the photos are the same ones), so Free up space doesn\'t count it.',
  ],
  fields: [],
  albums: _make,
  library: true,
  backup: false,
);

AlbumService _make(StoreConfig c, void Function(String, String) remember) => AppleAlbums();

class AppleAlbums extends AlbumService {
  @override
  Future<String> authorize() async {
    if (await media.getAccess() != media.Access.granted) {
      throw Exception('allow Winnow full access to Photos (Settings > Privacy > Photos)');
    }
    return 'Photos library';
  }

  /// Already in the library: filing it is adding it to the album.
  @override
  Future<String> upload(Item item, String albumId) async {
    await WinnowNative.albumAdd(albumId, [item.id]);
    return item.id;
  }

  @override
  Future<String> ensureAlbum(String title, String? known) => WinnowNative.albumEnsure(title, known);

  @override
  Future<void> add(String albumId, List<String> ids) => WinnowNative.albumAdd(albumId, ids);

  @override
  Future<void> remove(String albumId, List<String> ids) => WinnowNative.albumRemove(albumId, ids);

  @override
  Future<bool> exists(String id) => WinnowNative.assetExists(id);

  @override
  void close() {}
}

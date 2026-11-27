// Apple Photos library checks on an iOS simulator (CI adds sample media and grants photo access first): Winnow sees
// the library, and keeps Apple albums in step (make, find again, rename, add, remove).
//   xcrun simctl addmedia <sim> photo.jpg clip.mp4
//   flutter build ios --simulator --debug -t integration_test/apple_test.dart
//   xcrun simctl install <sim> build/ios/iphonesimulator/Runner.app
//   xcrun simctl privacy <sim> grant photos net.jamespate.winnow
//   xcrun simctl launch --console-pty <sim> net.jamespate.winnow
// (Granted before launch: the app reads its photo permission once, so `flutter test`, which launches it, can't be
// granted in time.)

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:winnow/apple.dart';
import 'package:winnow/db.dart';
import 'package:winnow/media.dart' as media;
import 'package:winnow/models.dart';
import 'package:winnow_native/winnow_native.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late List<Item> items;

  /// The library album called [title] and how many photos it holds (null when there's none).
  Future<int?> albumCount(String title) async {
    final paths = await PhotoManager.getAssetPathList(type: RequestType.common);
    final p = paths.where((p) => p.name == title).firstOrNull;
    return await p?.assetCountAsync;
  }

  testWidgets('sees the library', (_) async {
    expect(media.useFolders, isFalse);
    expect(media.appleLibrary, isTrue);
    expect(await media.getAccess(), media.Access.granted, reason: 'the workflow grants photo access before launch');
    items = await media.loadItems(await Db.open(), const []);
    expect(items.where((i) => !i.isVideo), isNotEmpty, reason: 'the sample photo is in the library');
    expect(items.where((i) => i.isVideo), isNotEmpty, reason: 'the sample video is in the library');
  });

  testWidgets('keeps Apple albums in step', (_) async {
    final photo = items.firstWhere((i) => !i.isVideo);
    final api = AppleAlbums();
    expect(await api.authorize(), 'Photos library');

    final id = await api.ensureAlbum('Winnow CI', null);
    expect(await api.ensureAlbum('Winnow CI', null), id, reason: 'an album with that name is reused, not made twice');
    expect(await api.ensureAlbum('Winnow CI', id), id);

    expect(await api.upload(photo, id), photo.id);
    expect(await albumCount('Winnow CI'), 1);

    // Renaming in Winnow renames the same album in Photos.
    expect(await api.ensureAlbum('Winnow CI renamed', id), id);
    expect(await albumCount('Winnow CI'), isNull);
    expect(await albumCount('Winnow CI renamed'), 1);

    await api.remove(id, [photo.id]);
    expect(await albumCount('Winnow CI renamed'), 0);
    expect(await api.exists(photo.id), isTrue, reason: 'taking it out of an album leaves it in the library');
    // (Deleting an album makes Photos ask, so that path isn't exercised here.)
  });

  testWidgets('a photo gone from the library reads as gone', (_) async {
    expect(await WinnowNative.assetExists('00000000-0000-0000-0000-000000000000/L0/001'), isFalse);
  });
}

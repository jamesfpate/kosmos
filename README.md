# Winnow

App for culling photos before they're backed up (Android, iPhone, Mac, Windows, Linux): swipe to delete or file into
an album (🔍 searches them all; long-press a photo for full size; everything else goes to the year's catch-all album, or the month's if set), review bursts together, file older photos in a grid, and upload only what was kept to
[Immich](https://immich.app), Google Photos (Android), PhotoPrism, Synology Photos or file storage (Nextcloud/WebDAV,
SFTP, S3, B2, Dropbox, OneDrive).

Flutter app (rewritten from an earlier Capacitor/Svelte version; same package id and signing key, so it installs as
an update over it, and that version's backups import here).

Free, no ads, no tracking, no account: photos go only to the services you set up ([privacy](PRIVACY.md)). If it
saves you time, [sponsor it](https://github.com/sponsors/jamesfpate) or buy the Supporter thank-you in the Play Store
build (it unlocks nothing; everything stays free).

## Install
With [Obtainium](https://github.com/ImranR98/Obtainium): Add app -> `https://github.com/jamesfpate/winnow`.
Releases are signed APKs built by GitHub Actions from `v*` tags. Android 11+.

## iPhone and Apple Photos
Winnow reviews the Photos library in place: deletes go to Recently Deleted (after Photos' own confirm), kept photos
go into real albums of the same names ("Apple Photos albums" integration, on by default; iCloud Photos syncs them).
Apple albums aren't a backup, so Free up space doesn't count them. No keywords/captions (Apple's API can't).
- iPhone: each release has `winnow-X.Y.Z-ios-unsigned.ipa`. Install with AltStore or Sideloadly (they sign it with
  your Apple ID; a free Apple ID re-signs every 7 days). TestFlight / App Store need a paid Apple Developer account.
- Mac: Settings > General > Review: Folders or Photos library.
- No background upload on Apple (uploads run while Winnow is open); Google Photos is Android-only.

## Desktop (Mac, Windows, Linux)
Each release also has `winnow-X.Y.Z-mac.zip`, `-windows.zip` and `-linux.tar.gz`. Pick a folder of photos (subfolders
included; a Mac can review its Photos library instead, see above); swipe or use the keyboard (← delete, → keep, ↓ later, Space play, Z undo, / search albums). Kept photos sync to the same
targets as on the phone, while the app is open. Deletes go to the Trash / Recycle Bin. Files stay where they are.
- Mac: not notarized, so the first launch is blocked. Right-click Winnow.app → Open, or
  `xattr -dr com.apple.quarantine /Applications/Winnow.app`. Thumbnails, dates and HEIC/RAW come from macOS itself.
- Windows / Linux: JPEG/PNG/WebP previews only (no HEIC), no video thumbnails. Linux needs `gio` (or uses
  ~/.local/share/Trash) and zenity/kdialog for the folder picker.
- Not on desktop: Google Photos (its sign-in needs Play Services), background upload.

## Develop
Flutter 3.44 (`lib/`): `state.dart` holds all app state and logic, `media.dart` the photo library (photo_manager),
`immich.dart` the Immich API, `db.dart` local SQLite, `ui/` the screens.
- `flutter pub get`, `flutter analyze`, `flutter run`
- codevm has no room for the SDK: `~/bin/fl <args>` runs Flutter in a container on the homelab server
  (ghcr.io/cirruslabs/flutter:3.44.0, source synced to /mnt/apps/appdata/winnow-dev/app).
- Desktop: `lib/folders.dart` (folder scan, metadata cache, trash). Apple native code (Mac folders; Photos albums on
  iPhone and Mac) in `packages/winnow_native/darwin`, `lib/apple.dart` the Apple albums integration. CI's Desktop
  workflow runs `integration_test/desktop_test.dart` on a Mac runner and `integration_test/apple_test.dart` on an
  iPhone simulator (sample media added, photo access granted with `xcrun simctl privacy`).
- Every push to `main`/`flutter` builds a debug APK ("Winnow dev", app id `net.jamespate.winnow.dev`) as a workflow
  artifact; it installs next to the release build.

## Release
Tag `vX.Y.Z` and push the tag. CI signs with the keystore from the repo secrets `WINNOW_KEYSTORE_BASE64`,
`WINNOW_KEYSTORE_PASSWORD`, `WINNOW_KEY_ALIAS`. Every release must use the same key, or Android refuses the
update; the keystore's backup lives outside this repo.
The same release also gets `winnow-X.Y.Z.aab` (the Play Store bundle, signed with the same key as the upload key).

## Monitoring
The Weekly stats workflow comments every Monday on the "Weekly stats" issue: downloads by platform, stars, forks,
open issues, with the change since last week. Run it by hand from Actions any time.

## License
[FSL-1.1-ALv2](LICENSE.md): free to use, change and share, but not to sell as a competing app or service. Each
version becomes Apache 2.0 two years after its release.

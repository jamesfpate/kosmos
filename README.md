# Winnow

Android (and later iOS) app for culling photos on the phone before they're backed up: swipe to delete or file into
an album, review bursts together, file older photos in a grid, and upload only what was kept to
[Immich](https://immich.app) (Google Photos later).

Flutter app (rewritten from an earlier Capacitor/Svelte version; same package id and signing key, so it installs as
an update over it, and that version's backups import here).

## Install
With [Obtainium](https://github.com/ImranR98/Obtainium): Add app -> `https://github.com/jamesfpate/winnow`.
Releases are signed APKs built by GitHub Actions from `v*` tags. Android 11+.

## Desktop (Mac, Windows, Linux)
Each release also has `winnow-X.Y.Z-mac.zip`, `-windows.zip` and `-linux.tar.gz`. Pick a folder of photos (subfolders
included); swipe or use the keyboard (← delete, → keep, ↓ later, Space play, Z undo). Kept photos sync to the same
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
- Desktop: `lib/folders.dart` (folder scan, metadata cache, trash), Mac native code in
  `packages/winnow_native/macos`. CI's Desktop workflow runs `integration_test/desktop_test.dart` on a Mac runner.
- Every push to `main`/`flutter` builds a debug APK ("Winnow dev", app id `net.jamespate.winnow.dev`) as a workflow
  artifact; it installs next to the release build.

## Release
Tag `vX.Y.Z` and push the tag. CI signs with the keystore from the repo secrets `WINNOW_KEYSTORE_BASE64`,
`WINNOW_KEYSTORE_PASSWORD`, `WINNOW_KEY_ALIAS`. Every release must use the same key, or Android refuses the
update; the keystore's backup lives outside this repo.

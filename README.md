# Winnow

Android (and later iOS) app for culling photos on the phone before they're backed up: swipe to delete or file into
an album, review bursts together, file older photos in a grid, and upload only what was kept to
[Immich](https://immich.app) (Google Photos later).

Flutter app (rewritten from an earlier Capacitor/Svelte version; same package id and signing key, so it installs as
an update over it, and that version's backups import here).

## Install
With [Obtainium](https://github.com/ImranR98/Obtainium): Add app -> `https://github.com/jamesfpate/winnow`.
Releases are signed APKs built by GitHub Actions from `v*` tags. Android 11+.

## Develop
Flutter 3.44 (`lib/`): `state.dart` holds all app state and logic, `media.dart` the photo library (photo_manager),
`immich.dart` the Immich API, `db.dart` local SQLite, `ui/` the screens.
- `flutter pub get`, `flutter analyze`, `flutter run`
- codevm has no room for the SDK: `~/bin/fl <args>` runs Flutter in a container on the homelab server
  (ghcr.io/cirruslabs/flutter:3.44.0, source synced to /mnt/apps/appdata/winnow-dev/app).
- Every push to `main`/`flutter` builds a debug APK ("Winnow dev", app id `net.jamespate.winnow.dev`) as a workflow
  artifact; it installs next to the release build.

## Release
Tag `vX.Y.Z` and push the tag. CI signs with the keystore from the repo secrets `WINNOW_KEYSTORE_BASE64`,
`WINNOW_KEYSTORE_PASSWORD`, `WINNOW_KEY_ALIAS`. Every release must use the same key, or Android refuses the
update; the keystore's backup lives outside this repo.

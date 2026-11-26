# Winnow

Android app for culling photos on the phone before they're backed up: swipe to trash or file into an album, and
upload only what was kept to [Immich](https://immich.app) and/or Google Photos.

Status: culling, albums (dated, undated, per-month), bursts, grid filing and backup work; Immich and Google Photos
upload not yet. Formerly "Kosmos" (renamed before publishing; package id changed with it).

## Install
With [Obtainium](https://github.com/ImranR98/Obtainium): Add app -> `https://github.com/jamesfpate/winnow`.
Releases are signed APKs built by GitHub Actions from `v*` tags. Android 11+.

## Develop
Svelte 5 + Vite in `src/`, Capacitor 8 Android shell in `android/`.
- `npm install`, `npm run dev` (browser; add `?mock` for fake photos and bursts), `npm run check`
- `npm run build && npx cap sync android`, then build with Android Studio or `cd android && ./gradlew assembleDebug`
- Every push to `main` builds a debug APK ("Winnow dev", app id `net.jamespate.winnow.dev`) as a workflow
  artifact; it installs next to the release build.

## Release
Tag `vX.Y.Z` and push the tag. CI signs with the keystore from the repo secrets `WINNOW_KEYSTORE_BASE64`,
`WINNOW_KEYSTORE_PASSWORD`, `WINNOW_KEY_ALIAS`. Every release must use the same key, or Android refuses the
update; the keystore's backup lives outside this repo.

# Kosmos

Android app for culling photos on the phone before they're backed up: swipe to trash or file into an album, and
upload only what was kept to [Immich](https://immich.app) and/or Google Photos.

Status: early. Nothing to cull yet.

## Install
With [Obtainium](https://github.com/ImranR98/Obtainium): Add app -> `https://github.com/jamesfpate/kosmos`.
Releases are signed APKs built by GitHub Actions from `v*` tags. Android 11+.

## Develop
Svelte 5 + Vite in `src/`, Capacitor 8 Android shell in `android/`.
- `npm install`, `npm run dev` (browser), `npm run check`
- `npm run build && npx cap sync android`, then build with Android Studio or `cd android && ./gradlew assembleDebug`
- Every push to `main` builds a debug APK ("Kosmos dev", app id `net.jamespate.kosmos.dev`) as a workflow
  artifact; it installs next to the release build.

## Release
Tag `vX.Y.Z` and push the tag. CI signs with the keystore from the repo secrets `KOSMOS_KEYSTORE_BASE64`,
`KOSMOS_KEYSTORE_PASSWORD`, `KOSMOS_KEY_ALIAS`. Every release must use the same key, or Android refuses the
update; the keystore's backup lives outside this repo.

# iOS client

Open `BetterYouTube.xcodeproj` after running `python3 scripts/setup-ios.py` from the repository root. Choose the **BetterYouTube** scheme. Branding and app assets live in `BetterYouTube/Assets.xcassets`.

## Configuration

`Config/Defaults.xcconfig` supplies generic defaults for the app and tests. It optionally includes ignored `Google.local.xcconfig` and `Local.xcconfig`. The latter can override the bundle identifier and development team. `Local.example.xcconfig` documents the format.

`BetterYouTube/Connection.example.plist` is the empty template. Setup copies it to the ignored `Connection.plist` only when that file does not exist. Use `scripts/configure-google.py` for Google sign-in and `scripts/prepare-companion.py` for server pairing. The shared `Info.plist` expands the Google callback and background-task identifier from build settings.

Keep the same local bundle ID and signing team when updating an installed app to preserve its storage and Keychain access. Register any new bundle ID with its own matching Google iOS OAuth client.

## Tests

From the repository root, run `bash scripts/test-simulator.sh YOUR_SIMULATOR_ID`. A fresh simulator starts signed out. Account tests support builds with or without Google configuration; the OAuth browser test skips when Google is not configured.

The native player test uses `server/state/media/aqz-KE-bpKQ.mp4`, created by requesting the Big Buck Bunny video through the companion. It skips if the local fixture is missing. A simulator-only launch environment variable supplies that file to the app; the override is absent from physical-device builds. The download/background-transfer test requires a paired local companion and real media preparation.

Playback settings tests cover caption selection, persistence, speed changes, pause behavior, fullscreen, and native playback. Native menu tests pause before menu interaction because XCTest can wait indefinitely for AVKit animations while a menu overlays playing media.

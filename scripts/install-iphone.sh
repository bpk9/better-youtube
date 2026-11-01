#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
iphone_id="${1:-${IPHONE_ID:-}}"
if [[ -z "$iphone_id" ]]; then
  echo 'Usage: scripts/install-iphone.sh DEVICE_ID (or set IPHONE_ID). List paired devices with: xcrun devicectl list devices' >&2
  exit 2
fi
python3 scripts/setup-ios.py
mkdir -p artifacts
xcodebuild -project ios/BetterYouTube.xcodeproj -scheme BetterYouTube \
  -destination 'generic/platform=iOS' -derivedDataPath .build-device \
  -allowProvisioningUpdates build > artifacts/build-device.log 2>&1
app_path='.build-device/Build/Products/Debug-iphoneos/BetterYouTube.app'
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Info.plist")
xcrun devicectl device install app --device "$iphone_id" "$app_path" --json-output artifacts/install.json
xcrun devicectl device process launch --device "$iphone_id" \
  --terminate-existing "$bundle_id" --json-output artifacts/launch.json

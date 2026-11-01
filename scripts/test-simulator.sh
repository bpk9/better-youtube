#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
simulator_id="${1:-${SIMULATOR_ID:-}}"
if [[ -z "$simulator_id" ]]; then
  echo 'Usage: scripts/test-simulator.sh SIMULATOR_ID (or set SIMULATOR_ID). List simulators with: xcrun simctl list devices available' >&2
  exit 2
fi
python3 scripts/setup-ios.py
mkdir -p artifacts
result="artifacts/tests-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project ios/BetterYouTube.xcodeproj -scheme BetterYouTube \
  -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath .build \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 150 -resultBundlePath "$result" \
  test CODE_SIGNING_ALLOWED=NO > artifacts/tests.log 2>&1
echo "Test results: $result"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build-links
swiftc ios/BetterYouTube/YouTubeLink.swift scripts/link-tests/main.swift -o .build-links/test-links
.build-links/test-links

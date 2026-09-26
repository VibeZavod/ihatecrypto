#!/bin/zsh
# Builds LALA.app with the embedded signing process, signed by the AIVAX team (N78L833HCS).
# Usage: ./build-app.sh [Debug|Release]   → .build/xcode/Build/Products/<config>/LALA.app
set -e
cd "$(dirname "$0")/Xcode"
xcodegen generate --quiet
xcodebuild -project LALA.xcodeproj -scheme LALA -configuration "${1:-Release}" -derivedDataPath ../.build/xcode \
  -allowProvisioningUpdates -skipPackagePluginValidation build | grep -E "error:|BUILD" || true

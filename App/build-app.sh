#!/bin/zsh
# Builds ihatecrypto.app with the embedded signing process, signed by the AIVAX team (N78L833HCS).
# Usage: ./build-app.sh [Debug|Release]   → .build/xcode/Build/Products/<config>/ihatecrypto.app
# A failed build exits non-zero and prints why (a compiler crash has no «error:» line, so the log is searched wider).
set -e
cd "$(dirname "$0")/Xcode"
xcodegen generate --quiet
log=$(mktemp -t lala-build)
if ! xcodebuild -project LALA.xcodeproj -scheme LALA -configuration "${1:-Release}" -derivedDataPath ../.build/xcode \
     -allowProvisioningUpdates -skipPackagePluginValidation build > "$log" 2>&1; then
  grep -E "error:|DESERIALIZATION|Command .* failed|BUILD FAILED" "$log" | cut -c1-300 | head -20
  echo "full log: $log"
  exit 1
fi
grep -E "BUILD" "$log"
rm -f "$log"

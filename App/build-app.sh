#!/bin/zsh
# Builds ihatecrypto.app with the embedded signing process, signed by the AIVAX team (N78L833HCS).
# Usage: ./build-app.sh [Debug|Release]   → .build/xcode/Build/Products/<config>/ihatecrypto.app; Release is then
# installed as ~/Applications/ihatecrypto.app (quit the running copy first).
# A failed build exits non-zero and prints why (a compiler crash has no «error:» line, so the log is searched wider).
set -e
cd "$(dirname "$0")/Xcode"
xcodegen generate --quiet
log=$(mktemp -t ihatecrypto-build)
if ! xcodebuild -project ihatecrypto.xcodeproj -scheme ihatecrypto -configuration "${1:-Release}" -derivedDataPath ../.build/xcode \
     -allowProvisioningUpdates -skipPackagePluginValidation build > "$log" 2>&1; then
  grep -E "error:|DESERIALIZATION|Command .* failed|BUILD FAILED" "$log" | cut -c1-300 | head -20
  echo "full log: $log"
  exit 1
fi
grep -E "BUILD" "$log"
rm -f "$log"
# Release runs from ~/Applications: macOS refuses notifications (UNErrorDomain 1) to an app inside ~/Desktop, where
# this repo lives. Debug stays in .build for tests; the build copy is unregistered so «open -b» and the Dock find one app.
if [ "${1:-Release}" = Release ]; then
  built=../.build/xcode/Build/Products/Release/ihatecrypto.app
  mkdir -p ~/Applications
  rm -rf ~/Applications/ihatecrypto.app.new
  ditto "$built" ~/Applications/ihatecrypto.app.new
  rm -rf ~/Applications/ihatecrypto.app
  mv ~/Applications/ihatecrypto.app.new ~/Applications/ihatecrypto.app
  ls=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  $ls -u "$built" 2>/dev/null || true
  $ls -f ~/Applications/ihatecrypto.app
  echo "installed: ~/Applications/ihatecrypto.app (launch that one)"
fi

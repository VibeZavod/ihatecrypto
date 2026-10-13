#!/bin/zsh
# Builds «ihatecrypto Dev.app» — the development copy — with the embedded signing process, signed by the AIVAX team
# (N78L833HCS). It runs beside the working ihatecrypto.app (the release: release.sh makes it, Sparkle updates it) and
# shares nothing with it: the bundle id app.ihatecrypto.mac.dev gives it its own signer Keychain group (so its own
# wallets), settings, model logins, data (Application Support/ihatecrypto-dev), debug API port (51790) and Keep running
# agent. Nothing here touches ~/Applications/ihatecrypto.app or what it keeps.
# Usage: ./build-app.sh [Debug|Release]   → .build/xcode/Build/Products/<config>/ihatecrypto Dev.app; Release is then
# installed as ~/Applications/ihatecrypto Dev.app (quit the running Dev copy first).
# A failed build exits non-zero and prints why (a compiler crash has no «error:» line, so the log is searched wider).
set -e
cd "$(dirname "$0")/Xcode"
xcodegen generate --quiet
log=$(mktemp -t ihatecrypto-build)
if ! xcodebuild -project ihatecrypto.xcodeproj -scheme ihatecrypto -configuration "${1:-Release}" -derivedDataPath ../.build/xcode \
     -allowProvisioningUpdates -skipPackagePluginValidation APP_NAME="ihatecrypto Dev" APP_ID=app.ihatecrypto.mac.dev \
     build > "$log" 2>&1; then
  grep -E "error:|DESERIALIZATION|Command .* failed|BUILD FAILED" "$log" | cut -c1-300 | head -20
  echo "full log: $log"
  exit 1
fi
grep -E "BUILD" "$log"
rm -f "$log"
# Release runs from ~/Applications: macOS refuses notifications (UNErrorDomain 1) to an app inside ~/Desktop, where
# this repo lives. Debug stays in .build for tests; the build copy is unregistered so «open -b» and the Dock find one app.
if [ "${1:-Release}" = Release ]; then
  built="../.build/xcode/Build/Products/Release/ihatecrypto Dev.app"
  dev=~/Applications/"ihatecrypto Dev.app"
  mkdir -p ~/Applications
  rm -rf "$dev.new"
  ditto "$built" "$dev.new"
  rm -rf "$dev"
  mv "$dev.new" "$dev"
  ls=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  $ls -u "$built" 2>/dev/null || true
  $ls -f "$dev"
  echo "installed: $dev (launch that one; the working ihatecrypto.app is untouched)"
fi

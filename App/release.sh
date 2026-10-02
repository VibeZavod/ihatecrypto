#!/bin/zsh
# An update for the site: ./release.sh 0.2 https://example.com/ihatecrypto
#   → dist/ihatecrypto-0.2.zip and dist/appcast.xml (with the release notes inside). Upload them to that URL: copies
#     downloaded from it find the appcast there and update themselves. Keep dist/ between releases: the old zips make
#     the small .delta updates.
# A copy to hand over: ./release.sh 0.2   → dist/ihatecrypto-0.2.dmg, notarized, no update checks. Opens on any Mac
#   with macOS 26 by a double click and starts on the first screen; the Keychain and Application Support stay here.
# Needs, once on this Mac:
#   - the «Developer ID Application» certificate of team N78L833HCS in the login Keychain (Xcode › Settings › Accounts);
#   - a notarytool profile: xcrun notarytool store-credentials notary --apple-id … --team-id N78L833HCS
#   - Sparkle's private key, in the login Keychain only (generate_keys made it; its public half is in
#     Xcode/ihatecrypto-Info.plist). Never export it to a file. If it's lost, it can be replaced: releases carry the team's
#     Developer ID signature, and Sparkle takes an update that changes the EdDSA key as long as that signature stays the
#     team's — a new key (generate_keys) and its SUPublicEDKey in the next release. Never change both at once.
# Team and bundle id stay N78L833HCS / app.ihatecrypto.mac, or the signer loses its Keychain items.
# The build number is the commit count, so every release is newer than the last. Built from the working tree:
# commit first, the script refuses uncommitted changes to Sources.
set -e
version=$1; site=${2%/}
[[ -n $version && ( -z $site || $site == https://* ) ]] || { echo "usage: ./release.sh <version> [<https://site/path>]"; exit 1; }
cd "$(dirname "$0")"
git diff --quiet HEAD -- Sources Xcode || { echo "Sources or Xcode have uncommitted changes: commit them first."; exit 1; }
python3 Tools/release-notes.py "$version" > /dev/null || { echo "Sources/IhatecryptoApp/WhatsNew/whatsnew.json has no entry for $version."; exit 1; }
build=$(git rev-list --count HEAD)
out=dist; derived=.build/release
sparkle=$derived/SourcePackages/artifacts/sparkle/Sparkle/bin
mkdir -p $out
(cd Xcode && xcodegen generate --quiet)
log=$(mktemp -t ihatecrypto-release)
step() { echo "· $1"; }
fail() { grep -E "error:|Command .* failed|FAILED" "$log" | cut -c1-300 | head -20; echo "full log: $log"; exit 1; }

step "archive $version ($build)"
xcodebuild -project Xcode/ihatecrypto.xcodeproj -scheme ihatecrypto -configuration Release -derivedDataPath $derived \
  -archivePath $out/ihatecrypto.xcarchive -allowProvisioningUpdates -skipPackagePluginValidation \
  MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$build SPARKLE_FEED_URL=${site:+$site/appcast.xml} archive > "$log" 2>&1 || fail

step "sign with Developer ID"
cat > $out/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>N78L833HCS</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
rm -rf $out/export
xcodebuild -exportArchive -archivePath $out/ihatecrypto.xcarchive -exportPath $out/export -exportOptionsPlist $out/export.plist \
  -allowProvisioningUpdates > "$log" 2>&1 || fail
app=$out/export/ihatecrypto.app
codesign --verify --deep --strict "$app"
[[ -z $site || $(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$app/Contents/Info.plist") == $site/appcast.xml ]] || { echo "the feed didn't make it into Info.plist"; exit 1; }

step "notarize (a few minutes)"
ditto -c -k --keepParent "$app" $out/notarize.zip
xcrun notarytool submit $out/notarize.zip --keychain-profile notary --wait
rm $out/notarize.zip
xcrun stapler staple "$app"
spctl --assess --type execute "$app"

if [[ -z $site ]]; then
  step "disk image"
  dmg=$out/ihatecrypto-$version.dmg
  rm -rf $out/dmg $dmg; mkdir $out/dmg
  ditto "$app" $out/dmg/ihatecrypto.app
  ln -s /Applications $out/dmg/Applications
  hdiutil create -volname ihatecrypto -srcfolder $out/dmg -format UDZO $dmg > /dev/null
  identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
  [[ -n $identity ]] && codesign --sign "$identity" --timestamp $dmg
  xcrun notarytool submit $dmg --keychain-profile notary --wait
  xcrun stapler staple $dmg
  rm -rf $out/dmg $out/export $out/ihatecrypto.xcarchive $out/export.plist
  echo "done: $out/ihatecrypto-$version.dmg — hand over this file only"
  exit 0
fi

step "archive and appcast"
ditto -c -k --sequesterRsrc --keepParent "$app" $out/ihatecrypto-$version.zip
python3 Tools/release-notes.py "$version" > $out/ihatecrypto-$version.html
rm -rf $out/export $out/ihatecrypto.xcarchive $out/export.plist
# Signs the new zip (and the feed: the app requires a signed one) with the key in the Keychain; the notes go inside.
$sparkle/generate_appcast --download-url-prefix "$site/" $out
rm -f "$log"
echo "done: upload $out/appcast.xml, $out/ihatecrypto-$version.zip and any .delta files to $site/"

#!/bin/sh
# Build, sign with your Apple Development certificate, run.
# A stable signature lets Keychain recognise the app after every rebuild,
# so "Always Allow" is asked once instead of after each build.
set -e
cd "$(dirname "$0")"
swift build --product IhatecryptoApp
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')
[ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" --identifier app.ihatecrypto.dev .build/debug/IhatecryptoApp
exec .build/debug/IhatecryptoApp "$@"

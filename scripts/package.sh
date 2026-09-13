#!/usr/bin/env bash
# Builds a universal Release .app and packages it into dist/QuackCast.dmg and
# dist/QuackCast-macOS.zip. Ad-hoc signed (no Apple account needed); see README
# for the notarization upgrade that removes the Gatekeeper prompt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The .xcodeproj is generated (gitignored), so it must be created before build.
xcodegen generate

rm -rf build dist
mkdir -p dist

xcodebuild -project QuackCast.xcodeproj -scheme QuackCast -configuration Release \
  -derivedDataPath build/dd \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" build

APP="build/dd/Build/Products/Release/QuackCast.app"
STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "QuackCast" -srcfolder "$STAGE" -ov -format UDZO dist/QuackCast.dmg
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/QuackCast-macOS.zip

echo "Artifacts:"
ls -lh dist/

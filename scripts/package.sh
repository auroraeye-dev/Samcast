#!/usr/bin/env bash
# Build Samcast and package it for distribution.
#
#   ./scripts/package.sh              build + package (ad-hoc/dev signed)
#   ./scripts/package.sh --run        build, install to /Applications, launch
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package.sh
#   NOTARY_PROFILE=samcast ./scripts/package.sh    also notarize (needs the above)
#
# Signing notes:
#   * Default signing uses whatever the project is configured with (a free
#     Apple Development identity). That is fine for running locally and keeps
#     macOS privacy permissions stable across rebuilds.
#   * A Developer ID identity + notarization is the ONLY way a *downloaded*
#     build opens with no Gatekeeper warning, and requires a paid Apple
#     Developer Program membership.
#   * Building from source (this script) never sets the quarantine flag, so
#     locally built apps open with no warning regardless of signing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_AFTER=false
SHARE=false
for arg in "$@"; do
  case "$arg" in
    --run)   RUN_AFTER=true ;;
    --share) SHARE=true ;;
  esac
done

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate

rm -rf build dist
mkdir -p dist

# The project pins a development team so that privacy permissions survive
# rebuilds on the developer's own machine. A CI runner has no such
# certificate, so without a fallback every tagged release fails to build.
# NOTE: expanded below as ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} rather than plain
# "${SIGN_ARGS[@]}". macOS ships bash 3.2, where expanding an EMPTY array under
# `set -u` is an unbound-variable error — which is exactly the common case here,
# when the project's own signing identity is used and no overrides are needed.
SIGN_ARGS=()
if $SHARE; then
  # A build meant for somebody else's Mac.
  #
  # The normal build is signed with an Apple Development certificate, which
  # makes macOS add the get-task-allow (debuggable) entitlement. An app
  # carrying that, signed for development, refuses to launch on any Mac other
  # than a registered development machine — so the obvious "just send them the
  # DMG" quietly does not work.
  #
  # Ad-hoc signing drops both, and the app runs anywhere after the user
  # right-click ▸ Opens it once. The cost is that the signature changes with
  # every build, so macOS treats each one as a new app and privacy permissions
  # have to be granted again. Fine for testing; Developer ID + notarization is
  # the real answer for distribution.
  echo "Building a shareable, ad-hoc signed app (runs on any Mac)"
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
             DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER=""
             CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "Signing with: $SIGN_IDENTITY"
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY")
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Develop"; then
  echo "Signing with the project's configured identity"
else
  echo "No signing identity available — falling back to ad-hoc signing"
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="")
fi

xcodebuild -project Samcast.xcodeproj -scheme Samcast -configuration Release \
  -derivedDataPath build/dd \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} build

APP="build/dd/Build/Products/Release/Samcast.app"

# Package a DMG (drag-to-Applications) and a plain zip.
STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Samcast" -srcfolder "$STAGE" -ov -format UDZO dist/Samcast.dmg
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Samcast-macOS.zip

# Notarize only when a stored notarytool profile is supplied.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Notarizing with profile: $NOTARY_PROFILE"
  xcrun notarytool submit dist/Samcast.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple dist/Samcast.dmg
fi

echo
echo "Artifacts:"
ls -lh dist/
codesign -dv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" || true

if $RUN_AFTER; then
  echo
  echo "Installing to /Applications and launching…"
  pkill -f "Samcast.app/Contents/MacOS/Samcast" 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Samcast.app
  cp -R "$APP" /Applications/Samcast.app
  open -a /Applications/Samcast.app
fi

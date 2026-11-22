#!/bin/zsh
# Builds Cove in Release and packs it into a dmg.
#
#   scripts/package.sh                       # ad-hoc signed: runs on this Mac, Gatekeeper warns elsewhere
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package.sh
#   CODESIGN_IDENTITY=... NOTARY_PROFILE=cove-notary scripts/package.sh   # also notarizes and staples
#
# NOTARY_PROFILE is a keychain profile made once with:
#   xcrun notarytool store-credentials cove-notary --apple-id <id> --team-id <TEAMID>
set -euo pipefail
cd "${0:A:h}/.."

IDENTITY="${CODESIGN_IDENTITY:--}"
OUT="build/release"
APP="$OUT/Build/Products/Release/Cove.app"
DMG="build/Cove.dmg"

rm -rf "$OUT" "$DMG"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath "$OUT" CODE_SIGNING_ALLOWED=NO build | tail -3

# Sign inside-out: helpers first, then the app, with the hardened runtime when a real identity is used.
FLAGS=(--force --timestamp=none)
[[ "$IDENTITY" != "-" ]] && FLAGS=(--force --timestamp --options runtime)
find "$APP/Contents" \( -name "*.xpc" -o -name "*.dylib" -o -path "*/Helpers/*" -o -name "*.framework" \) -print0 \
  | xargs -0 -I{} codesign "${FLAGS[@]}" --sign "$IDENTITY" {} 2>/dev/null || true
codesign "${FLAGS[@]}" --sign "$IDENTITY" --entitlements boringNotch/boringNotch.entitlements "$APP" 2>/dev/null \
  || codesign "${FLAGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "signature ok ($IDENTITY)"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Cove" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
echo "wrote $DMG"

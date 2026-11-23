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

# Signing identity: CODESIGN_IDENTITY, else the local self-signed "Cove Local Signing" certificate if it exists (so macOS
# keeps recognising the app across rebuilds and updates and does not reset Accessibility and similar grants), else ad hoc.
LOCAL_HASH="$(security find-identity -p codesigning 2>/dev/null | awk '/"Cove Local Signing"/ {print $2; exit}')"
IDENTITY="${CODESIGN_IDENTITY:-${LOCAL_HASH:--}}"
LOCAL_SIGNING=0
[[ "$IDENTITY" == "$LOCAL_HASH" && -n "$LOCAL_HASH" ]] && LOCAL_SIGNING=1
OUT="build/release"
APP="$OUT/Build/Products/Release/Cove.app"
DMG="build/Cove.dmg"

rm -rf "$OUT" "$DMG"
# Let Xcode sign everything (helpers, Sparkle's XPC services, the app) so entitlements and nesting come out right.
SIGN_ARGS=(CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY="$IDENTITY")
[[ "$IDENTITY" != "-" && "$LOCAL_SIGNING" == 0 ]] && SIGN_ARGS+=(ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp")
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath "$OUT" "${SIGN_ARGS[@]}" build | tail -3
codesign --verify --deep --strict "$APP"
echo "signature ok ($IDENTITY)"; codesign -dr - "$APP" 2>&1 | grep -E "designated" | cut -c1-160

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

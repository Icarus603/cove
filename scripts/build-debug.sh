#!/bin/zsh
# Builds the Debug app into .build/xcode, signed with the same local certificate as the release (see package.sh), so macOS keeps
# recognising it across rebuilds and does not reset Accessibility (the "Replace system HUD" switch) and similar grants. Without that
# certificate it falls back to ad hoc signing, which changes with every build and loses those grants each time.
set -euo pipefail
cd "${0:A:h}/.."
LOCAL_HASH="$(security find-identity -p codesigning 2>/dev/null | awk '/"Cove Local Signing"/ {print $2; exit}')"
IDENTITY="${CODESIGN_IDENTITY:-${LOCAL_HASH:--}}"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath .build/xcode \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY="$IDENTITY" build 2>&1 | grep -E "error:|BUILD SUCC|BUILD FAIL"
codesign -dr - .build/xcode/Build/Products/Debug/Cove.app 2>&1 | grep designated | cut -c1-160

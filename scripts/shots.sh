#!/bin/zsh
# Builds Cove (Debug), runs it once and takes real screen captures: the closed notch and each settings tab.
# Unlike the off-screen snapshots these show the sidebar and the notch exactly as on screen. Needs the
# terminal app to have Screen Recording access. The installed Cove should be left alone: this is a separate run.
#
#   scripts/shots.sh                       # every tab -> build/shots
#   scripts/shots.sh Modules,Advanced      # only these tabs
#   OUT=/some/dir scripts/shots.sh
set -euo pipefail
cd "${0:A:h}/.."
OUT="${OUT:-$PWD/build/shots}"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath .build/xcode \
  build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error: |\*\* BUILD" || true
env COVE_SHOT_DIR="$OUT" ${1:+COVE_SHOT_TABS=$1} .build/xcode/Build/Products/Debug/Cove.app/Contents/MacOS/Cove >/dev/null 2>&1 &
PID=$!
for _ in {1..90}; do [[ -f "$OUT/DONE" ]] && break; sleep 1; done
kill $PID 2>/dev/null || true
pkill -f "Build/Products/Debug/Cove.app" 2>/dev/null || true
ls "$OUT"

#!/bin/zsh
# One release, start to finish: scripts/release.sh <version> "<one-line summary>" [notes file]
#
# Commits everything first, bumps the version, builds and signs, then checks that the commit being tagged is exactly what was
# built (a clean tree) before it tags, pushes and publishes. It stops at the first failure and never tags anything half done.
set -euo pipefail
cd "${0:A:h}/.."
VERSION="${1:?usage: scripts/release.sh <version> \"summary\" [notes file]}"
SUMMARY="${2:?usage: scripts/release.sh <version> \"summary\" [notes file]}"
NOTES="${3:-}"
TAG="v$VERSION"

[[ -z "$(git tag -l "$TAG")" ]] || { echo "tag $TAG already exists"; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "not on main"; exit 1; }
scripts/check-accent.sh

# 1. Everything that has changed goes into one commit, before the build.
git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "Cove $VERSION: $SUMMARY

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
fi

# 2. The version number, in its own commit.
BUILD=$(( $(grep -m1 "CURRENT_PROJECT_VERSION" boringNotch.xcodeproj/project.pbxproj | tr -dc '0-9') + 1 ))
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD;/g; s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $VERSION;/g" boringNotch.xcodeproj/project.pbxproj
git add boringNotch.xcodeproj
git commit -q -m "Cove $VERSION

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"

# 3. Build, sign and pack, then the update feed.
pkill -9 -x Cove 2>/dev/null || true
scripts/package.sh
scripts/make-appcast.sh "$VERSION"

# 4. What is tagged must be what was built: nothing uncommitted, nothing untracked that matters.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "the working tree is not clean after the build; nothing was tagged:"; git status --short; exit 1
fi

# 5. Tag, push, publish, and check the release has both files.
git tag "$TAG"
git push -q origin main
git push -q origin "$TAG"
if [[ -n "$NOTES" ]]; then NOTES_ARGS=(--notes-file "$NOTES"); else NOTES_ARGS=(--notes "$SUMMARY"); fi
gh release create "$TAG" build/Cove.dmg build/appcast.xml --title "Cove $VERSION" "${NOTES_ARGS[@]}"
ASSETS="$(gh release view "$TAG" --json assets -q '.assets[].name' | sort | tr '\n' ' ')"
[[ "$ASSETS" == "Cove.dmg appcast.xml " || "$ASSETS" == "appcast.xml Cove.dmg " ]] || { echo "release is missing a file: $ASSETS"; exit 1; }
echo "released $TAG: $(gh release view "$TAG" --json url -q .url)"

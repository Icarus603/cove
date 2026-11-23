#!/bin/zsh
# Writes build/appcast.xml for build/Cove.dmg, signed with the Sparkle EdDSA key in your login Keychain
# (made once with Sparkle's generate_keys; the public half is SUPublicEDKey in Info.plist).
# The feed lives at releases/latest/download/appcast.xml, so every release uploads Cove.dmg and appcast.xml together.
#
#   scripts/make-appcast.sh 1.0.0
set -euo pipefail
cd "${0:A:h}/.."
VERSION="${1:?usage: make-appcast.sh <version>}"
REPO="${REPO:-Icarus603/cove}"
DMG="build/Cove.dmg"
APP="build/release/Build/Products/Release/Cove.app"
SIGN="$(find .build/xcode/SourcePackages/artifacts -name sign_update -path '*bin*' | head -1)"

BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 14.0)"
SIG_ATTRS="$("$SIGN" "$DMG")"          # sparkle:edSignature="..." length="..."
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cove</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/v$VERSION</link>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Cove.dmg" type="application/octet-stream" $SIG_ATTRS/>
    </item>
  </channel>
</rss>
XML
echo "wrote build/appcast.xml"

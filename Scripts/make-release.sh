#!/bin/bash
# Builds a release of Convert Anything for GitHub: a universal (Apple Silicon + Intel) app as a
# drag-to-install disk image for people to download, the same app zipped for Sparkle, and the
# appcast.xml that tells installed copies about the zip (Sparkle reads it from the latest release).
#
#   ./Scripts/make-release.sh notes.html
#
# notes.html is a short HTML fragment (e.g. a <ul>) shown in the update window. The version comes from
# MARKETING_VERSION / CURRENT_PROJECT_VERSION in the Xcode project; bump both before running.
# Signing uses the private key that `generate_keys --account convert-anything` saved in your keychain.
# Output goes to build/release/: Convert-Anything.dmg, Convert-Anything.zip and appcast.xml.
# Attach all three to a GitHub release tagged v<version>, e.g.  gh release create v1.3 build/release/* --notes-file notes.md
set -euo pipefail

cd "$(dirname "$0")/.."
NOTES=${1:?usage: make-release.sh notes.html}
REPO=JayBirdZhang/convert-anything
OUT=build/release
DERIVED=build/derived

xcodebuild -project "Convert Anything.xcodeproj" -scheme "Convert Anything" -configuration Release \
    -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet

APP="$DERIVED/Build/Products/Release/Convert Anything.app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
MIN_MACOS=$(plist LSMinimumSystemVersion)

rm -rf "$OUT" && mkdir -p "$OUT"
# No extended attributes or resource forks: they'd come out as stray ._ files and break the signature.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUT/Convert-Anything.zip"

"$(dirname "$0")/make-dmg.sh" "$APP" "$OUT/Convert-Anything.dmg"

SIGN_UPDATE=$(find "$DERIVED/SourcePackages/artifacts" -name sign_update -type f -perm +111 | head -1)
SIGNATURE=$("$SIGN_UPDATE" --account convert-anything "$OUT/Convert-Anything.zip")

cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Convert Anything</title>
        <item>
            <title>$VERSION</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
            <description><![CDATA[$(cat "$NOTES")]]></description>
            <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Convert-Anything.zip" $SIGNATURE type="application/octet-stream"/>
        </item>
    </channel>
</rss>
EOF
xmllint --noout "$OUT/appcast.xml"
echo "Convert Anything $VERSION ($BUILD) → $OUT"

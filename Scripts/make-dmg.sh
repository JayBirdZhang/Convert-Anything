#!/bin/bash
# Packs a built Convert Anything.app into a drag-to-install disk image: the app, an Applications
# shortcut, and a background with an arrow between them.
#
#   ./Scripts/make-dmg.sh "path/to/Convert Anything.app" out/Convert-Anything.dmg
#
# Uses only hdiutil, Finder (to lay out the window) and swift (to draw the background).
set -euo pipefail

APP=${1:?usage: make-dmg.sh app out.dmg}
DMG=${2:?usage: make-dmg.sh app out.dmg}
NAME="Convert Anything"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Background: 1x and 2x drawn by dmg-background.swift, combined into one HiDPI TIFF.
swift "$HERE/dmg-background.swift" "$WORK" 2>/dev/null
mkdir -p "$WORK/stage/.background"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" \
    -out "$WORK/stage/.background/background.tiff" 2>/dev/null

ditto --norsrc --noextattr "$APP" "$WORK/stage/$NAME.app"
ln -s /Applications "$WORK/stage/Applications"

hdiutil create -quiet -srcfolder "$WORK/stage" -volname "$NAME" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
# The volume may mount as "Convert Anything 1" if a volume of that name is already mounted.
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
DISK=$(basename "$MOUNT")

osascript <<EOF
tell application "Finder"
    tell disk "$DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 800, 548}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$NAME.app" of container window to {160, 190}
        set position of item "Applications" of container window to {440, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

# Wait for Finder to write the layout, then seal the image.
for _ in $(seq 20); do [ -f "$MOUNT/.DS_Store" ] && break; sleep 0.5; done
[ -f "$MOUNT/.DS_Store" ] || { echo "Finder didn't save the window layout" >&2; exit 1; }
rm -rf "$MOUNT/.fseventsd"
sync
hdiutil detach -quiet "$MOUNT"
mkdir -p "$(dirname "$DMG")"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -ov -o "$DMG"
echo "Disk image → $DMG"

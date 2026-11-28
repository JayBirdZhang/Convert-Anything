#!/bin/bash
# Double-click to try the drop zone prototype: makes test files, opens them in Finder, starts the prototype.
cd "$(dirname "$0")"
APP="$PWD/build/DropZoneProto.app"
LOG="$HOME/Library/Logs/DropZoneProto.log"
FILES="$HOME/Desktop/Drop Zone Test Files"

[ -d "$APP" ] || ./build.sh

# Fake files: the prototype only looks at the extension and never opens or changes them.
mkdir -p "$FILES"
for f in "Photo.heic" "Screenshot.png" "Holiday.jpg" "Interview.mp4" "Song.mp3" "Essay.docx" "Paper.pdf" "Slides.pptx" "Mystery.xyz"; do
    [ -e "$FILES/$f" ] || : > "$FILES/$f"
done

pkill -x DropZoneProto 2>/dev/null
: > "$LOG"
open "$APP"
open "$FILES"

clear
cat <<'STEPS'
The prototype is running: it's the second prism icon in your menu bar.
A Finder window with test files is open.

Try these:
  1. Drag Photo.heic up onto the prism and hold still for a moment.
     The menu opens with formats. Let go on one: a checkmark appears.
  2. Drag a file onto the prism, then let go somewhere else. Nothing should happen.
  3. Select three photos (heic, png, jpg) and drag them together.
  4. Drag Mystery.xyz: it should say it can't convert it.
  5. Drop on "More…" to see every format.
  6. Drag Photo.heic again: your last choice should come first.
  7. Click the prism to change the "Spring-load delay" if opening feels slow or fast.

When you're done, come back here and press Return.
STEPS
read -r || exit 0

echo
echo "What happened:"
grep -E "spring: fired|dropped on|closed \(|wait restarted|drag entered" "$LOG" | sed 's/^ *[0-9.]*  /  /'
pkill -x DropZoneProto
echo
echo "Prototype quit. You can delete \"Drop Zone Test Files\" from your Desktop."

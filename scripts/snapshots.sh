#!/bin/zsh
# Saves pictures of the interface from a debug build, for checks on another system or chip.
#   scripts/snapshots.sh OUTPUT_FOLDER
set -euo pipefail

ROOT="${0:A:h:h}"
OUT="${1:?usage: scripts/snapshots.sh OUTPUT_FOLDER}"
SCRATCH="$HOME/Library/Caches/MediaShift/build"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product MediaShiftApp
APP="$(swift build --scratch-path "$SCRATCH" --show-bin-path)/MediaShiftApp"

mkdir -p "$OUT"
SAMPLES="$(mktemp -d)"
trap 'rm -rf "$SAMPLES"' EXIT
touch "$SAMPLES/photo.jpg" "$SAMPLES/clip.mp4" "$SAMPLES/Quarterly report for the board.docx"
echo "this is not a word file" > "$SAMPLES/broken.docx"

shot() {
    # Exits by itself after saving the picture. The limit only guards against a hang.
    MEDIASHIFT_PREVIEW="$1" MEDIASHIFT_SNAPSHOT="$OUT/$2.png" perl -e 'alarm 15; exec @ARGV' "$APP" || echo "warning: no picture of $2"
}

shot "wheel:$SAMPLES/photo.jpg" wheel-image
shot "wheel:$SAMPLES/photo.jpg:2" wheel-highlighted
shot "wheel:$SAMPLES/clip.mp4" wheel-video
shot "wheel:$SAMPLES/Quarterly report for the board.docx" wheel-document
shot "chooser:$SAMPLES/photo.jpg" chooser
shot "toast:$SAMPLES/broken.docx" result-note
for page in general wheel output images media documents; do
    shot "settings:$page" "settings-$page"
done

ls "$OUT"

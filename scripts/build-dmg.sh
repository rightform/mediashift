#!/bin/zsh
# Packs the built app into a disk image, the usual way to hand out a Mac app: open it and drag
# the app onto the Applications shortcut. Run it through `make dmg`, which builds the app first.
# Signing and notarizing come in here once a Developer ID is available.
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/app.env"
DIST="$HOME/Library/Caches/MediaShift/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$APP_VERSION.dmg"

if [[ ! -d "$APP" ]]; then
    echo "error: there is no app to pack yet. Run: make app" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# hdiutil now and then fails for a moment with no lasting cause, so it gets a few tries. Newer
# systems call it deprecated in favor of diskutil image, but this has to build on macOS 15 too.
for attempt in 1 2 3; do
    if hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format ULFO "$DMG" > /dev/null; then
        break
    fi
    if (( attempt == 3 )); then
        echo "error: the disk image could not be created." >&2
        exit 1
    fi
    echo "The disk image could not be created. Trying again." >&2
    sleep 3
done
hdiutil verify -quiet "$DMG"

echo "$DMG"

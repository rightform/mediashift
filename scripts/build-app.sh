#!/bin/zsh
# Builds a release .app. Output goes to the Caches folder, not the project:
# folders on the Desktop carry Finder and iCloud attributes that codesign rejects.
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/app.env"
SCRATCH="$HOME/Library/Caches/MediaShift/build"
DIST="$HOME/Library/Caches/MediaShift/dist"
APP="$DIST/$APP_NAME.app"
FFMPEG="$ROOT/vendor/ffmpeg/bin/ffmpeg"

cd "$ROOT"
CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product MediaShiftApp --scratch-path "$SCRATCH"
swift build -c "$CONFIG" --product mediashift --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c "$CONFIG" --product MediaShiftApp --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/MediaShiftApp" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/mediashift" "$APP/Contents/Helpers/mediashift"

# Data files are read from the app's Resources. See OfficeFormats/Pages/PagesWriter.swift.
cp -R "$ROOT/Sources/OfficeFormats/Resources/BlankTemplate.pages" "$APP/Contents/Resources/"

if [[ -x "$FFMPEG" ]]; then
    cp "$FFMPEG" "$APP/Contents/Resources/bin/ffmpeg"
    cp -R "$ROOT/vendor/ffmpeg/licenses" "$APP/Contents/Resources/licenses"
else
    echo "warning: vendor/ffmpeg is missing, so audio, video and WebP will not work. Run: make ffmpeg" >&2
fi

if [[ -f "$ROOT/scripts/AppIcon.icns" ]]; then
    cp "$ROOT/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License. Copyright rightform Aleksander Jagusiak.</string>
</dict>
</plist>
PLIST

# Ad hoc signature until a Developer ID is available. Inner binaries first.
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ -x "$APP/Contents/Resources/bin/ffmpeg" ]]; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/bin/ffmpeg"
fi
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Helpers/mediashift"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "$APP"

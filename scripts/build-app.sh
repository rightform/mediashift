#!/bin/zsh
# Builds a release .app for Apple Silicon and Intel. Output goes to the Caches folder, not the
# project: folders on the Desktop carry Finder and iCloud attributes that codesign rejects.
# APP_ARCHS="arm64" builds one architecture only, which is much quicker while developing.
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/app.env"
CACHES="$HOME/Library/Caches/MediaShift"
DIST="$CACHES/dist"
APP="$DIST/$APP_NAME.app"
FFMPEG="$ROOT/vendor/ffmpeg/bin/ffmpeg"
ARCHS=(${=APP_ARCHS:-arm64 x86_64})

cd "$ROOT"
CONFIG="${CONFIG:-release}"

# One scratch folder per architecture, so that neither build invalidates the other.
app_parts=()
tool_parts=()
for arch in $ARCHS; do
    build=(swift build -c "$CONFIG" --triple "$arch-apple-macosx$MIN_MACOS" --scratch-path "$CACHES/build-$arch")
    $build --product MediaShiftApp
    $build --product mediashift
    bin_dir="$($build --show-bin-path)"
    app_parts+="$bin_dir/MediaShiftApp"
    tool_parts+="$bin_dir/mediashift"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/bin"
lipo -create $app_parts -output "$APP/Contents/MacOS/$APP_NAME"
lipo -create $tool_parts -output "$APP/Contents/Helpers/mediashift"

# Data files are read from the app's Resources. See OfficeFormats/Pages/PagesWriter.swift.
cp -R "$ROOT/Sources/OfficeFormats/Resources/BlankTemplate.pages" "$APP/Contents/Resources/"

if [[ -x "$FFMPEG" ]]; then
    for arch in $ARCHS; do
        if [[ " $(lipo -archs "$FFMPEG") " != *" $arch "* ]]; then
            echo "warning: vendor/ffmpeg has no $arch part, so audio, video and WebP will not work there. Run: make ffmpeg" >&2
        fi
    done
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
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
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

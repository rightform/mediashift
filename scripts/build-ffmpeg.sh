#!/usr/bin/env bash
#
# Builds a small, static, LGPL ffmpeg for Apple Silicon into vendor/ffmpeg.
#
#   scripts/build-ffmpeg.sh            build, or do nothing if vendor/ffmpeg is current
#   scripts/build-ffmpeg.sh --clean    throw away the work directory first
#
# Result:
#   vendor/ffmpeg/bin/ffmpeg           self contained except for system libraries
#   vendor/ffmpeg/licenses/            license text and source pins of every component
#
# Every source tarball is pinned by version and SHA-256 below. A mismatch aborts the build.
# The only build tool that is not part of macOS or the Command Line Tools is pkgconf,
# which this script builds itself from its official tarball.
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Pinned sources. To update a component, change its version, URL and hash together.
# ---------------------------------------------------------------------------

FFMPEG_VERSION=8.1.3
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
FFMPEG_LICENSE="LGPL-2.1-or-later (built without GPL or nonfree parts)"

LIBVPX_VERSION=1.17.0
LIBVPX_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v${LIBVPX_VERSION}.tar.gz"
LIBVPX_SHA256=1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a
LIBVPX_LICENSE="BSD-3-Clause"

LIBWEBP_VERSION=1.6.0
LIBWEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${LIBWEBP_VERSION}.tar.gz"
LIBWEBP_SHA256=e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
LIBWEBP_LICENSE="BSD-3-Clause"

OPUS_VERSION=1.6.1
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
OPUS_LICENSE="BSD-3-Clause"

LIBOGG_VERSION=1.3.6
LIBOGG_URL="https://downloads.xiph.org/releases/ogg/libogg-${LIBOGG_VERSION}.tar.xz"
LIBOGG_SHA256=5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061
LIBOGG_LICENSE="BSD-3-Clause"

LIBVORBIS_VERSION=1.3.7
LIBVORBIS_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-${LIBVORBIS_VERSION}.tar.xz"
LIBVORBIS_SHA256=b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b
LIBVORBIS_LICENSE="BSD-3-Clause"

LAME_VERSION=3.100
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz"
LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
LAME_LICENSE="LGPL-2.0-or-later"

# Build tool only, never shipped.
PKGCONF_VERSION=2.5.1
PKGCONF_URL="https://distfiles.ariadne.space/pkgconf/pkgconf-${PKGCONF_VERSION}.tar.xz"
PKGCONF_SHA256=cd05c9589b9f86ecf044c10a2269822bc9eb001eced2582cfffd658b0a50c243

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/vendor/ffmpeg"
WORK="${FFMPEG_WORK_DIR:-$HOME/Library/Caches/MediaShift/ffmpeg-src}"
DOWNLOADS="$WORK/downloads"
BUILD="$WORK/build"
PREFIX="$WORK/prefix"
TOOLS="$WORK/tools"
LOGS="$WORK/logs"
STAMPS="$PREFIX/.stamps"

DEPLOYMENT_TARGET=26.0
JOBS="$(sysctl -n hw.ncpu)"
STEP="starting"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

on_error() {
    local code=$?
    printf '\nerror: the build failed while %s.\n' "$STEP" >&2
    local log="$LOGS/${STEP%% *}.log"
    if [[ -f "$log" ]]; then
        printf 'Last lines of %s:\n' "$log" >&2
        tail -n 25 "$log" >&2
    fi
    exit "$code"
}
trap on_error ERR

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
    STEP="checking the machine"
    [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || die "this build is for Apple Silicon Macs only"
    local tool
    for tool in curl shasum tar make perl otool strip codesign install; do
        command -v "$tool" > /dev/null || die "missing tool: $tool"
    done
    # Fails with a clear message when the Xcode license is not accepted or no toolchain exists.
    xcrun --sdk macosx --show-sdk-path > /dev/null \
        || die "no usable compiler toolchain. Install the Command Line Tools or accept the Xcode license"
    clang --version > /dev/null || die "clang does not run"
}

# ---------------------------------------------------------------------------
# Download, verify, extract
# ---------------------------------------------------------------------------

# value NAME FIELD reads a pinned value such as FFMPEG_URL.
value() {
    local key
    key="$(printf '%s_%s' "$1" "$2" | tr '[:lower:]' '[:upper:]')"
    printf '%s' "${!key}"
}

verify() {
    local file="$1" expected="$2" actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]]
}

# fetch NAME downloads the pinned tarball unless a verified copy is already cached.
fetch() {
    local name="$1" url sha file
    url="$(value "$name" url)"
    sha="$(value "$name" sha256)"
    file="$DOWNLOADS/$(basename "$url")"
    mkdir -p "$DOWNLOADS"

    if [[ -f "$file" ]] && verify "$file" "$sha"; then
        return
    fi
    STEP="downloading $name"
    say "Downloading $(basename "$url")"
    rm -f "$file" "$file.part"
    curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
        --output "$file.part" "$url"
    if ! verify "$file.part" "$sha"; then
        local actual
        actual="$(shasum -a 256 "$file.part" | awk '{print $1}')"
        rm -f "$file.part"
        die "SHA-256 mismatch for $(basename "$url")
       expected $sha
       got      $actual
       The download was discarded. Do not continue unless you have verified the new file."
    fi
    mv "$file.part" "$file"
}

# extract NAME unpacks into a fresh directory and sets SRC to it.
extract() {
    local name="$1" url file
    url="$(value "$name" url)"
    file="$DOWNLOADS/$(basename "$url")"
    SRC="$BUILD/$name"
    rm -rf "$SRC"
    mkdir -p "$SRC"
    tar -xf "$file" -C "$SRC" --strip-components=1
}

# ---------------------------------------------------------------------------
# Build helpers
# ---------------------------------------------------------------------------

# logged NAME COMMAND... runs a command with its output going to logs/NAME.log.
logged() {
    local name="$1"
    shift
    mkdir -p "$LOGS"
    "$@" >> "$LOGS/$name.log" 2>&1
}

already_built() {
    [[ -f "$STAMPS/$1-$(value "$1" version)" ]]
}

mark_built() {
    mkdir -p "$STAMPS"
    touch "$STAMPS/$1-$(value "$1" version)"
}

# autotools NAME CONFIGURE_ARGS... is the common configure, make, make install dance.
autotools() {
    local name="$1"
    shift
    already_built "$name" && return
    fetch "$name"
    STEP="$name build"
    say "Building $name $(value "$name" version)"
    rm -f "$LOGS/$name.log"
    extract "$name"
    cd "$SRC"
    if declare -F "patch_$name" > /dev/null; then
        "patch_$name"
    fi
    logged "$name" ./configure --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-dependency-tracking "$@"
    logged "$name" make -j"$JOBS"
    logged "$name" make install
    cd "$ROOT"
    mark_built "$name"
}

build_pkgconf() {
    if [[ -x "$TOOLS/bin/pkg-config" ]]; then
        return
    fi
    fetch pkgconf
    STEP="pkgconf build"
    say "Building pkgconf $PKGCONF_VERSION (build tool)"
    rm -f "$LOGS/pkgconf.log"
    extract pkgconf
    cd "$SRC"
    logged pkgconf ./configure --prefix="$TOOLS" --disable-shared --enable-static
    logged pkgconf make -j"$JOBS"
    logged pkgconf make install
    ln -sf pkgconf "$TOOLS/bin/pkg-config"
    cd "$ROOT"
}

build_libvpx() {
    already_built libvpx && return
    fetch libvpx
    STEP="libvpx build"
    say "Building libvpx $LIBVPX_VERSION"
    rm -f "$LOGS/libvpx.log"
    extract libvpx
    cd "$SRC"
    logged libvpx ./configure --prefix="$PREFIX" --target=arm64-darwin25-gcc \
        --enable-static --disable-shared --enable-pic \
        --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth --enable-runtime-cpu-detect \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests
    logged libvpx make -j"$JOBS"
    logged libvpx make install
    cd "$ROOT"
    mark_built libvpx
}

build_libwebp() {
    autotools libwebp \
        --enable-libwebpmux --enable-libwebpdemux \
        --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic
}

build_opus() {
    autotools opus --disable-doc --disable-extra-programs
}

build_libogg() {
    autotools libogg
}

# The configure script adds a linker flag the current macOS linker rejects.
patch_libvorbis() {
    sed -i '' 's/-force_cpusubtype_ALL//g' configure
}

build_libvorbis() {
    autotools libvorbis --with-ogg="$PREFIX" --disable-docs --disable-examples --disable-oggtest
}

build_lame() {
    already_built lame && return
    fetch lame
    STEP="lame build"
    say "Building lame $LAME_VERSION"
    rm -f "$LOGS/lame.log"
    extract lame
    cd "$SRC"
    # The export list names a symbol the code no longer defines, which the macOS linker rejects.
    sed -i '' '/lame_init_old/d' include/libmp3lame.sym
    # The bundled config.guess predates Apple Silicon, so name the machine explicitly.
    logged lame ./configure --prefix="$PREFIX" --build=aarch64-apple-darwin --host=aarch64-apple-darwin \
        --disable-shared --enable-static --disable-dependency-tracking \
        --disable-frontend --disable-decoder --disable-gtktest
    logged lame make -j"$JOBS"
    logged lame make install
    cd "$ROOT"
    mark_built lame
}

build_ffmpeg() {
    fetch ffmpeg
    STEP="ffmpeg build"
    say "Building ffmpeg $FFMPEG_VERSION"
    rm -f "$LOGS/ffmpeg.log"
    extract ffmpeg
    cd "$SRC"
    # No --enable-gpl and no --enable-nonfree, on purpose. --disable-autodetect keeps the
    # build from picking up any library that happens to be installed on this machine.
    logged ffmpeg ./configure \
        --prefix="$WORK/ffmpeg-install" \
        --cc=clang --arch=arm64 \
        --pkg-config="$TOOLS/bin/pkg-config" --pkg-config-flags=--static \
        --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" \
        --disable-gpl --disable-nonfree --disable-autodetect \
        --enable-static --disable-shared \
        --enable-zlib --enable-videotoolbox --enable-audiotoolbox \
        --enable-libvpx --enable-libwebp --enable-libopus --enable-libvorbis --enable-libmp3lame \
        --disable-ffplay --disable-ffprobe --disable-doc --disable-network --disable-debug
    logged ffmpeg make -j"$JOBS"

    STEP="installing ffmpeg"
    mkdir -p "$OUT/bin"
    install -m 755 ffmpeg "$OUT/bin/ffmpeg"
    strip -x "$OUT/bin/ffmpeg"
    # Stripping invalidates the signature and Apple Silicon refuses to run unsigned code.
    codesign --force --sign - "$OUT/bin/ffmpeg" > /dev/null 2>&1
    cd "$ROOT"
}

# ---------------------------------------------------------------------------
# Licenses
# ---------------------------------------------------------------------------

# keep_licenses NAME FILE... copies license files out of a component's source tree.
keep_licenses() {
    local name="$1" dir file
    shift
    extract "$name"
    dir="$OUT/licenses/$name"
    mkdir -p "$dir"
    for file in "$@"; do
        [[ -f "$SRC/$file" ]] || die "$name has no $file, its license layout changed"
        cp "$SRC/$file" "$dir/$file"
    done
}

write_licenses() {
    STEP="collecting licenses"
    say "Collecting license texts"
    rm -rf "$OUT/licenses"
    mkdir -p "$OUT/licenses"

    keep_licenses ffmpeg COPYING.LGPLv2.1 LICENSE.md
    keep_licenses libvpx LICENSE PATENTS
    keep_licenses libwebp COPYING PATENTS
    keep_licenses opus COPYING
    keep_licenses libogg COPYING
    keep_licenses libvorbis COPYING
    keep_licenses lame COPYING LICENSE

    {
        echo "This ffmpeg binary was built by scripts/build-ffmpeg.sh from these sources."
        echo "Each archive is fetched from the URL below and checked against its SHA-256."
        echo "ffmpeg is licensed under the LGPL. This build contains no GPL or nonfree code."
        echo "The license text of every component is in the folder named after it."
        echo
        local name
        for name in ffmpeg libvpx libwebp opus libogg libvorbis lame; do
            printf '%s %s\n  license: %s\n  source:  %s\n  sha256:  %s\n\n' \
                "$name" "$(value "$name" version)" "$(value "$name" license)" \
                "$(value "$name" url)" "$(value "$name" sha256)"
        done
    } > "$OUT/licenses/COMPONENTS.txt"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify_binary() {
    STEP="verifying the binary"
    local bin="$OUT/bin/ffmpeg" lib bad=0
    say "Verifying $bin"

    echo "Linked libraries:"
    while read -r lib; do
        echo "  $lib"
        case "$lib" in
            /usr/lib/* | /System/Library/*) ;;
            *) echo "  ^ not a system library" >&2; bad=1 ;;
        esac
    done < <(otool -L "$bin" | tail -n +2 | awk '{print $1}')
    [[ $bad -eq 0 ]] || die "the binary depends on libraries outside macOS"

    local buildconf
    buildconf="$("$bin" -hide_banner -buildconf 2>&1)"
    if grep -qE -e '--enable-(gpl|nonfree|version3)' <<< "$buildconf"; then
        die "the binary was configured with GPL or nonfree options"
    fi

    local license
    # The notice is hard wrapped, so join its first paragraph into one line.
    license="$("$bin" -hide_banner -L 2>&1)"
    license="$(awk 'NF == 0 { exit } { printf "%s ", $0 }' <<< "$license")"
    echo "License: $license"
    grep -q 'GNU Lesser General Public' <<< "$license" || die "ffmpeg does not report the LGPL"

    local encoders encoder
    encoders="$("$bin" -hide_banner -encoders 2>&1)"
    for encoder in libvpx libvpx-vp9 libwebp libwebp_anim libopus libvorbis libmp3lame \
        h264_videotoolbox hevc_videotoolbox aac_at; do
        grep -qE "[[:space:]]${encoder}[[:space:]]" <<< "$encoders" || die "encoder missing: $encoder"
    done

    # A real encode through each software library.
    local scratch
    scratch="$(mktemp -d)"
    "$bin" -hide_banner -loglevel error -f lavfi -i testsrc2=size=160x120:rate=10:duration=1 \
        -f lavfi -i sine=duration=1 -c:v libvpx-vp9 -c:a libopus "$scratch/a.webm" \
        || die "libvpx or libopus failed to encode"
    "$bin" -hide_banner -loglevel error -f lavfi -i sine=duration=1 "$scratch/a.mp3" \
        || die "lame failed to encode"
    "$bin" -hide_banner -loglevel error -f lavfi -i sine=duration=1 -c:a libvorbis "$scratch/a.ogg" \
        || die "libvorbis failed to encode"
    "$bin" -hide_banner -loglevel error -f lavfi -i testsrc2=size=160x120:rate=10:duration=1 -frames:v 1 \
        "$scratch/a.webp" || die "libwebp failed to encode"
    "$bin" -hide_banner -loglevel error -f lavfi -i testsrc2=size=160x120:rate=10:duration=1 \
        -c:v h264_videotoolbox "$scratch/a.mp4" \
        || echo "warning: the VideoToolbox encoder did not run here. It needs a Mac with media hardware."
    rm -rf "$scratch"

    local version
    version="$("$bin" -version 2>&1)"
    echo "Size: $(du -h "$bin" | awk '{print $1}')  $(head -n1 <<< "$version")"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    if [[ "${1:-}" == "--clean" ]]; then
        rm -rf "$BUILD" "$PREFIX" "$LOGS" "$OUT"
    elif [[ -n "${1:-}" ]]; then
        die "unknown option: $1"
    fi

    preflight

    local pins_stamp="$OUT/.built-with"
    local pins
    pins="$(grep -hE '^[A-Z]+_(VERSION|SHA256)=' "${BASH_SOURCE[0]}" | shasum -a 256 | awk '{print $1}')"
    if [[ -x "$OUT/bin/ffmpeg" && -f "$pins_stamp" && "$(cat "$pins_stamp")" == "$pins" ]]; then
        say "vendor/ffmpeg is already current. Use --clean to rebuild."
        exit 0
    fi

    mkdir -p "$WORK" "$LOGS"

    # Keep the build away from Homebrew and anything else on this machine.
    export PATH="$TOOLS/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    export CFLAGS="-O2 -arch arm64"
    export CPPFLAGS="-I$PREFIX/include"
    export LDFLAGS="-L$PREFIX/lib"
    export PKG_CONFIG="$TOOLS/bin/pkg-config"
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
    unset PKG_CONFIG_PATH

    build_pkgconf
    build_libogg
    build_libvorbis
    build_opus
    build_libvpx
    build_libwebp
    build_lame
    build_ffmpeg
    write_licenses
    verify_binary

    echo "$pins" > "$pins_stamp"
    say "Done: $OUT/bin/ffmpeg"
}

main "$@"

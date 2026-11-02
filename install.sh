#!/bin/zsh
# Installs MediaShift, the file converter for the Mac menu bar, with one line in Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/rightform/mediashift/main/install.sh | zsh
#   npx @rightform/mediashift
#
# When GitHub has a published release, this downloads its disk image, checks it against the
# SHA-256 GitHub lists for the file and copies the app into Applications. Until then, or with
# --build, it builds the app from the source on GitHub, as the README's longer steps do, and
# installs that. Nothing here needs more than macOS and Apple's free developer tools.
#
#   --build      build from source even when a release exists
#   --no-open    leave the app closed after installing
#
# MEDIASHIFT_APPLICATIONS sets the folder the app goes into, and MEDIASHIFT_REPO and
# MEDIASHIFT_RELEASES_URL point at another copy of the project.

usage() {
    print -r -- "usage: install.sh [--build] [--no-open]"
}

say() {
    print -r -- "$*"
}

step() {
    if [[ -t 1 ]]; then
        print -r -- $'\n\e[1m'"==> $*"$'\e[0m'
    else
        print -r -- $'\n'"==> $*"
    fi
}

fail() {
    print -u2 -r -- $'\n'"MediaShift was not installed: $*"
    clean_up
    exit 1
}

# The folder for downloads and unpacked files, removed at the end either way.
typeset -g work=""

clean_up() {
    if [[ -n $work ]]; then
        rm -rf "$work"
    fi
}

# Sets `app` to the downloaded app, or returns 1 when there is no release to download.
download_release() {
    local url=$1 work=$2
    step "Looking for a published release"
    if ! curl -fsSL -H "Accept: application/vnd.github+json" -o "$work/release.json" "$url" 2> /dev/null; then
        say "There is no published release yet, so MediaShift is built on this Mac instead."
        return 1
    fi

    local index=0 name image="" link="" digest=""
    while name=$(plutil -extract "assets.$index.name" raw -o - "$work/release.json" 2> /dev/null); do
        if [[ $name == *.dmg ]]; then
            image=$name
            link=$(plutil -extract "assets.$index.browser_download_url" raw -o - "$work/release.json")
            digest=$(plutil -extract "assets.$index.digest" raw -o - "$work/release.json" 2> /dev/null || true)
            break
        fi
        (( index += 1 ))
    done
    if [[ -z $image ]]; then
        say "The newest release has no disk image, so MediaShift is built on this Mac instead."
        return 1
    fi
    [[ $digest == sha256:* ]] || fail "GitHub lists no checksum for $image, so it cannot be checked."

    step "Downloading $image"
    curl -fL --progress-bar -o "$work/$image" "$link" || fail "the download did not finish. Check the connection and run the line again."
    local actual
    actual=$(shasum -a 256 "$work/$image" | awk '{ print $1 }')
    [[ $actual == "${digest#sha256:}" ]] || fail "the download does not match its checksum. Run the line again."
    say "The download matches its SHA-256 checksum."

    mkdir -p "$work/volume"
    # Newer systems call hdiutil deprecated in favor of diskutil image, which macOS 15 lacks.
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$work/volume" "$work/$image" > /dev/null 2>&1 \
        || fail "the disk image could not be opened."
    ditto "$work/volume/MediaShift.app" "$work/MediaShift.app" || fail "the app could not be copied out of the disk image."
    hdiutil detach "$work/volume" -quiet || true
    typeset -g app="$work/MediaShift.app"
}

# Uses the Command Line Tools, or Xcode when its license is accepted, and installs the tools
# when neither is there. The Command Line Tools come first: they need no license step.
developer_tools() {
    local tools=/Library/Developer/CommandLineTools
    if [[ -x $tools/usr/bin/swift ]]; then
        export DEVELOPER_DIR=$tools
    elif ! xcrun swift --version > /dev/null 2>&1; then
        step "Installing Apple's free developer tools"
        say "A window asks to install them. Click Install and wait. This continues by itself once they are in place."
        xcode-select --install > /dev/null 2>&1 || true
        local waited=0
        until [[ -x $tools/usr/bin/swift ]]; do
            sleep 10
            (( waited += 10 ))
            (( waited < 3600 )) || fail "the developer tools did not arrive within an hour. Install them with: xcode-select --install"
        done
        export DEVELOPER_DIR=$tools
    fi

    local sdk major
    sdk=$(xcrun --sdk macosx --show-sdk-version 2> /dev/null || true)
    major=${sdk%%.*}
    if [[ $major != <-> ]] || (( major < 26 )); then
        fail "building needs the macOS 26 SDK or newer, and these developer tools have ${sdk:-none}. Update macOS and the developer tools in System Settings, under General, Software Update."
    fi
}

# Sets `app` to a fresh build of the main branch.
build_from_source() {
    local repo=$1 work=$2
    local caches=$HOME/Library/Caches/MediaShift
    local source=$caches/installer/mediashift
    developer_tools

    step "Getting the source from github.com/$repo"
    curl -fsSL -o "$work/source.tar.gz" "https://github.com/$repo/archive/refs/heads/main.tar.gz" \
        || fail "the source could not be downloaded. Check the connection and run the line again."
    mkdir -p "$work/source"
    tar -xzf "$work/source.tar.gz" -C "$work/source" --strip-components 1
    # The media engine takes most of the build and rarely changes, so an earlier build of it
    # stays. Its own script rebuilds it when its pinned sources change.
    if [[ -d $source/vendor ]]; then
        mv "$source/vendor" "$work/source/vendor"
    fi
    rm -rf "$source"
    mkdir -p "${source:h}"
    mv "$work/source" "$source"

    step "Building the media engine. The first time takes several minutes, and text scrolling past is normal."
    (cd "$source" && make ffmpeg) || fail "the media engine did not build. The messages above say why."
    step "Building MediaShift"
    (cd "$source" && make app) || fail "the app did not build. The messages above say why."
    typeset -g app="$caches/dist/MediaShift.app"
}

install_app() {
    local built=$1 open=$2
    local folder=${MEDIASHIFT_APPLICATIONS:-/Applications}
    # Applications needs an administrator account. Anyone else gets their own Applications folder.
    if [[ -z ${MEDIASHIFT_APPLICATIONS:-} && ! -w /Applications ]]; then
        folder=$HOME/Applications
    fi
    mkdir -p "$folder"
    local target=$folder/MediaShift.app

    # A copy running from there is closed first, so the new one can take its place.
    local pid running=0
    for pid in $(pgrep -x MediaShift 2> /dev/null || true); do
        if [[ $(ps -p "$pid" -o comm= 2> /dev/null) == "$target"/* ]]; then
            running=1
        fi
    done
    if (( running )); then
        osascript -e 'tell application id "pl.rightform.mediashift" to quit' > /dev/null 2>&1 || true
        local waited=0
        while pgrep -f "$target/Contents/MacOS/MediaShift" > /dev/null && (( waited < 10 )); do
            sleep 1
            (( waited += 1 ))
        done
        pkill -f "$target/Contents/MacOS/MediaShift" 2> /dev/null || true
    fi

    step "Installing into $folder"
    rm -rf "$target.new"
    ditto "$built" "$target.new" || fail "the app could not be copied into $folder."
    rm -rf "$target"
    mv "$target.new" "$target"

    local version
    version=$(plutil -extract CFBundleShortVersionString raw -o - "$target/Contents/Info.plist" 2> /dev/null || true)
    if (( open )); then
        open "$target"
    fi
    say ""
    say "MediaShift ${version:-} is in $folder."
    say "It lives in the menu bar at the top of the screen, as a small dot circled by six smaller ones."
    say "To convert a file, start dragging it in the Finder and tap Shift."
}

# Everything runs from here, on the last line, so a download cut short runs nothing.
main() {
    emulate -L zsh
    setopt err_exit pipe_fail no_unset

    local repo=${MEDIASHIFT_REPO:-rightform/mediashift}
    local releases=${MEDIASHIFT_RELEASES_URL:-https://api.github.com/repos/$repo/releases/latest}
    local build=0 open=1 argument
    for argument in "$@"; do
        case $argument in
            --build) build=1 ;;
            --no-open) open=0 ;;
            -h | --help) usage; return 0 ;;
            *) usage; fail "there is no option $argument." ;;
        esac
    done

    [[ $(uname -s) == Darwin ]] || fail "MediaShift runs on macOS only."
    local system
    system=$(sw_vers -productVersion)
    (( ${system%%.*} >= 15 )) || fail "MediaShift needs macOS 15 or later, and this Mac has macOS $system."

    work=$(mktemp -d -t mediashift)
    typeset -g app=""
    if (( build )) || ! download_release "$releases" "$work"; then
        build_from_source "$repo" "$work"
    fi
    install_app "$app" "$open"
    clean_up
}

main "$@"

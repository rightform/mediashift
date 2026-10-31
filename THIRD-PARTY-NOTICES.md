# Third-party notices

## Swift packages

| Package | License | Source |
| --- | --- | --- |
| ZIPFoundation | MIT | https://github.com/weichsel/ZIPFoundation |
| swift-markdown | Apache 2.0 | https://github.com/swiftlang/swift-markdown |
| swift-cmark | BSD 2-Clause | https://github.com/swiftlang/swift-cmark |

## Bundled with the app

The app ships a statically linked `ffmpeg` executable. It runs as a separate program and is built by [`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh) with no GPL or non-free components. That script names the exact source versions and checksums, so the same binary can be rebuilt or replaced. The full license texts are in `Contents/Resources/licenses` inside the app.

| Component | License | Source |
| --- | --- | --- |
| FFmpeg | LGPL 2.1 or later | https://ffmpeg.org |
| LAME | LGPL 2.0 or later | https://lame.sourceforge.io |
| libvpx | BSD 3-Clause | https://github.com/webmproject/libvpx |
| libwebp | BSD 3-Clause | https://github.com/webmproject/libwebp |
| Opus | BSD 3-Clause | https://opus-codec.org |
| libogg, libvorbis | BSD 3-Clause | https://xiph.org |

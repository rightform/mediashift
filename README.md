# MediaShift

A native Mac file converter that gets out of the way. Hold Shift while dragging a file and formats appear around the pointer. Drop it on one. The result lands next to the original.

Free, open source, and fully offline: no account, no telemetry, and no file ever leaves your Mac.

Made by [rightform](https://rightform.pl).

## What it does

**Convert** between

| Family | Formats |
| --- | --- |
| Documents | TXT, Markdown, RTF, HTML, DOCX, DOC (read), ODT, EPUB, Pages, PDF |
| Spreadsheets | XLSX, CSV, TSV, Numbers (read) |
| Presentations | PPTX, Keynote (read) |
| Images | JPEG, PNG, HEIC, WebP, AVIF, TIFF, GIF, BMP |
| Video | MP4, MOV, M4V, MKV, WebM, AVI (read) |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF |

Office and iWork files do not need Office or iWork to be installed. Scanned PDFs and images are read with on-device text recognition.

**Compress** images, audio, video and PDF, by strength or down to a size you set.

**Remove metadata** from images, audio, video, PDF and Office files: GPS position, camera, author, company and timestamps.

Originals are never changed, and a new file never replaces an existing one.

## Using it

- **The wheel:** hold Shift while dragging files from anywhere, or tap it at any moment during the drag. Drop on a format, or back in the middle to cancel.
- **The menu bar:** drop files on the icon, or open it and choose files. Everything the wheel does is available there from the keyboard, along with progress and history.
- **The command line:** the tool ships inside the app. To use it from anywhere, link it once:

```bash
sudo ln -s /Applications/MediaShift.app/Contents/Helpers/mediashift /usr/local/bin/mediashift
```

Then:

```bash
mediashift report.docx --to pdf
```

```bash
mediashift holiday/*.heic --to jpeg --out converted
```

```bash
mediashift talk.mov --compress strong
```

```bash
mediashift photo.jpg --strip-metadata
```

## Settings

- **General:** open at login, how many conversions run at once, and what happens when they finish.
- **Wheel:** the key that opens it (Shift, Control, Option or Command), haptic feedback, and which formats appear on it.
- **Output:** where results go, what is added to their names, metadata removal, compression strength and a size limit.
- **Images:** quality and largest size.
- **Video & Audio:** codec, quality, largest resolution, GIF size and frame rate, and audio bitrate.
- **Documents:** PDF page size, the resolution of pages turned into images, and text recognition for scans.

## Building

The app runs on macOS 15 or later, on Apple Silicon and Intel. Building it takes the macOS 26 SDK or newer, from Xcode or just the Command Line Tools.

```bash
make ffmpeg
```

```bash
make test
```

```bash
make app
```

`make ffmpeg` builds the media engine from pinned, verified sources and is needed once. Without it, the tests that depend on it are skipped. `make app` prints the location of the finished app.

Both build for Apple Silicon and Intel in one go. `FFMPEG_ARCHS=arm64 make ffmpeg` and `APP_ARCHS=arm64 make app` build one architecture only, which is much quicker while developing.

## How it is built

```
MediaShiftApp     menu bar, wheel, settings (SwiftUI and AppKit)
mediashift        command line tool
      \           /
      ConversionKit       one entry point, the catalog of what converts to what
      /     |      \
DocumentEngine  OfficeFormats  MediaEngine
      \     |      /
      ConversionCore      formats, the document model, errors
```

Documents do not convert to each other directly. Every reader produces a `RichDocument`, and every writer consumes one, so a new format means one reader or one writer rather than a converter for every other format. PDFs of Office and iWork files are the exception: they come from the system's own Quick Look renderer, which knows their fonts and layout, with the shared model as a fallback.

Images go through ImageIO, and audio and video through ffmpeg with the Mac's hardware encoders.

## Limits worth knowing

- The document model keeps structure and common text styling, such as headings, lists, tables, images, links, bold and colour. It does not keep page layout, so a converted file will not match a designed original exactly.
- RTF and ODT output carry text and tables, but images are not preserved.
- PDF to text formats recovers text and headings, not layout.
- The first text recognition after installing takes about 25 seconds while macOS prepares its model. After that it is immediate.
- Written Pages files hold text and heading styles, so images and tables become text.
- HEIC and AVIF are offered only where macOS can write them, which depends on the system and the chip. AVIF may be missing on older systems and on Intel.
- Intel support is new and less tested than Apple Silicon. Video encoding on Intel Macs is slower too.
- The wheel uses Liquid Glass on macOS 26 and later, and a system material on macOS 15.
- The app is not notarized yet, so macOS asks for confirmation on first launch: open it, then allow it under System Settings, Privacy & Security.

## License

[MIT](LICENSE). The bundled ffmpeg is built without GPL components and is licensed under the LGPL. See [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES.md).

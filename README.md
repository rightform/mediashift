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

- **The wheel:** hold Shift while dragging files from anywhere. Drop on a format, or back in the middle to cancel.
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

## Building

Requires macOS 26 or later on Apple Silicon, with Xcode or just the Command Line Tools.

```bash
make test
```

```bash
make ffmpeg
```

```bash
make app
```

`make ffmpeg` builds the media engine from pinned, verified sources and is needed once. `make app` prints the location of the finished app.

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

Images go through ImageIO, and audio and video through ffmpeg with the Apple Silicon hardware encoders.

## Limits worth knowing

- The document model keeps structure and common text styling, such as headings, lists, tables, images, links, bold and colour. It does not keep page layout, so a converted file will not match a designed original exactly.
- RTF and ODT output carry text and tables, but images are not preserved.
- PDF to text formats recovers text and headings, not layout.
- The first text recognition after installing takes about 25 seconds while macOS prepares its model. After that it is immediate.
- Written Pages files hold text and heading styles, so images and tables become text.
- The app is not notarized yet, so macOS asks for confirmation on first launch: open it, then allow it under System Settings, Privacy & Security.

## License

[MIT](LICENSE). The bundled ffmpeg is built without GPL components and is licensed under the LGPL. See [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES.md).

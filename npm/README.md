# MediaShift installer

Installs [MediaShift](https://github.com/rightform/mediashift), a free file converter that lives in the Mac menu bar. Drag a file, tap Shift, pick a format.

```bash
npx @rightform/mediashift
```

It needs macOS 15 or later. When a release is published on GitHub, the installer downloads it, checks it against the SHA-256 GitHub lists for the file and copies the app into Applications. Until then it builds the app on your Mac from the source on GitHub, which takes a few minutes the first time and installs Apple's free developer tools if they are missing.

- `--build` builds from source even when a release exists.
- `--no-open` leaves the app closed after installing.

Without Node.js, the same installer runs with one line in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/rightform/mediashift/main/install.sh | zsh
```

Made by [rightform](https://rightform.pl). MIT license.

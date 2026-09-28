# BatchPrint

A small native macOS app for printing a batch of files under one set of rules.

[中文文档](README.zh-CN.md)

Drop in a folder of receipts, invoices, tickets or screenshots, set the scale and paper
once, then send the whole queue to the printer as a single job. It was written for the
month-end expenses case — 80% scale by default so nothing gets clipped when the pages are
bound, centered on A4, and filenames that stay readable while you check the list.

![BatchPrint](screenshots/01-default.png)

## What it does

- **One queue, many formats** — PDF, images (PNG / JPG / JPEG / TIFF / GIF / BMP / HEIC / HEIF / WEBP)
  and Office or text files (doc/docx, xls/xlsx, ppt/pptx, odt/ods/odp, rtf, txt, csv).
- **One set of rules** — scale (fit / actual size / custom 50–100%), paper (A4 / Letter / A5),
  margins, duplex.
- **Per-file overrides** — page range, copies, and rotation, each file on its own.
- **Live preview** — the selected file is re-rendered with the current settings as you change them.
- **Export instead of printing** — write the scaled PDFs to a folder first and check the layout.
- **Built as a print queue, not a file manager** — the list answers "what am I about to print,
  and which files have settings that differ from the default".

More states: [`screenshots/`](screenshots) — default, hover, rotated, changed settings, dark mode, empty.

## Requirements

- **macOS 26 (Tahoe) or later.** The UI uses `glassEffect` and `containerBackground`, so it
  neither builds nor runs on earlier versions.
- **Apple Silicon.** The build target is `arm64-apple-macos26.0`; Intel isn't tested.
- Optional: **LibreOffice**, only if you want to print Office or text files. Without it those
  files are skipped when you add them.

## Install

1. Download `BatchPrint-1.3.dmg` from the [latest release](releases/latest) and open it.
2. Drag the app into `Applications`.
3. **First launch:** the app is ad-hoc signed, not notarized — notarization needs a paid Apple
   Developer account. macOS will refuse to open it the usual way. Either:
   - right-click the app → **Open** → **Open**, or
   - run `xattr -dr com.apple.quarantine "/Applications/批量打印工具.app"`

   If you would rather not bypass Gatekeeper, build it yourself with `./build.sh --install`
   and skip the download.

## Build from source

```bash
./build.sh              # → dist/批量打印工具.app
./build.sh --install    # also installs to ~/Applications and opens it
./build.sh --package    # also produces dist/BatchPrint-<version>.dmg and .zip
```

You need Xcode or the Command Line Tools for the macOS 26 SDK; the script locates the SDK by
itself (`xcrun --show-sdk-path`). `VERSION=`, `BUILD_NUM=`, `ARCH=` and `SDK=` override the defaults.

## Notes

- Printing goes through CUPS `lp`. The app does the scaling itself while building the PDF
  instead of relying on driver-side scaling, which varies between printers.
- The preview, the export and the print job share one PDF pipeline, so what you see in the
  preview is what comes out of the printer.
- No telemetry and no network calls. Files are read locally and never modified.
- The implementation is a single Swift file, `src/App.swift`. There is no dependency and no
  package manager step.

## Repository layout

```
src/App.swift             the whole app
build.sh                  build + package + sign
assets/AppIcon.icns       app icon
screenshots/              real screenshots used by this README and the release
design/                   the three HTML prototypes the queue layout went through
tools/scalepdf.swift      an early standalone CLI for scaling a PDF
legacy/                   the very first AppKit version, kept for reference
```

## License

MIT — see [LICENSE](LICENSE).

This tool solves one narrow problem: printing a stack of vouchers under a single set of rules.
If your case is different, an issue describing where you get stuck is welcome.
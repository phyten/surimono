# Surimono

> Open it casually, glance at it, print it right away.
> 雑に開いて、雑に見て、さっと刷る。

**Surimono** is a macOS app for quickly viewing and printing everyday documents and images — Markdown, PDF, images, Org, plain text and HTML. It is built around printing: swappable print stylesheets, HTML noise-removal presets, and saddle-stitch booklet printing (two A4 pages side by side on A3, printed double-sided, folded and stapled in the middle).

The name comes from *surimono* (摺物), privately commissioned Japanese woodblock prints; *suru* (摺る) means "to print".

[日本語の README はこちら](README.ja.md)

> [!NOTE]
> Surimono is in early development. Nothing has been released yet.

## Why

Printing a Markdown note, an Org file or a long HTML article on a Mac usually means a detour through a browser, an editor plugin or a PDF tool. Surimono aims to make it a two-step job: open the file, press Print.

## Features

- Quick viewer for Markdown, PDF, images, Org, plain text, HTML, and CSV
- Open multiple images together as one image bundle, including mixed image formats
- Reorder images by dragging thumbnails or with Option-Command-Up/Down
- Export an image bundle as a PDF in its current order and print layout
- WYSIWYG print preview: what you see is how the paper comes out
- Swappable print stylesheets for Markdown, Org and text, including your own CSS
- HTML noise-removal presets (navigation, ads, sidebars, cookie banners, …) that you can extend
- Print layouts: A4 single-sided, A4 double-sided, and saddle-stitch booklets (A3 → A4 booklet, A4 → A5 booklet), plus A3 2-up
- Quick print without a dialog, and PDF export (for example, for convenience-store printers)
- A borderless view: only the paper, with a menu that appears when you point at the window; spread, single-page and two-page scroll views; zoom without losing sharpness
- Settings you change are remembered per document by its content (SHA-256), not its name; image bundles by the set of images
- Open a ZIP of images as one image bundle (images in nested folders, sorted by name; never extracted to disk)
- Keep a window floating on top of other apps
- Follows the system light / dark appearance

## Supported formats

| Format | Extensions |
|---|---|
| Markdown | `.md`, `.markdown` |
| PDF | `.pdf` |
| Images | `.png`, `.jpg`, `.heic`, `.gif`, `.tiff`, `.webp`, … |
| Org | `.org` |
| Plain text | `.txt` and other text files |
| HTML | `.html`, `.htm` |
| CSV / TSV | `.csv`, `.tsv` |
| ZIP of images | `.zip` (opened as one image bundle) |

## Requirements

- macOS 15 Sequoia or later

## Building from source

Requires macOS 15 or later and Xcode 26 or later (Swift 6.2 or later). Select Xcode as the active developer directory before building. CI uses Xcode 26.6; local development also supports Xcode 27.

```bash
make build                      # Debug build in build/DerivedData
make run FILE=Samples/sample.md # Build and open a document
make lint                       # Check Swift formatting
make format                     # Format Swift sources
make test                       # Package tests and hosted app tests
make test-kit                   # Package tests only
make test-app                   # Hosted app tests only
make package                    # Release ZIP and SHA-256 in build/release
make clean                      # Remove build products
```

You can also open `Surimono.xcodeproj` and use the shared `Surimono` scheme. Override `CONFIGURATION` or `DERIVED_DATA` for builds, and `VERSION` / `BUILD_NUMBER` for packaging. The app is ad-hoc signed; no developer account is required. The app connects document conversion, print preview, printing, and PDF export through SurimonoKit.

Sample documents in `Samples/` cover Markdown, Org, UTF-8 and Shift_JIS text, HTML, and CSV. `booklet-demo.md` is a long, image-free document for checking booklet page order. Settings include print margins, page numbers, back-side rotation, and JavaScript for HTML. Add CSS in `~/Library/Application Support/Surimono/Styles/` and JSON presets in `Presets/`, then reload them in Settings. Open documents automatically reload after external saves; source files are never edited.

## Contributing

Issues and pull requests are welcome, in English or Japanese. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © 2026 phyten

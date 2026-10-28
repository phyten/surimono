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

## Planned features

- Quick viewer for Markdown, PDF, images, Org, plain text and HTML (CSV later)
- WYSIWYG print preview: what you see is how the paper comes out
- Swappable print stylesheets for Markdown, Org and text, including your own CSS
- HTML noise-removal presets (navigation, ads, sidebars, cookie banners, …) that you can extend
- Print layouts: A4 single-sided, A4 double-sided, and saddle-stitch booklets (A3 → A4 booklet, A4 → A5 booklet)
- Quick print without a dialog, and PDF export (for example, for convenience-store printers)
- One-click light / dark appearance switch

## Supported formats (planned)

| Format | Extensions |
|---|---|
| Markdown | `.md`, `.markdown` |
| PDF | `.pdf` |
| Images | `.png`, `.jpg`, `.heic`, `.gif`, `.tiff`, `.webp`, … |
| Org | `.org` |
| Plain text | `.txt` and other text files |
| HTML | `.html`, `.htm` |

## Requirements

- macOS 15 Sequoia or later (planned)

## Building from source

Build instructions will be added together with the Xcode project.

## Contributing

Issues and pull requests are welcome, in English or Japanese. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © 2026 phyten

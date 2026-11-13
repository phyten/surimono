# Surimono

[![DMG downloads](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fphyten%2Fsurimono%2Fstats%2Fdownloads-dmg.json)](https://github.com/phyten/surimono/releases) [![ZIP downloads](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fphyten%2Fsurimono%2Fstats%2Fdownloads-zip.json)](https://github.com/phyten/surimono/releases)

> Open it casually, glance at it, print it right away.
> 雑に開いて、雑に見て、さっと刷る。

**Surimono** is a macOS app for quickly viewing and printing everyday documents and images — Markdown, PDF, images, Org, plain text, HTML and LaTeX. It is built around printing: **108 print styles**, HTML noise-removal presets, and saddle-stitch booklet printing (two A4 pages side by side on A3, printed double-sided, folded and stapled in the middle).

**108 styles to print in** — from letters and reports to woodblock-print headings and a sports-day programme — picked from samples of your own document's first page.

The name comes from *surimono* (摺物), privately commissioned Japanese woodblock prints; *suru* (摺る) means "to print".

[日本語の README はこちら](README.ja.md)

> [!NOTE]
> Surimono is in early development.

## Why

Printing a Markdown note, an Org file or a long HTML article on a Mac usually means a detour through a browser, an editor plugin or a PDF tool. Surimono aims to make it a two-step job: open the file, press Print.

## Features

- Open copied Markdown, text, HTML source, or images directly from the clipboard with ⌘N, without saving a source file
- Open or print selected text from any app with the Services menu (Open in Surimono, Print with Surimono). It stays in memory until you choose Save as File…
- Bind a Markdown file's parts: `<<[file]` (Marked), `{{file}}` (MultiMarkdown), `/file` (iA Writer), or a SUMMARY.md of links open as a binder when you ask, with the parent's text as a preface
- Streaming Preview, compatible with [Marked's](https://markedapp.com/help/Streaming_Preview): apps that write to the `mkStreamingPreview` pasteboard appear live, without a file (the base URL for relative images is not used)
- Syntax highlighting for Markdown and Org code blocks, plus Markdown callouts (`:::` and `> [!note]`) with a tag, an icon and a line of their own that tell the kinds apart even in black and white, rendered offline without JavaScript
- Extended Markdown: footnotes, `==highlight==`, `^superscript^` and `~subscript~`, ruby `{漢字|かんじ}`, emoji `:tada:`, definition lists, heading ids and a `[TOC]` table of contents
- Mermaid diagrams in Markdown (```` ```mermaid ````) and Org (`#+begin_src mermaid`) rendered as printable SVG offline. Invalid diagrams keep their source and appear in the preflight checks.
- Math in Markdown (`$…$`, `$$…$$`, ```` ```math ````) typeset without JavaScript by [SwaTex](https://github.com/PhraseHQ/SwaTex), a KaTeX-compatible engine in pure Swift, including chemistry (mhchem)
- Quick viewer for Markdown, PDF, images, Org, plain text, HTML, CSV, and LaTeX
- LaTeX documents printed with the styles: titles, numbered sections and references, lists (enumitem), code (listings), math through SwaTex with equation numbers, footnotes, hyperref, xcolor, figures (graphicx), tables (booktabs), theorems and proofs (amsthm), the bibliography and citations, and units (siunitx). Surimono reads the common subset rather than running TeX; TikZ pictures are marked where they would be
- Combine Markdown, Org, text, CSV, LaTeX, HTML, PDFs, and images into one binder: drop files on an open window or use Add Documents…, reorder, remove, and print or export as one PDF or booklet, optionally starting each document on an odd page. A binder you close stays in File > Recent Binders.
- Open multiple images together as one image bundle, including mixed image formats
- Reorder images by dragging thumbnails or with Option-Command-Up/Down
- Export an image bundle as a PDF in its current order and print layout
- A print screen that lays out the sheets as they come out of the printer — fronts and backs side by side, booklet sheets with their fold, and a "See It Folded" preview that turns the pages of the folded booklet. Pinch, ⌘-scroll, double-click or ⌘+ / ⌘− zoom around the pointer up to twice the real size, and a drag moves sheets that do not fit (the printed size stays the same)
- 108 print stylesheets for Markdown, Org, text, CSV and LaTeX in 12 categories (everyday, Japanese, business, academic, technical, reading, notes, print-friendly, retro, pop, seasons, kids), chosen from a palette of samples of your document's first page — in one searchable, scrolling list: Recent, Favorites and Suggested, followed by categories and your own styles — that, in the viewing screen, tries a style on the paper as you point at it, or by laying up to four side by side from the same heading or code, plus your own CSS. A LaTeX-style one sets the text in Computer Modern (the bundled KaTeX fonts) with LaTeX's numbered sections and indented paragraphs. Some playful styles sprinkle emoji that stay the same for a document on screen and on paper
- Text size from 80% to 200% layered over any style for Markdown, Org, text, CSV, and LaTeX; keeps the window and paper size, with the same result in print and PDF export
- Open the style palette from either the viewing screen or the print screen. Switch between **This Document** and a bundled **Sample Document** with headings, paragraphs, lists, a table, code and a quotation; the choice is remembered across the app. The specimen is Japanese for a Japanese UI and English otherwise. In the viewing screen, hovering tries the style on the paper. In the print screen, hovering enlarges only the sample beside the list; clicking chooses the style, records it in Recent and lays out the sheets. The palette stays open for comparison and closes with Esc or a click outside. A brief hint appears beside the style button on the first eligible visit to the print screen.
- Code colors apart from the style: 12 palettes, plus the frame, line numbers, long lines and the language name
- HTML noise-removal presets (navigation, ads, sidebars, cookie banners, …) that you can extend
- Smart Removal (beta) for HTML: finds ads, recommended articles, share buttons, cookie banners and the like, removes them, and lets you review and keep any of them; detection runs on your Mac only
- Before printing, checks show unreadable images, overly wide blocks, formula errors, and unsupported LaTeX with their pages and suggested fixes. Documents without issues gain no extra controls; printing is never blocked.
- Print layouts: single-sided and duplex A4, B5, and Letter; saddle-stitch booklets A3 → A4, A4 → A5, B4 → B5, B5 → B6, Tabloid → Letter, and Letter → Half Letter. Choose left or right binding in Print Settings.
- Put two pages on A3 / A4, B4 / B5, or Tabloid / Letter, or four pages on portrait A4, B5, or Letter (top left, top right, bottom left, bottom right). Choose the paper and page count below the 2-up card. Each paper family also offers three pages plus notes. With no saved default layout, the region and default printer paper determine whether A sizes or Letter are offered first.
- Print settings, added only when printing and never to the document: margins on each side (inside and outside too), header and footer, page breaks by heading and chapters from the right-hand page, and contents added to the paper
- Note pages to write on: on one side of each spread, behind each page or after each chapter. 17 templates such as college ruled, grid, manuscript paper and cute patterns, with line style, thickness, spacing and color you can adjust and save. They work with PDFs and images too
- Print straight to the printer chosen on the print screen, without a dialog (the system print dialog is one step away), and PDF export (for example, for convenience-store printers)
- Layouts the chosen printer cannot do (a paper it does not take, no two-sided printing) carry a small badge; Print then opens the system print dialog instead of sending right away
- Remembers back-side rotation separately for long-edge and short-edge binding, and print order, for each printer. A one-sheet duplex test helps check and save the back-side orientation.
- A view with the toolbar outside the paper, always shown (**View › Always Show Toolbar**, ⌥⌘T) or only when you point at it, over the paper’s edge, so that the window is the paper alone; spread and single-page views; zoom without losing sharpness. The mouse wheel and trackpad turn pages with the chosen effect (fade, slide, curl, cover, reveal, wipe, zoom) at an adjustable sensitivity; in Markdown and the other themed formats, single-page scrolling can join pages by hiding the margins where they meet; a lone last page of a spread sits on its side; and page numbers can be turned on for view mode and for print separately, set in the bottom margin (never in single-page scrolling)
- **Help › Keys and Gestures** and the toolbar’s **… › Keys and Gestures** open the same guide: Tab / M for the toolbar, ⌥⌘T to always show it, V for view options, T for text selection, Option to swap drag behavior, edge clicks and double-click zoom, pinch and ⌘-scroll zoom, ⌘F to find in the document (⌘G / ⇧⌘G for the next and previous match), ⌥⌘G to go to a page, ⌘R to reload, plus printing with ⌘P / ⌥⌘P / ⌘1–⌘6 and returning with Esc. The guide includes when each paper gesture works
- Save named **setting sets** and apply print layout, orientation, margins, page numbers, style and text size, or an HTML cleanup preset to another document; rename or delete sets in Settings.
- Open defaults for new documents and app-wide settings from **Surimono › Settings…** (⌘,). Actions on the current document live in the View and Document menus
- Settings you change are remembered per document by its content (SHA-256), not its name; image bundles by the set of images
- Open a ZIP of images as one image bundle (images in nested folders, sorted by name; never extracted to disk)
- Keep a window floating on top of other apps (**View › Float on Top**)
- Follows the system light / dark appearance

## From Finder and Shortcuts

- **Finder**: select files, then choose Services → Print with Surimono (in the Finder menu, or at the end of the context menu). The files open in the print mode with the sheets laid out; nothing goes to the printer until you press Print. One file opens as a document, several images as an image bundle, and other mixes as a binder. If the item is missing, turn it on in System Settings → Keyboard → Keyboard Shortcuts → Services.
- **Shortcuts**: two actions, with no extra app to install.
  - *Export PDF with Surimono* takes a file and returns the PDF of its sheets. Choose a layout (A4 booklet, 2-up, …) and a style by name, or leave them empty for the defaults in Surimono's settings. It runs without a window. Nothing is written next to your file or into your folders: the intermediate files stay in the app's temporary directory and are removed, and the PDF is handed back in memory.
  - *Open in Surimono's Print Mode* opens files in the print mode, as the Finder service does. A file made by an earlier action exists only while the shortcut runs, so one such file opens from memory; save several of them (or a ZIP) with Save File first.

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
| LaTeX | `.tex`, `.latex`, `.ltx` |
| ZIP of images | `.zip` (opened as one image bundle) |

## Requirements

- macOS 15 Sequoia or later

## Install

1. Download `Surimono-<version>.dmg` from the [latest release](https://github.com/phyten/surimono/releases/latest), open it, and drag Surimono to Applications.
2. Surimono is not notarized by Apple yet, so macOS blocks the first launch. Follow the steps in the release notes (System Settings > Privacy & Security > Open Anyway). Later launches open normally.

Surimono updates itself. Choose **Surimono > Check for Updates…**, or let it check automatically on every launch and once a day while it runs: it asks on the second launch, and Settings > General turns it on or off. Updates are signed and verified before they are installed. Checking downloads a small feed from GitHub; nothing about your documents is sent.

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
make package                    # Release DMG and ZIP with SHA-256 in build/release
make clean                      # Remove build products
```

You can also open `Surimono.xcodeproj` and use the shared `Surimono` scheme. Override `CONFIGURATION` or `DERIVED_DATA` for builds, and `VERSION` / `BUILD_NUMBER` for packaging (for a prerelease such as `0.2.0-beta.1`, also set `MARKETING_VERSION=0.2.0`). The app is ad-hoc signed; no developer account is required. The app connects document conversion, print preview, printing, and PDF export through SurimonoKit.

Sample documents in `Samples/` cover Markdown, Org, UTF-8 and Shift_JIS text, HTML, and CSV. `booklet-demo.md` is a long, image-free document for checking booklet page order, and `callouts.md` shows every kind of callout. Settings include print margins, page numbers, back-side rotation, and JavaScript for HTML. Add CSS in `~/Library/Application Support/Surimono/Styles/` and JSON presets in `Presets/`, then reload them in Settings. For Markdown and the other themed formats, a background a style (your CSS included) gives `html`, such as a paper tint or ruling, covers the margins too, with its pattern starting at the top left of the text (a document much wider than the page keeps it inside the text area). Open documents automatically reload after external saves (Markdown marks the blocks that changed with a thin red line on the left, never in print); source files are never edited.

## Contributing

Issues and pull requests are welcome, in English or Japanese. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © 2026 phyten

## Languages

Surimono supports English, Japanese, Simplified Chinese, Traditional Chinese, Korean, French, German, and Spanish.
Choose **Surimono › Settings… › General › Language**, then relaunch when prompted. **System (default)** follows macOS. You can also choose the app language in **macOS System Settings › General › Language & Region › Applications**.

For host-side visual checks, launch the Debug app with `-AppleLanguages '(de)'` (replace `de` with `en`, `ja`, `zh-Hans`, `zh-Hant`, `ko`, `fr`, or `es`). This works with the existing `-SurimonoSnapshotPath`, `-SurimonoPopover style|view`, `-SurimonoMode print|compare`, and `-SurimonoMenu full` arguments. Use a fresh instance for each language. Language changes take effect on relaunch, including menus and theme names.

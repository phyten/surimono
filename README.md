# Surimono

[![DMG downloads](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fphyten%2Fsurimono%2Fstats%2Fdownloads-dmg.json)](https://github.com/phyten/surimono/releases) [![ZIP downloads](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fphyten%2Fsurimono%2Fstats%2Fdownloads-zip.json)](https://github.com/phyten/surimono/releases)

> Open it casually, glance at it, print it right away.
> 雑に開いて、雑に見て、さっと刷る。

**Surimono** is a macOS app for quickly viewing and printing everyday documents and images — Markdown, PDF, images, Org, plain text, HTML and LaTeX. It is built around printing: **115 print styles, including a Japanese vertical-writing prototype and six for LaTeX**, HTML noise-removal presets, and saddle-stitch booklet printing (two A4 pages side by side on A3, printed double-sided, folded and stapled in the middle).

**108 general print styles, one vertical-writing prototype and six for LaTeX** — from letters and reports to woodblock-print headings and a sports-day programme — picked from samples of your own document's first page.

The name comes from *surimono* (摺物), privately commissioned Japanese woodblock prints; *suru* (摺る) means "to print".

[日本語の README はこちら](README.ja.md)

> [!NOTE]
> Surimono is in early development.

## Why

Printing a Markdown note, an Org file or a long HTML article on a Mac usually means a detour through a browser, an editor plugin or a PDF tool. Surimono aims to make it a two-step job: open the file, press Print.

## Features

- Export a **PDF for Reading** in page order, with heading bookmarks, existing links and title metadata, or choose **PDF of Sheets** to keep the print layout.
- Export reading pages as PNG (72 / 144 / 300 dpi), save themed text as a single HTML file, copy HTML or rich text (including tables, lists, figures and math), or share a reading PDF through macOS.
- Customize local and global keys in **Settings › Keyboard Shortcuts**. Keys and Gestures and button hints follow your assignments. Export your overrides as JSON, review and merge an import, or restore all defaults with confirmation. Fixed keys for cancellation, editing and keyboard access stay available.
- Print Markdown CriticMarkup with revision marks, accepted changes, or the original text.
- The five LaTeX paper styles lay out one- and two-column papers with page- or column-bottom footnotes, full-width titles and floating figures and tables. `multicols` balances its final columns. Long footnotes stay whole. If the layout cannot fit them, Surimono prints in one column with endnotes and adds a print check.
- With general styles, put Markdown and LaTeX footnotes at the bottom of their first reference page (beta); references inside tables, callouts and quotes, and oversized notes, stay at the end. PDF text extraction can repeat text on pages with moved notes.
- Markdown front matter can choose a print setting set, layout, orientation, margins, style, and text size with `surimono:`; saved document settings take priority.

- Open copied Markdown, text, HTML source, or images directly from the clipboard with ⌘N, without saving a source file
- Copied text opens formatted (Markdown, Org, HTML, LaTeX, CSV or TSV) only when its format is clear; otherwise Surimono asks, showing the first lines and what each format would do. The format on the toolbar opens the same text again in another format, and Settings › Clipboard sets how the format is chosen. A copied URL opens as text. Use **File › Open from URL…** to load a page and print it with the HTML cleanup settings.
- Set two global shortcuts in Settings > Keyboard Shortcuts to open the clipboard in the viewer or on the print screen while Surimono is running (both are unset by default).
- Open or print selected text from any app with the Services menu (Open in Surimono, Print with Surimono). It stays in memory until you choose Save as File…
- Bind a Markdown file's parts: `<<[file]` (Marked), `{{file}}` (MultiMarkdown), `/file` (iA Writer), or a SUMMARY.md of links open as a binder when you ask, with the parent's text as a preface
- Streaming Preview, compatible with [Marked's](https://markedapp.com/help/Streaming_Preview): apps that write to the `mkStreamingPreview` pasteboard appear live, without a file (the base URL for relative images is not used). A leading `<!--format: org-->` comment selects the format
- Syntax highlighting for Markdown and Org code blocks, plus Markdown callouts (`:::` and `> [!note]`) with a tag, an icon and a line of their own that tell the kinds apart even in black and white, rendered offline without JavaScript
- Extended Markdown: footnotes, `==highlight==`, `^superscript^` and `~subscript~`, ruby `{漢字|かんじ}`, emoji `:tada:`, definition lists, heading ids and a `[TOC]` table of contents
- Cite a local BibTeX file with `bibliography: refs.bib` and `[@key, p. 33]`. References are numbered in citation order. Markdown also reads Pandoc title, author, date and contents fields, and fenced divs with classes and an ID.
- Open the sample document from Help or the welcome screen. On its paper, right-click a Mermaid, Graphviz or PlantUML diagram to save SVG or PNG, or copy PNG.
- Org files print as documents, not as source: TODO keywords (your `#+TODO` ones too), priorities, tags, progress cookies, planning dates, checkboxes, footnotes, captions and `#+begin_note`-style blocks each get a form that follows the chosen style and stays readable in black and white. LaTeX math (`$…$`, `\[…\]`, `\begin{equation}` and the like) is typeset too
- Mermaid diagrams in Markdown (```` ```mermaid ````) and Org (`#+begin_src mermaid`) rendered as printable SVG offline. Invalid diagrams keep their source and appear in the preflight checks.
- Graphviz (`dot` / `graphviz`) and PlantUML (`plantuml` / `puml`) code blocks in Markdown and Org render offline, without Java. Standalone PlantUML files can contain multiple diagrams. External includes and optional sprite libraries are unavailable; failed diagrams retain their source and an error message.
- Math in Markdown (`$…$`, `$$…$$`, ```` ```math ````) typeset without JavaScript by [SwaTex](https://github.com/PhraseHQ/SwaTex), a KaTeX-compatible engine in pure Swift, including chemistry (mhchem)
- Quick viewer for Markdown, PDF, images, Org, plain text, HTML, CSV, and LaTeX
- Print Jupyter Notebook Markdown, code and saved outputs without executing code. Supports nbformat 4; interactive-only outputs are marked with a framed note.
- LaTeX documents printed with the styles: titles, numbered sections and references, lists (enumitem), code (listings), math through SwaTex with equation numbers, footnotes, hyperref, xcolor, figures (graphicx), tables (booktabs), theorems and proofs (amsthm), the bibliography and citations, and units (siunitx). Journal front matter groups authors, affiliations, abstracts and keywords with the title. Rules, nested tables, cropped graphics and scaled boxes retain their layout. User commands and environments, counters, conditional branches and bounded loops are supported. Cross-references use English or Japanese names and can show a title, list or range. The print check lists unrecognized commands. Split manuscripts can include neighboring chapters, BibTeX or biblatex databases, and source listings. Minipages, subfigures, long tables, and framed boxes use the print style. TikZ flowcharts, geometric figures, matrices of nodes and simple trees, and pgfplots line, scatter, bar and log-axis charts print as SVG and can be saved as diagrams. For unsupported pictures, the print check identifies the feature and the page uses an externalized PDF, PNG or SVG when available. New LaTeX documents open in the article, report / book, Japanese, Chinese or Korean style according to the class and language. Babel and polyglossia supply caption names, dates, quotations and reading direction. The reader follows renamed headings, lists of figures and tables, installed fontspec families, paragraph spacing and heading sizes. In a LaTeX style, **As the Document** preserves the class or geometry text width and height on the selected paper. Each pair of margins shares the remaining space in its original proportions. If the text block exceeds the paper on an axis, its margins fall to zero and the block fits that axis. Page numbers follow the class, its numbering and counter resets. Plain numbers sit below the center of the text block. Basic fancyhdr fields can place text, running titles and numbers in the header or footer. Numeric margins and custom headers or footers can be selected per document. The contents, lists of figures and tables, and page references use the paginated body. The class size sets the leading. On A4, 10 pt jsarticle and ltjsarticle use a 49-character line. A saved style choice takes precedence. In report and book documents, equation, figure, and table numbers include the chapter number. Footnote numbering restarts in each chapter. Title acknowledgements use symbols. Listings can specify a frame, size and syntax colors, and plain-style bibliographies print publication details by entry type. Surimono reads these files locally and does not run TeX
- Combine Markdown, Org, text, CSV, LaTeX, HTML, PDFs, and images into one binder: drop files on an open window or use Add Documents…, reorder, remove, and print or export as one PDF or booklet, optionally starting each document on an odd page. A binder you close stays in File > Recent Binders.
- Open multiple images together as one image bundle, including mixed image formats
- Reorder images by dragging thumbnails or with Option-Command-Up/Down
- Export an image bundle as a PDF in its current order and print layout
- A print screen that lays out the sheets as they come out of the printer — fronts and backs side by side, booklet sheets with their fold, and a "See It Folded" preview that turns the pages of the folded booklet. Pinch, ⌘-scroll, double-click or ⌘+ / ⌘− zoom around the pointer up to twice the real size, and a drag moves sheets that do not fit (the printed size stays the same)
- Each document is set in its own language, detected from its text: Chinese in Chinese fonts and glyph forms, Cyrillic in Latin-style fonts, Korean without breaks inside words, Arabic and Hebrew right to left, and hyphenation in the justified styles. A `lang` key in Markdown front matter or `#+LANGUAGE` in Org sets it explicitly
- 115 built-in print stylesheets across 13 categories. For beamer decks the LaTeX category offers Slides. Other LaTeX documents open with a category of five styles for different classes and languages. Vertical (Prototype) sets Markdown, Org and plain text in top-to-bottom lines, read from right to left. The 108 general styles are available to all themed formats in 12 categories (everyday, Japanese, business, academic, technical, reading, notes, print-friendly, retro, pop, seasons, kids), chosen from a palette of bundled samples (or your document's first page) — in a searchable list with Recent, Favorites, Suggested, categories and your own styles — that, in the viewing screen, tries a style on the paper as you point at it, or by laying up to four side by side from the same heading or code, plus your own CSS. A LaTeX-style one sets the text in Computer Modern (the bundled KaTeX fonts) with LaTeX's numbered sections and indented paragraphs. Some playful styles sprinkle emoji that stay the same for a document on screen and on paper
- Choose **LaTeX Typeface** beside Text Size to use Computer Modern for Western text and its typewriter face for code. Other scripts keep the style’s fonts.
- Text size from 80% to 200% in 1% steps (⌥⌘+ / ⌥⌘− and the menus move through eight presets), layered over any style for Markdown, Org, text, CSV, and LaTeX; keeps the window and paper size, with the same result in print and PDF export
- Open the style palette from either the viewing screen or the print screen. Switch between **This Document** and a bundled **Sample Document** with headings, paragraphs, lists, a table, code and a quotation; the choice is remembered across the app. Sample Document is the default unless you have already made a choice. The specimen is Japanese for a Japanese UI and English otherwise. Its samples are cached on disk and reused across launches; samples of your own document are never stored on disk. In the viewing screen, hovering tries the style on the paper. Turn off **Try a Style on the Paper When Pointing at It** in Settings > Styles to keep the paper unchanged on hover and choose by clicking. In the print screen, hovering enlarges only the sample beside the list; clicking chooses the style, records it in Recent and lays out the sheets. The palette stays open for comparison and closes with Esc or a click outside. A brief hint appears beside the style button on the first eligible visit to the print screen.
- Code colors apart from the style: 12 palettes, plus the frame, line numbers, long lines and the language name
- HTML noise-removal presets (navigation, ads, sidebars, cookie banners, …) that you can extend
- Smart Removal (beta) for HTML: finds ads, recommended articles, share buttons, cookie banners and the like, removes them, and lets you review and keep any of them; detection runs on your Mac only
- Before printing, checks show unreadable images, overly wide blocks, formula errors, and unsupported LaTeX with their pages and suggested fixes. Documents without issues gain no extra controls; printing is never blocked.
- Print layouts: single-sided and duplex A4, B5, and Letter; saddle-stitch booklets A3 → A4, A4 → A5, B4 → B5, B5 → B6, Tabloid → Letter, and Letter → Half Letter. Choose left or right binding in Print Settings.
- Put two pages on A3 / A4, B4 / B5, or Tabloid / Letter, or four pages on portrait A4, B5, or Letter (top left, top right, bottom left, bottom right). Choose the paper and page count from the ▼ on the 2-up card. Each paper family also offers three pages plus notes. With no saved default layout, the region and default printer paper determine whether A sizes or Letter are offered first.
- Filter the contents by heading text to find a section quickly
- Show the current chapter in the reading toolbar
- Bookmark pages, revisit them from the contents, and go Back or Forward after a jump
- Print settings, which change the pages (on screen too) and never the document: margins on each side in 0.1 mm steps, shown in inches where the region uses them (inside and outside too), header and footer, page breaks by heading and chapters from the right-hand page, and contents added to the paper
- Headers and footers can show the current chapter. For themed text documents, print external link destinations after the link text or in a numbered list at the end.
- Note pages to write on: on one side of each spread, behind each page or after each chapter. 17 templates such as college ruled, grid, manuscript paper and cute patterns, with line style, thickness, spacing and color you can adjust and save. They work with PDFs and images too
- Print straight to the printer chosen on the print screen, without a dialog (the system print dialog is one step away), and PDF export (for example, for convenience-store printers)
- Layouts the chosen printer cannot do (a paper it does not take, no two-sided printing) carry a small badge; Print then opens the system print dialog instead of sending right away
- Remembers back-side rotation separately for long-edge and short-edge binding, and print order, for each printer. A one-sheet duplex test helps check and save the back-side orientation.
- View mode shows the pages of the print layout, so what you read is what prints, header and footer included (except on images, on PDF pages of another size than the layout's page, and in the three-pages-plus-notes layout, where they stand beside the page); the paper family is the same choice as on the print screen (note pages, the page range and printing only the current slide apply on the print screen only; images keep their own shape on screen)
- A view with the toolbar outside the paper, always shown (**View › Always Show Toolbar**, ⌥⌘T) or only when you point at it, when the window grows around the paper to make room and is the paper alone again once the toolbar hides; single-page (⌥⌘1) and spread (⌥⌘2) views; zoom without losing sharpness. Pages slide by default. The mouse wheel and trackpad turn pages with the chosen effect (fade, slide, curl, cover, reveal, wipe, zoom) at an adjustable sensitivity; in Markdown and the other themed formats, single-page scrolling can join pages by hiding the margins where they meet; a lone last page of a spread sits on its side; and page numbers can be turned on for view mode and for print separately, set in the bottom margin (never in single-page scrolling)
- **Help › Keys and Gestures** and the toolbar’s **… › Keys and Gestures** open the same guide: Tab / M for the toolbar, ⌥⌘T to always show it, V for view options, T for text selection, Option to swap drag behavior, edge clicks and double-click zoom, pinch and ⌘-scroll zoom, ⌘F to find in the document (⌘G / ⇧⌘G for the next and previous match), ⌥⌘G to go to a page, ⌘R to reload, plus printing with ⌘P / ⌥⌘P / ⌘1–⌘6 and returning with Esc. The guide includes when each paper gesture works
- In **Settings › General**, choose **Square**, **Standard**, or **Round** corners for app controls. While Surimono is running, click the booklet in the menu bar to open clipboard content, reopen one of your five most recent files, open another file, start a streaming preview, or open Settings. To hide the booklet, turn off **Show in Menu Bar** in **Settings › General**.
- Arrange the toolbar in **Settings › Toolbar Arrangement**: drag its parts and separator lines on a miniature of the window (or move them from the keyboard), take parts you never use off it (they stay in **…**), and keep several arrangements as sets you can duplicate, overwrite, rename and switch, with Standard always one click away.
- Save named **setting sets** from **Document > Setting Sets** or the print screen. Choose which parts to include: layout and orientation, margins, headers and footers, finishing, notes, style (including text size and typeface), or HTML presets. In Settings › Setting Sets, you can reorder, rename or delete your sets, export one or all to JSON, and import sets from one or more files. If a name is taken, a different set gets a numbered suffix. An identical set is skipped.
- Open defaults for new documents and app-wide settings from **Surimono › Settings…** (⌘,). The sidebar groups settings under General, Viewing, Printing and Opening. Search by setting or section name to jump to a matching row. Actions on the current document live in the View and Document menus
- Files keep their settings when moved or copied. Surimono matches the content (SHA-256) first, then the file location so it can restore settings after you edit a closed file. Image bundles are matched by their set of images
- Open a ZIP of images as one image bundle (images in nested folders, sorted by name; never extracted to disk)
- Choose **Float on Top** or **Page Turn** in **…**. Add either to the toolbar in Settings. **Single or Spread** stays on the toolbar. **View › Float on Top** also pins the window. Choose **View › Show on All Spaces** to see it on every desktop.
- Light by default; choose Dark or Match System under **Settings › General › Appearance**. The paper stays white in every appearance

## Privacy and network access

Surimono works offline and has no telemetry. It connects when you press **Open** in **Open from URL…**, when a document loads its own resources, and for update checks. If you enter an HTTP address, Surimono changes it to HTTPS before connecting. It follows only HTTPS redirects and uses a temporary session without stored cookies. HTML opens on paper and resolves images and styles relative to the final URL.

**File › Recently Closed Clipboard Documents** lists the last ten clipboard, selection, or URL documents closed during this run (up to 50 MB in total). Reopen the latest with ⇧⌘T. The history stays in memory. Turn off **Keep Closed Clipboard Documents Until Quit** in **Settings › Clipboard** to clear it immediately.

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
| Plain text | `.txt`, `.log` and other text files |
| Source code and configuration (colored by language; shown as written) | `.swift`, `.py`, `.rb`, `.js`, `.ts`, `.tsx`, `.go`, `.rs`, `.java`, `.kt`, `.c`, `.h`, `.cpp`, `.cs`, `.m`, `.php`, `.sh`, `.sql`, `.lua`, `.r`, `.jl`, `.hs`, `.vue`, `.css`, `.scss`, `.json`, `.jsonl`, `.ndjson`, `.yaml`, `.yml`, `.toml`, `.ini`, `.xml`, `.plist`, `.diff`, `.patch`, `.mk`, `Makefile`, … |
| HTML | `.html`, `.htm` |
| CSV / TSV | `.csv`, `.tsv` |
| LaTeX | `.tex`, `.latex`, `.ltx` |
| Quarto (code is shown as configured; results are not generated) | `.qmd` |
| R Markdown (code is shown as configured; results are not generated) | `.Rmd`, `.rmd`, `.Rmarkdown` |
| Word | `.docx` |
| Djot | `.dj`, `.djot` |
| reStructuredText | `.rst`, `.rest` |
| MediaWiki | `.mediawiki`, `.wiki`, `.wikitext` |
| Textile | `.textile` |
| AsciiDoc | `.adoc`, `.asciidoc` |
| Jupyter Notebook | `.ipynb` |
| Graphviz | `.dot`, `.gv` |
| PlantUML | `.puml`, `.plantuml`, `.pu`, `.iuml`, `.wsd` |
| ZIP of images | `.zip` (opened as one image bundle) |

Page layout supports plain text up to 30 MB, CSV and TSV up to 60,000 rows including the header, and generated HTML up to 60 MB (1 MB = 1,000,000 bytes). Source code and configuration files use syntax highlighting up to 200,000 UTF-16 code units; a longer file is shown whole without colors. The language comes from a well-known file name (`Makefile`, `Dockerfile`, …), then the extension, then a leading `#!` line. Surimono registers as a secondary viewer for source code. Which app opens these files, and whether Finder offers Surimono for them, depends on the apps on your Mac and on your own choices. macOS treats `.ts` as a video stream: Surimono reads the beginning of the file and opens it when that reads as text, and does not open one that reads as an MPEG transport stream or as other binary data (the same check applies to `.plist`). **File > Open…** also lets you select files such as `Dockerfile`, `Makefile`, `Gemfile`, and `LICENSE`. Press ⇧⌘. in the panel to show hidden files such as `.gitignore` and `.env.example`. If Finder identifies an extensionless script only as a Unix executable, use the Open panel or drop it on a Surimono window. Surimono checks the beginning of the file before opening it as text.

Source pages show line numbers by default. Choose **View > Go to Line…** (⌃G) and enter `120` or `120:8` to jump to line 120 and briefly highlight it. The column is optional and ignored. You can change the key in **Settings > Keyboard Shortcuts**.

### Not supported

- Repeating column headings on later pages of a printed LaTeX table.

## Requirements

- macOS 15 Sequoia or later

## Install

1. Download `Surimono-<version>.dmg` from the [latest release](https://github.com/phyten/surimono/releases/latest), open it, and drag Surimono to Applications.
2. Surimono is not notarized by Apple yet, so macOS blocks the first launch. Follow the steps in the release notes (System Settings > Privacy & Security > Open Anyway). Later launches open normally.

Surimono updates itself. Choose **Surimono > Check for Updates…**, or let it check automatically on every launch and once a day while it runs: it asks on the second launch, and Settings > General turns it on or off. Settings > General also lets you choose **Notify Me** (the default) or **Install Automatically**. With notifications, Sparkle shows its update dialog near launch; if it would defer the dialog while you work, a small **Update Available** panel offers **Show Update…** without taking keyboard focus. Automatic installation downloads the update in the background and installs it when you quit, ready for the next launch. An existing Sparkle automatic-install choice is preserved. Updates are signed and verified before they are installed. Checking downloads a small feed from GitHub; nothing about your documents is sent.

Recent files are also saved by Surimono, including bookmarks to follow moved files. If macOS loses its recent-items list after an update, Surimono restores it at launch, skipping missing files. Clear Menu clears both lists. A list already lost before this version first saved it cannot be recovered.

## Building from source

Building requires Xcode 27 (Swift 6.4); the app itself runs on macOS 15 or later. Select Xcode as the active developer directory before building. CI and releases are built with Xcode 27.2, and older Xcode versions are no longer checked.

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

Sample documents in `Samples/` cover reStructuredText (`sample.rst`), Djot (`sample.dj`), Textile (`sample.textile`), Markdown, Org, UTF-8 and Shift_JIS text, HTML, CSV, JSON (`sample.json`) and source code (`sample.swift`, `sample.py`, `sample.rb`, `sample.ts`). `booklet-demo.md` is a long, image-free document for checking booklet page order, and `callouts.md` shows every kind of callout. Settings include print margins, page numbers, back-side rotation, and JavaScript for HTML. Add CSS in `~/Library/Application Support/Surimono/Styles/` and JSON presets in `Presets/`, then reload them in Settings. For Markdown and the other themed formats, a background a style (your CSS included) gives `html`, such as a paper tint or ruling, covers the margins too, with its pattern starting at the top left of the text (a document much wider than the page keeps it inside the text area). By default, Surimono reloads a saved file. In supported text and Word documents it stays on the current page if a change is there, or jumps to the next changed page. On screen, soft yellow shows the changed paragraphs, plain text lines, list items and table rows. A thin strip shows where text was deleted. In General settings you can change the colors, stay on the current page, or turn off automatic reloading. Source files are never edited.

## Contributing

Contributors can compare rendered documents and UI against an approved local baseline with `make snapshots && make snapshots-report`. Open the reported HTML to review page images, text and layout shifts before approving selected cases. See [the snapshot workflow](AGENTS.md#スナップショット見た目の回帰).

Issues and pull requests are welcome, in English or Japanese. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © 2026 phyten

## Languages

Surimono supports English, Japanese, Simplified Chinese, Traditional Chinese, Korean, French, German, and Spanish.
Choose **Surimono › Settings… › General › Language**, then relaunch when prompted. **System** (the default) follows macOS. You can also choose the app language in **macOS System Settings › General › Language & Region › Applications**.

For host-side visual checks, launch the Debug app with `-AppleLanguages '(de)'` (replace `de` with `en`, `ja`, `zh-Hans`, `zh-Hant`, `ko`, `fr`, or `es`). This works with the existing `-SurimonoSnapshotPath`, `-SurimonoPopover style|view`, `-SurimonoMode print|compare`, and `-SurimonoMenu full` arguments. Use a fresh instance for each language. Language changes take effect on relaunch, including menus and theme names.

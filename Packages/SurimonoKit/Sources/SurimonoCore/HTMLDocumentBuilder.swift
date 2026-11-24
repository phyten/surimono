import Foundation

public enum HTMLDocumentBuilder {
    /// - Parameter removesPaper: Whether the page is laid out without the theme's paper, which then goes on a page of
    ///   its own (`PaperBackground`).
    /// - Parameter finish: Style rules of the print finish, laid over the theme in an element of their own, which a
    ///   theme picker leaves in place.
    public static func build(
        fragment: HTMLFragment, format: DocumentFormat, theme: PrintTheme, baseURL: URL? = nil, language: String = "ja",
        textScale: Double = 1, typeface: Typeface = .style, removesPaper: Bool = false, finish: String = "",
        code: CodeStyle = CodeStyle()
    ) -> String {
        build(
            fragment: fragment, format: format, theme: theme, baseURL: baseURL, language: language,
            textScale: textScale, typeface: typeface, removesPaper: removesPaper, finish: finish, code: code,
            verticalMarkup: { (try? VerticalText.marked($0, latex: $1)) ?? $0 }, checkSourceBytes: { _ in })
    }

    package static func build(
        fragment: HTMLFragment, format: DocumentFormat, theme: PrintTheme, baseURL: URL? = nil, language: String = "ja",
        textScale: Double = 1, typeface: Typeface = .style, removesPaper: Bool = false, finish: String = "",
        code: CodeStyle = CodeStyle(), preparesThemeSampler: Bool = false,
        verticalMarkup: (String, Bool) throws -> String = VerticalText.marked,
        checkSourceBytes: (Int) throws -> Void
    ) rethrows -> String {
        let language = Self.language(for: fragment, fallback: language)
        let info = format == .latex ? fragment.latexClass : nil
        let latex =
            info.map { info in
                let attributes = " data-latex-size=\"\(info.pointSize)\" data-latex-chapters=\"\(info.hasChapters)\""
                let verticalGrid: String
                if theme.flow == .vertical || preparesThemeSampler {
                    let box = info.pageBox
                    verticalGrid =
                        " data-latex-vertical-rows=\"\(info.columns)\" data-latex-text-width=\"\(box.textWidth)\""
                        + " data-latex-text-height=\"\(box.textHeight)\""
                } else {
                    verticalGrid = ""
                }
                let title = info.hasSeparateTitlePage.map { $0 ? "separate" : "inline" }
                let localMain = info.mainFontName.map { $0 != "Surimono Computer Modern" } == true
                return attributes + verticalGrid + " data-latex-class=\"\(HTML.escape(info.name))\""
                    + (info.composition == .proof ? " data-latex-review=\"proofPageLines\"" : "")
                    + (info.linksReferences ? " data-latex-hyperref" : "")
                    + (info.pageBackReferences ? " data-latex-page-backrefs" : "")
                    + info.latinLineAttributes
                    + (info.resolvedStyle.map { style in
                        " data-latex-style=\"\(style.family.rawValue)\" data-latex-style-mode=\"\(style.mode.rawValue)\""
                            + (style.review.map { " data-latex-review=\"\($0.rawValue)\"" } ?? "")
                            + (style.reviewBanner.map { " data-latex-review-banner=\"\(HTML.escape($0))\"" } ?? "")
                            + (style.reviewCorner.map { " data-latex-review-corner=\"\(HTML.escape($0))\"" } ?? "")
                            + (style.raggedBottom ? " data-latex-ragged-bottom" : "")
                            + (style.frenchSpacing ? " data-latex-french-spacing" : "")
                    } ?? "")
                    + (info.publicationGridStyle.map { " data-latex-publication-grid=\"\($0)\"" } ?? "")
                    + (info.raggedColumns ? " data-latex-ragged-bottom" : "")
                    + (info.profile.bookOpeningSide.map { " data-latex-book-opening=\"\($0)\"" } ?? "")
                    + (info.usesNaturalTableCaptionHeight ? " data-latex-natural-table-captions" : "")
                    + (localMain ? " data-latex-local-main-font" : "")
                    + (title.map { " data-latex-title-layout=\"\($0)\"" } ?? "")
                    + (info.columns == 2 && info.profile.usesGridFlow
                        ? " data-latex-js-twocolumn" : "")
                    + (info.usesJSChapterSpacing ? " data-latex-js-chapters" : "")
                    + (info.usesNativeCJKHeadings ? " data-latex-native-headings" : "")
                    + (info.journalStyle.map { " data-latex-journal=\"\($0.rawValue)\"" } ?? "")
                    + (info.profile.usesGridFlow ? " data-latex-js-toc" : "")
                    + (info.styleVariables.isEmpty ? "" : " style=\"\(HTML.escape(info.styleVariables))\"")
            } ?? ""
        // Local font aliases live outside the replaceable theme sheet. Selecting a new
        // theme can then opt into the same document fonts without re-reading the source.
        let localFaces =
            format == .latex
            ? [textShapes, info?.localFontFaces ?? "", info == nil ? "" : ideographFaces]
                .filter { !$0.isEmpty }.joined(separator: "\n") : ""
        let fontStyle =
            localFaces.isEmpty
            ? ""
            : "<style>\(localFaces.replacingOccurrences(of: "</style", with: "\\3C /style", options: .caseInsensitive))</style>"
        let sourcePage = format == .plainText && fragment.sourceLanguage != nil
        let marked = try CodeBlockMarkup.apply(
            code, to: fragment.body, language: sourcePage ? fragment.sourceLanguage : nil,
            checkSourceBytes: checkSourceBytes)
        var body = marked
        if !preparesThemeSampler, !sourcePage, theme.flow == .vertical, theme.supports(format) {
            body = try verticalMarkup(body, format == .latex)
            try checkSourceBytes(body.utf8.count)
        }
        if !sourcePage {
            body = LongTokenMarks.marked(body, verticalLaTeX: format == .latex && theme.flow == .vertical)
        }
        let sheet = styleSheet(
            theme: theme, textScale: textScale, typeface: format.usesPrintTheme ? typeface : .style,
            code: code, language: language.code, sourcePage: sourcePage)
        // The sampler replaces the first style element. This source-only sheet stays with its lines.
        let scale = textScale.isFinite && textScale > 0 ? textScale : 1
        let sourceStyle =
            sourcePage
            ? "<style>\n:root { --source-min-size: \(10 / scale)px; }\n\(sourcePageCSS)\n</style>" : ""
        let slideStyle = info.flatMap { beamerStyle($0, sheet: sheet) } ?? ""
        let direction = language.isRightToLeft ? " dir=\"rtl\"" : ""
        // Styles that number headings with counters leave such a document alone.
        let ownNumbers = fragment.decidesHeadingNumbers ? " own-heading-numbers" : ""
        let base = baseURL.map { "<base href=\"\(HTML.escape($0.absoluteString))\">\n" } ?? ""
        let finishStyle = finish.isEmpty ? "" : "\n<style id=\"surimono-finish\">\n\(finish)\n</style>"
        return """
            <!doctype html>
            <html lang="\(HTML.escape(language.code))"\(direction)>
            <head>
            <meta charset="utf-8">\(offlinePolicy(for: format))
            <title>\(HTML.escape(fragment.title ?? ""))</title>
            \(base)<style>
            \(sheet)
            </style>\(sourceStyle)\(fontStyle)\(format == .rst ? rstStyle : "")\(finishStyle)\(slideStyle)\(removesPaper ? "\n" + PaperBackground.removalStyle : "")
            </head>
            <body class="surimono format-\(format.rawValue)\(ownNumbers)"\(latex)>
            \(body)
            </body>
            </html>
            """
    }

    private static let sourcePageCSS: String = {
        guard let url = Bundle.module.url(forResource: "source-page", withExtension: "css") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    private static let rstStyle = """
        <style>
        .format-rst :is(td, th) > p { margin: 0; }
        .format-rst table > caption { white-space: nowrap; text-align: start; }
        .format-rst dd > p:first-child { margin-block-start: 0; }
        .format-rst dd > p:last-child { margin-block-end: 0; }
        .format-rst :is(pre.literal-block, pre.doctest-block, code.rst-plain-code) { font-weight: normal; font-style: normal; }
        .format-rst dt > .rst-classifier::before { content: " : "; }
        .format-rst .rst-line-block > .rst-line-block { margin-inline-start: 1.5em; }
        .format-rst .rubric, .format-rst .topic-title, .format-rst .sidebar-title { font-weight: bold; }
        .format-rst :is([role="doc-footnote"], [role="doc-biblioentry"]) > .label + p { display: inline; margin-inline-start: .35em; }
        </style>
        """

    private static func beamerStyle(_ info: LaTeXDocumentClassInfo, sheet: String) -> String? {
        guard let size = info.beamerPageSize else { return nil }
        let family = info.beamerUsesSerifText ? "Surimono Computer Modern" : "Surimono Computer Modern Sans"
        let face =
            sheet.contains("@font-face { font-family: \"\(family)\"")
            ? "" : ThemeFonts.faces(forStyleSheet: "\"\(family)\"")
        return """
            <style>
            \(face)
            :root { --beamer-width: \(size.width * 1.25)px; --beamer-height: \(size.height * 1.25)px;
                --beamer-font: \(info.beamerFontSize * 1.24533)px; --beamer-family: "\(family)", sans-serif; }
            \(beamerCSS)
            \(slideSizes(for: info.beamerFontSize))
            </style>
            """
    }

    private static func slideSizes(for body: Double) -> String {
        // Beamer selects the size*.clo ladder. Large, small, footnotesize and scriptsize
        // are discrete sizes, so a 20pt frame cannot just enlarge the default 11pt theme.
        let sizes:
            (
                title: Double, block: Double, small: Double, note: Double, script: Double, pitch: Double,
                smallPitch: Double, notePitch: Double
            )
        switch body {
        case 8: sizes = (10.95, 10, 7, 6, 5, 9.5, 8, 7)
        case 9: sizes = (10.95, 10, 8, 7, 6, 10.95, 9, 8)
        case 10: sizes = (14.4, 12, 9, 8, 7, 12, 11, 9.5)
        case 12: sizes = (17.28, 14.4, 10.95, 10, 8, 14.5, 13.6, 12)
        case 14.4: sizes = (20.74, 17.28, 12, 10, 8, 17, 14, 12)
        case 17.28: sizes = (24.88, 20.74, 14.4, 12, 10, 22, 17, 14)
        case 20.74: sizes = (29.86, 24.88, 17.28, 14.4, 12, 25, 22, 17)
        default: return ""
        }
        // Footnote marks are superscripts; the math script size at the note's text size
        // differs from the script size at the frame's base size (fontmath.ltx).
        let scriptSizes: [Double: Double] = [
            5: 5, 6: 5, 7: 5, 8: 6, 9: 6, 10: 7, 10.95: 8, 12: 8, 14.4: 10, 17.28: 12, 20.74: 14.4,
        ]
        return """
            body.surimono.format-latex {
                --beamer-title-size: calc(\(sizes.title) * var(--tex-pt)); --beamer-block-size: calc(\(sizes.block) * var(--tex-pt));
                --beamer-small-size: calc(\(sizes.small) * var(--tex-pt)); --beamer-note-size: calc(\(sizes.note) * var(--tex-pt));
                --beamer-script-size: calc(\(sizes.script) * var(--tex-pt)); --beamer-pitch: calc(\(sizes.pitch) * var(--tex-pt));
                --beamer-small-pitch: calc(\(sizes.smallPitch) * var(--tex-pt)); --beamer-note-pitch: calc(\(sizes.notePitch) * var(--tex-pt));
                --beamer-mark-size: calc(\(scriptSizes[body] ?? sizes.script) * var(--tex-pt));
                --beamer-note-mark-size: calc(\(scriptSizes[sizes.note] ?? sizes.script) * var(--tex-pt));
                --latex-size-Large: var(--beamer-title-size); --latex-size-large: var(--beamer-block-size);
                --latex-size-small: var(--beamer-small-size); --latex-size-footnotesize: var(--beamer-note-size);
                --latex-size-scriptsize: var(--beamer-script-size); --latex-size-normalsize: var(--beamer-font);
            }
            """
    }

    private static let beamerCSS: String = {
        guard let url = Bundle.module.url(forResource: "latex-beamer", withExtension: "css"),
            var css = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        // Embedded images also survive a standalone HTML export with the document's resources blocked.
        for name in ["beamer-article", "beamer-book"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "svg"),
                let image = try? Data(contentsOf: url)
            {
                css +=
                    "\n.beamer-bib-icon.\(name)::before { background-image:url(data:image/svg+xml;base64,\(image.base64EncodedString())); }"
            }
        }
        return css
    }()

    // Keep LaTeX font commands available when the user switches to a general print theme.
    private static let textShapes = """
        :where(.format-latex .latex-item-mark) { display: none; }
        .latex-sl { font-style: oblique 9.46deg; }
        .latex-rm, .latex-normal { font-family: var(--tex-body-fonts, var(--surimono-western,) var(--surimono-style-family, serif)); }
        .latex-up, .latex-normal { font-style: normal; font-variant-caps: normal; }
        .latex-md, .latex-normal { font-weight: normal; }
        """

    private static let ideographFaces =
        Bundle.module.url(forResource: "latex-ideograph-faces", withExtension: "css")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
        .replacingOccurrences(of: "KANGXI_UNIFIED_RANGE", with: LaTeXIdeographs.unifiedRange) ?? ""

    /// The document and its separate paper page both load theme CSS. Permit local resources and the bundled
    /// diagram engine's WebAssembly, while the renderer keeps document JavaScript disabled.
    static func offlinePolicy(for format: DocumentFormat) -> String {
        guard format == .rst || format == .mediawiki || format == .docx || format == .quarto || format == .rMarkdown
        else { return "" }
        // The sandbox serves checked relative images through its local URL scheme.
        let images = format == .rst ? "file: data: blob: surimono-local:" : "file: data: blob:"
        let policy =
            "default-src 'none'; img-src \(images); font-src file: data:; "
            + "style-src 'unsafe-inline' file: data:; script-src 'wasm-unsafe-eval'; form-action 'none'"
        return "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
    }

    public static func language(for fragment: HTMLFragment, fallback: String = "ja") -> DocumentLanguage {
        DocumentLanguage.detect(html: fragment.body, declared: fragment.language, fallback: fallback)
    }

    /// The contents of the document’s replaceable theme style element. A theme picker swaps it in a page that is already laid out.
    public static func styleSheet(
        theme: PrintTheme, textScale: Double = 1, typeface: Typeface = .style, code: CodeStyle = CodeStyle(),
        language: String = "ja", sourcePage: Bool = false
    ) -> String {
        // Prose fallbacks can put a proportional face ahead of the code face for some languages.
        var families = sourcePage ? theme.css : LanguageFonts.adapt(theme.css, language: language)
        if sourcePage && theme.id == "mimeograph" {
            // This theme normally starts even code in proportional Osaka. Use its fixed-pitch sibling.
            families += "\npre.surimono-source > code { font-family: \"Osaka-Mono\", Menlo, monospace; }"
        }
        // Escape closing style tags in HTML raw text.
        let css = families.replacingOccurrences(
            of: "</style", with: "\\3C /style", options: .caseInsensitive)
        // Zoom scales fixed-point fonts, tables and images together while pagination keeps the paper size.
        let scaleCSS =
            textScale != 1 && textScale.isFinite && textScale > 0
            ? "\nhtml { zoom: \(textScale); }" : ""
        // In the same element, so a theme picker that swaps it brings the theme's fonts along.
        let codeCSS = code.isDefault ? "" : "\n" + code.css
        let usesTypeface = typeface == .latex && Typeface.isAvailable(themeID: theme.id, usesPrintTheme: true)
        let styled = usesTypeface ? LanguageFonts.prefixTypeface(in: css + codeCSS) + Typeface.overlay : css + codeCSS
        let fonts = ThemeFonts.faces(forStyleSheet: styled)
        return styled + scaleCSS + (fonts.isEmpty ? "" : "\n" + fonts)
    }
}

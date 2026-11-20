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
        let language = Self.language(for: fragment, fallback: language)
        let info = format == .latex ? fragment.latexClass : nil
        let latex =
            info.map { info in
                let attributes = " data-latex-size=\"\(info.pointSize)\" data-latex-chapters=\"\(info.hasChapters)\""
                let title = info.hasSeparateTitlePage.map { $0 ? "separate" : "inline" }
                let localMain = info.mainFontName.map { $0 != "Surimono Computer Modern" } == true
                return attributes + " data-latex-class=\"\(HTML.escape(info.name))\""
                    + (info.resolvedStyle.map { style in
                        " data-latex-style=\"\(style.family.rawValue)\" data-latex-style-mode=\"\(style.mode.rawValue)\""
                            + (style.review.map { " data-latex-review=\"\($0.rawValue)\"" } ?? "")
                    } ?? "")
                    + (info.profile.bookOpeningSide.map { " data-latex-book-opening=\"\($0)\"" } ?? "")
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
            info.map { [$0.localFontFaces, ideographFaces].filter { !$0.isEmpty }.joined(separator: "\n") } ?? ""
        let fontStyle =
            localFaces.isEmpty
            ? ""
            : "<style>\(localFaces.replacingOccurrences(of: "</style", with: "\\3C /style", options: .caseInsensitive))</style>"
        let direction = language.isRightToLeft ? " dir=\"rtl\"" : ""
        let base = baseURL.map { "<base href=\"\(HTML.escape($0.absoluteString))\">\n" } ?? ""
        let finishStyle = finish.isEmpty ? "" : "\n<style id=\"surimono-finish\">\n\(finish)\n</style>"
        return """
            <!doctype html>
            <html lang="\(HTML.escape(language.code))"\(direction)>
            <head>
            <meta charset="utf-8">\(offlinePolicy(for: format))
            <title>\(HTML.escape(fragment.title ?? ""))</title>
            \(base)<style>
            \(styleSheet(theme: theme, textScale: textScale, typeface: format.usesPrintTheme ? typeface : .style, code: code, language: language.code))
            </style>\(fontStyle)\(finishStyle)\(removesPaper ? "\n" + PaperBackground.removalStyle : "")
            </head>
            <body class="surimono format-\(format.rawValue)"\(latex)>
            \(LongTokenMarks.marked(CodeBlockMarkup.apply(code, to: fragment.body)))
            </body>
            </html>
            """
    }

    private static let ideographFaces =
        Bundle.module.url(forResource: "latex-ideograph-faces", withExtension: "css")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
        .replacingOccurrences(of: "KANGXI_UNIFIED_RANGE", with: LaTeXIdeographs.unifiedRange) ?? ""

    /// The document and its separate paper page both load theme CSS. Permit local resources and the bundled
    /// diagram engine's WebAssembly, while the renderer keeps document JavaScript disabled.
    static func offlinePolicy(for format: DocumentFormat) -> String {
        guard format == .mediawiki || format == .docx || format == .quarto || format == .rMarkdown else { return "" }
        let policy =
            "default-src 'none'; img-src file: data: blob:; font-src file: data:; "
            + "style-src 'unsafe-inline' file: data:; script-src 'wasm-unsafe-eval'; form-action 'none'"
        return "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
    }

    public static func language(for fragment: HTMLFragment, fallback: String = "ja") -> DocumentLanguage {
        DocumentLanguage.detect(html: fragment.body, declared: fragment.language, fallback: fallback)
    }

    /// The contents of the document's one style element. A theme picker swaps it in a page that is already laid out.
    public static func styleSheet(
        theme: PrintTheme, textScale: Double = 1, typeface: Typeface = .style, code: CodeStyle = CodeStyle(),
        language: String = "ja"
    ) -> String {
        // Since style is an HTML raw-text element, CSS-escape any closing style tags inside the CSS.
        let css = LanguageFonts.adapt(theme.css, language: language).replacingOccurrences(
            of: "</style", with: "\\3C /style", options: .caseInsensitive)
        // Zoom scales fixed-point fonts, tables and images together while pagination keeps the paper size.
        let scaleCSS =
            textScale != 1 && textScale.isFinite && textScale > 0
            ? "\nhtml { zoom: \(textScale); }" : ""
        // In the same element, so a theme picker that swaps it brings the theme's fonts along.
        let codeCSS = code.isDefault ? "" : "\n" + code.css
        let usesTypeface = typeface == .latex && Typeface.isAvailable(themeID: theme.id, usesPrintTheme: true)
        let styled = usesTypeface ? LanguageFonts.prefixTypeface(in: css + codeCSS) + Typeface.overlay : css + codeCSS
        let fonts = usesTypeface ? ThemeFonts.textFaces : ThemeFonts.faces(forStyleSheet: css)
        return styled + scaleCSS + (fonts.isEmpty ? "" : "\n" + fonts)
    }
}

import Foundation

public enum HTMLDocumentBuilder {
    /// - Parameter removesPaper: Whether the page is laid out without the theme's paper, which then goes on a page of
    ///   its own (`PaperBackground`).
    /// - Parameter finish: Style rules of the print finish, laid over the theme in an element of their own, which a
    ///   theme picker leaves in place.
    public static func build(
        fragment: HTMLFragment, format: DocumentFormat, theme: PrintTheme, baseURL: URL? = nil, language: String = "ja",
        textScale: Double = 1, removesPaper: Bool = false, finish: String = "", code: CodeStyle = CodeStyle()
    ) -> String {
        let language = Self.language(for: fragment, fallback: language)
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
            \(styleSheet(theme: theme, textScale: textScale, code: code, language: language.code))
            </style>\(finishStyle)\(removesPaper ? "\n" + PaperBackground.removalStyle : "")
            </head>
            <body class="surimono format-\(format.rawValue)">
            \(LongTokenMarks.marked(CodeBlockMarkup.apply(code, to: fragment.body)))
            </body>
            </html>
            """
    }

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
        theme: PrintTheme, textScale: Double = 1, code: CodeStyle = CodeStyle(), language: String = "ja"
    ) -> String {
        // Since style is an HTML raw-text element, CSS-escape any closing style tags inside the CSS.
        let css = LanguageFonts.adapt(theme.css, language: language).replacingOccurrences(
            of: "</style", with: "\\3C /style", options: .caseInsensitive)
        // Zoom scales fixed-point fonts, tables and images together while pagination keeps the paper size.
        let scaleCSS =
            textScale != 1 && textScale.isFinite && textScale > 0
            ? "\nhtml { zoom: \(textScale); }" : ""
        // In the same element, so a theme picker that swaps it brings the theme's fonts along.
        let fonts = ThemeFonts.faces(forStyleSheet: css)
        let codeCSS = code.isDefault ? "" : "\n" + code.css
        return css + codeCSS + scaleCSS + (fonts.isEmpty ? "" : "\n" + fonts)
    }
}

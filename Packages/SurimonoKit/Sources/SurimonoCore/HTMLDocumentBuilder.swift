import Foundation

public enum HTMLDocumentBuilder {
    /// - Parameter removesPaper: Whether the page is laid out without the theme's paper, which then goes on a page of
    ///   its own (`PaperBackground`).
    public static func build(
        fragment: HTMLFragment, format: DocumentFormat, theme: PrintTheme, baseURL: URL? = nil, language: String = "ja",
        textScale: Double = 1, removesPaper: Bool = false
    ) -> String {
        let base = baseURL.map { "<base href=\"\(HTML.escape($0.absoluteString))\">\n" } ?? ""
        return """
            <!doctype html>
            <html lang="\(HTML.escape(language))">
            <head>
            <meta charset="utf-8">
            <title>\(HTML.escape(fragment.title ?? ""))</title>
            \(base)<style>
            \(styleSheet(theme: theme, textScale: textScale))
            </style>\(removesPaper ? "\n" + PaperBackground.removalStyle : "")
            </head>
            <body class="surimono format-\(format.rawValue)">
            \(fragment.body)
            </body>
            </html>
            """
    }

    /// The contents of the document's one style element. A theme picker swaps it in a page that is already laid out.
    public static func styleSheet(theme: PrintTheme, textScale: Double = 1) -> String {
        // Since style is an HTML raw-text element, CSS-escape any closing style tags inside the CSS.
        let css = theme.css.replacingOccurrences(of: "</style", with: "\\3C /style", options: .caseInsensitive)
        // Zoom scales fixed-point fonts, tables and images together while pagination keeps the paper size.
        let scaleCSS =
            textScale != 1 && textScale.isFinite && textScale > 0
            ? "\nhtml { zoom: \(textScale); }" : ""
        // In the same element, so a theme picker that swaps it brings the theme's fonts along.
        let fonts = ThemeFonts.faces(forStyleSheet: css)
        return css + scaleCSS + (fonts.isEmpty ? "" : "\n" + fonts)
    }
}

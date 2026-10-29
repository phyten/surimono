import Foundation

public enum HTMLDocumentBuilder {
    public static func build(
        fragment: HTMLFragment, format: DocumentFormat, theme: PrintTheme, baseURL: URL? = nil, language: String = "ja",
        textScale: Double = 1
    ) -> String {
        let base = baseURL.map { "<base href=\"\(HTML.escape($0.absoluteString))\">\n" } ?? ""
        // Since style is an HTML raw-text element, CSS-escape any closing style tags inside the CSS.
        let css = theme.css.replacingOccurrences(of: "</style", with: "\\3C /style", options: .caseInsensitive)
        // Zoom scales fixed-point fonts, tables and images together while pagination keeps the paper size.
        let scaleCSS =
            textScale != 1 && textScale.isFinite && textScale > 0
            ? "\nhtml { zoom: \(textScale); }" : ""
        return """
            <!doctype html>
            <html lang="\(HTML.escape(language))">
            <head>
            <meta charset="utf-8">
            <title>\(HTML.escape(fragment.title ?? ""))</title>
            \(base)<style>
            \(css)\(scaleCSS)
            </style>
            </head>
            <body class="surimono format-\(format.rawValue)">
            \(fragment.body)
            </body>
            </html>
            """
    }
}

import Foundation

public enum HTMLDocumentBuilder {
    public static func build(
        fragment: HTMLFragment, format: DocumentFormat, theme: PrintTheme, baseURL: URL? = nil, language: String = "ja"
    ) -> String {
        let base = baseURL.map { "<base href=\"\(HTML.escape($0.absoluteString))\">\n" } ?? ""
        // Since style is an HTML raw-text element, CSS-escape any closing style tags inside the CSS.
        let css = theme.css.replacingOccurrences(of: "</style", with: "\\3C /style", options: .caseInsensitive)
        return """
            <!doctype html>
            <html lang="\(HTML.escape(language))">
            <head>
            <meta charset="utf-8">
            <title>\(HTML.escape(fragment.title ?? ""))</title>
            \(base)<style>
            \(css)
            </style>
            </head>
            <body class="surimono format-\(format.rawValue)">
            \(fragment.body)
            </body>
            </html>
            """
    }
}

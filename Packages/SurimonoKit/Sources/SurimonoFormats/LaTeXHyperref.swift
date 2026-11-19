import Foundation

/// PDF link borders have no printed equivalent. Only an explicit colorlinks choice changes the ink.
struct LaTeXHyperref: Equatable {
    var colored: Bool?
    var link = "#ff0000"
    var cite = "#00ff00"
    var url = "#ff00ff"

    private func ink(_ color: String) -> String { colored == true ? color : "inherit" }

    func styleSheet(hasLocalColors: Bool) -> String? {
        guard colored != nil || hasLocalColors else { return nil }
        let scope = colored == nil ? "body.format-latex .latex-link-colors" : "body.format-latex"
        return """
            \(scope) a[href] { color: var(--latex-url-ink, \(ink(url))); text-decoration: none; }
            \(scope) a[href^="#"] { color: var(--latex-link-ink, \(ink(link))); }
            \(scope) .latex-cite a[href] { color: var(--latex-cite-ink, \(ink(cite))); }
            """
    }

    var inlineVariables: String {
        "--latex-link-ink: \(ink(link)); --latex-url-ink: \(ink(url)); --latex-cite-ink: \(ink(cite))"
    }
}

extension LaTeXReader {
    /// Capture a change made after the preamble at the use, including forward citations
    /// and lists whose links will only be generated after the whole document is known.
    func styledLinks(_ html: String, block: Bool = false) -> String {
        guard document.hyperref != document.initialHyperref else { return html }
        let tag = block ? "div" : "span"
        document.hasLocalLinkColors = true
        return "<\(tag) class=\"latex-link-colors\" style=\"\(document.hyperref.inlineVariables)\">\(html)</\(tag)>"
    }

    func readHyperrefOptions(_ options: String) {
        for (key, value) in LaTeXPageSettings.options(options) {
            switch key {
            case "colorlinks": document.hyperref.colored = value != "false"
            case "hidelinks": document.hyperref.colored = false
            case "linkcolor", "urlcolor", "citecolor", "allcolors":
                guard let color = LaTeXSymbols.cssColor(value, defined: document.colors) else { continue }
                if key == "linkcolor" || key == "allcolors" { document.hyperref.link = color }
                if key == "citecolor" || key == "allcolors" { document.hyperref.cite = color }
                if key == "urlcolor" || key == "allcolors" { document.hyperref.url = color }
            default: break
            }
        }
    }
}

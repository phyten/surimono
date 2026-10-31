import Foundation
import SwaTex

/// LaTeX math drawn by SwaTex, a KaTeX-compatible engine written in Swift, as inline SVG. The glyphs are text in the
/// KaTeX fonts, which `fontFaces(for:)` embeds, so formulas print as vectors and stay selectable, with no JavaScript.
public enum MathRenderer {
    /// KaTeX sets formulas a little larger than the text around them so their x-height matches it.
    static let scale = 1.1
    /// The SVG's own unit; only the ratio to it matters, since the sizes are rewritten in em.
    private static let fontSize = 10.0

    private static let viewBox = try? NSRegularExpression(pattern: #"viewBox="0 0 ([0-9.eE+-]+) ([0-9.eE+-]+)""#)
    private static let size = try? NSRegularExpression(pattern: #" width="[^"]*" height="[^"]*""#)

    /// The formula as HTML, or nil when SwaTex cannot read it.
    /// - Parameter macros: Definitions put in front of the formula, such as a document's `\newcommand`s; they are
    ///   not part of its accessible label.
    public static func html(_ latex: String, display: Bool, macros: String = "") -> String? {
        let source = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
            let list = try? SwaTexEngine.displayList(for: macros + source, style: display ? .display : .text)
        else { return nil }
        let svg = SVGRenderer(options: SVGOptions(fontSize: fontSize, padding: 0)).render(list)
        let nsSVG = svg as NSString
        guard let viewBox, let size,
            let box = viewBox.firstMatch(in: svg, range: NSRange(location: 0, length: nsSVG.length)),
            let width = Double(nsSVG.substring(with: box.range(at: 1))),
            let height = Double(nsSVG.substring(with: box.range(at: 2)))
        else { return nil }
        func em(_ value: Double) -> String { String(format: "%.4fem", value * scale) }
        // In em the formula follows the text size of the theme; it sits on the baseline by its depth, and glyphs that
        // reach past the layout box (a fraction's descenders) are not clipped.
        let attributes =
            " width=\"\(em(width / fontSize))\" height=\"\(em(height / fontSize))\""
            + " style=\"vertical-align: -\(em(list.depth)); overflow: visible\""
            + " role=\"img\" aria-label=\"\(HTML.escape(source))\""
        // Only the root element's size: the rules of fractions and radicals are rects with sizes of their own.
        guard let root = size.firstMatch(in: svg, range: NSRange(location: 0, length: nsSVG.length)) else { return nil }
        var html = nsSVG.replacingCharacters(in: root.range, with: attributes)
        // Formulas take the theme's text color unless they set a color of their own.
        html = html.replacingOccurrences(of: "\"rgba(0,0,0,1)\"", with: "\"currentColor\"")
        return "<span class=\"math math-\(display ? "display" : "inline")\">\(html)</span>"
    }

    /// The formula's source as written, marked so a reader sees that it could not be read.
    public static func fallback(_ source: String, display: Bool) -> String {
        display
            ? "<pre class=\"math-error\">\(HTML.escape(source))</pre>"
            : "<code class=\"math-error\">\(HTML.escape(source))</code>"
    }

    private static let face = try? NSRegularExpression(
        pattern: #"font-family="(KaTeX_[A-Za-z0-9]+)"[^>]*? font-weight="(normal|bold)" font-style="(normal|italic)""#)

    /// `@font-face` rules for the KaTeX fonts the formulas use, as data URLs, so the paper renders them without
    /// reading any file next to the document.
    public static func fontFaces(for html: String) -> String {
        guard html.contains("KaTeX_"), let face else { return "" }
        let nsHTML = html as NSString
        var seen = Set<String>()
        var rules: [String] = []
        for match in face.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let family = nsHTML.substring(with: match.range(at: 1))
            let weight = nsHTML.substring(with: match.range(at: 2))
            let style = nsHTML.substring(with: match.range(at: 3))
            let key = "\(family) \(weight) \(style)"
            guard seen.insert(key).inserted, let data = fontData(family: family, weight: weight, style: style) else {
                continue
            }
            rules.append(
                "@font-face { font-family: \"\(family)\"; font-weight: \(weight); font-style: \(style); "
                    + "src: url(\"data:font/ttf;base64,\(data.base64EncodedString())\") format(\"truetype\"); }")
        }
        return rules.joined(separator: "\n")
    }

    /// The bundled KaTeX font for a face, named as KaTeX names its files: `KaTeX_Main-BoldItalic.ttf`.
    static func fontData(family: String, weight: String, style: String) -> Data? {
        let variant =
            switch (weight == "bold", style == "italic") {
            case (true, true): "BoldItalic"
            case (true, false): "Bold"
            case (false, true): "Italic"
            case (false, false): "Regular"
            }
        guard let url = try? CoreResources.url("\(family)-\(variant)", extension: "ttf") else { return nil }
        return try? Data(contentsOf: url)
    }
}

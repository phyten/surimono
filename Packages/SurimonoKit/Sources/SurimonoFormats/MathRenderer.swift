import Foundation
import SwaTex

/// LaTeX math drawn by SwaTex, a KaTeX-compatible engine written in Swift, as inline SVG. The glyphs are text in the
/// bundled math fonts, which `fontFaces(for:)` embeds, so formulas print as vectors and stay selectable, with no JavaScript.
public enum MathRenderer {
    /// KaTeX sets formulas a little larger than the text around them so their x-height matches it.
    static let scale = 1.1
    /// The SVG's own unit; only the ratio to it matters, since the sizes are rewritten in em.
    private static let fontSize = 10.0

    private static let viewBox = try? NSRegularExpression(pattern: #"viewBox="0 0 ([0-9.eE+-]+) ([0-9.eE+-]+)""#)
    private static let size = try? NSRegularExpression(pattern: #" width="[^"]*" height="[^"]*""#)

    /// A primitive assignment only stores tokens. Read exactly one assignment with SwaTex's lexer.
    /// Keep the full validation path if the meaning of either primitive could have changed.
    static func isOrdinaryDefinition(_ source: String) -> Bool {
        func isControlWord(_ text: String) -> Bool {
            text.first == "\\" && text.count > 1 && text.dropFirst().allSatisfy { $0.isASCII && $0.isLetter }
        }
        var lexer = Lexer(source)
        let command = lexer.lex().text
        guard command == "\\def" || command == "\\let" else { return false }
        let name = lexer.lex().text
        guard isControlWord(name), !["\\def", "\\let", "\\verb"].contains(name) else { return false }
        if command == "\\let" {
            guard lexer.lex().text == "=" else { return false }
            let original = lexer.lex().text
            return isControlWord(original) && original != "\\verb" && lexer.pos == source.utf8.count
                && source.last == " "
        }
        var token = lexer.lex()
        var parameter = 0
        while token.text != "{" {
            if token.isEOF || token.text == "\\verb" { return false }
            if token.text == "#" {
                parameter += 1
                guard parameter <= 9, lexer.lex().text == String(parameter) else { return false }
            }
            token = lexer.lex()
        }
        var depth = 1
        while depth > 0 {
            let token = lexer.lex()
            if token.isEOF || token.text == "\\verb" { return false }
            if token.text == "{" { depth += 1 }
            if token.text == "}" { depth -= 1 }
        }
        return lexer.pos == source.utf8.count
    }

    /// The formula as HTML, or nil when SwaTex cannot read it.
    /// - Parameter macros: Definitions put in front of the formula, such as a document's `\newcommand`s; they are
    ///   not part of its accessible label.
    public static func html(_ latex: String, display: Bool, macros: String = "") -> String? {
        html(latex, display: display, macros: macros, rowNumberHTML: [], reportTruncation: false)
    }

    static func html(
        _ latex: String, display: Bool, macros: String, rowNumberHTML: [String?], measureRows: Bool = false,
        reportTruncation: Bool = true, sansMathAlphabet: Bool = false, originalSource: String? = nil
    ) -> String? {
        let source = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, let parsed = try? parseLaTeX(macros + source) else { return nil }
        let nodes = sansMathAlphabet ? parsed.map { sansLetter($0, depth: 0) } : parsed
        let options = LayoutOptions(style: display ? .display : .text)
        let box = layout(nodes, options: options)
        let list = toDisplayList(box)
        guard !reportTruncation || !list.truncated else { return nil }
        let rows = rowNumberHTML.isEmpty ? [] : rowBaselines(in: box)
        let labels = zip(rowNumberHTML, rows).compactMap { number, baseline in
            number.map {
                "<span class=\"latex-row-number\" style=\"top: \(String(format: "%.4f", baseline * 100))%\">\($0)</span>"
            }
        }.joined()
        var metrics = ""
        if measureRows, let first = rows.first, let last = rows.last {
            metrics = " data-latex-first-baseline=\"\(first)\" data-latex-last-baseline=\"\(last)\""
        }
        let renderer = SVGRenderer(options: SVGOptions(fontSize: fontSize, padding: 0))
        let svg = renderer.render(list)
        let nsSVG = svg as NSString
        guard let viewBox, let size,
            let bounds = viewBox.firstMatch(in: svg, range: NSRange(location: 0, length: nsSVG.length)),
            let width = Double(nsSVG.substring(with: bounds.range(at: 1))),
            let height = Double(nsSVG.substring(with: bounds.range(at: 2)))
        else { return nil }
        func em(_ value: Double) -> String { String(format: "%.4fem", value * scale) }
        // In em the formula follows the text size of the theme; it sits on the baseline by its depth, and glyphs that
        // reach past the layout box (a fraction's descenders) are not clipped.
        // cmark still parses the enclosing block. Literal newlines in an attribute can
        // end a list item; keep the original UTF-8 bytes outside Markdown's grammar.
        let original = originalSource ?? latex
        let savedSource =
            original == source ? "" : " data-formula-source=\"\(Data(original.utf8).base64EncodedString())\""
        let attributes =
            " width=\"\(em(width / fontSize))\" height=\"\(em(height / fontSize))\""
            + " style=\"vertical-align: -\(em(list.depth)); overflow: visible\""
            + " role=\"img\" aria-label=\"\(HTML.escape(source))\""
            + savedSource
            + tagAttribute(nodes: nodes, options: options, renderer: renderer, svg: svg)
            + (display ? "" : inlineGlue(nodes: nodes, box: box, list: list))
        // Only the root element's size: the rules of fractions and radicals are rects with sizes of their own.
        guard let root = size.firstMatch(in: svg, range: NSRange(location: 0, length: nsSVG.length)) else { return nil }
        var html = nsSVG.replacingCharacters(in: root.range, with: attributes)
        // Formulas take the theme's text color unless they set a color of their own.
        html = html.replacingOccurrences(of: "\"rgba(0,0,0,1)\"", with: "\"currentColor\"")
        return "<span class=\"math math-\(display ? "display" : "inline")\"\(metrics)>\(html)\(labels)</span>"
    }

    /// Some formats leave tags inside SwaTex's SVG. A phantom keeps the tag column's
    /// exact dimensions, giving us the same paint sequence with just those marks omitted.
    private static func tagAttribute(nodes: [ParseNode], options: LayoutOptions, renderer: SVGRenderer, svg: String)
        -> String
    {
        func mask(_ node: ParseNode) -> ParseNode {
            var node = node
            switch node.kind {
            case .tag(let body, let tag):
                node.kind = .tag(body: body, tag: [ParseNode(.phantom(body: tag), mode: node.mode)])
            case .array(var array) where array.tags != nil:
                array.tags = array.tags?.map { tag in
                    guard case .explicit(let content) = tag else { return tag }
                    return .explicit([ParseNode(.phantom(body: content), mode: node.mode)])
                }
                node.kind = .array(array)
            default: break
            }
            return node
        }
        guard
            nodes.contains(where: { node in
                switch node.kind {
                case .tag: true
                case .array(let info): info.tags != nil
                default: false
                }
            })
        else { return "" }
        let masked = nodes.map(mask)
        let clean = renderer.render(toDisplayList(layout(masked, options: options)))
        // The renderer emits a flat sequence of self-closing shapes and text elements.
        // Include each item's closing tag when comparing, including the glyph's text.
        let shapes = clean.components(separatedBy: "><").dropFirst().dropLast()
        var next = shapes.startIndex
        var tags = [String]()
        for (index, shape) in svg.components(separatedBy: "><").dropFirst().dropLast().enumerated() {
            if next < shapes.endIndex, shape == shapes[next] { next += 1 } else { tags.append(String(index)) }
        }
        guard next == shapes.endIndex, !tags.isEmpty else { return "" }
        return " data-formula-tags=\"\(tags.joined(separator: ","))\""
    }

    /// The root hbox has one child per parsed atom, with automatic kerns inserted
    /// between them. Explicit kerns have their own parse nodes. Never descend into
    /// an atom to discover glue: a group or a script is already a finished box.
    private static func inlineGlue(nodes: [ParseNode], box: LayoutBox, list: DisplayList) -> String {
        guard nodes.count > 1, nodes.count <= 256, !list.truncated, list.width == box.width,
            case .hbox(let children) = box.content, children.count > nodes.count,
            list.items.count <= 512,
            list.items.allSatisfy({
                switch $0 {
                case .glyphPath, .line(_, _, _, _, _, dashed: false): true
                default: false
                }
            })
        else { return "" }
        var index = 0
        var depth = 0
        var x = 0.0
        var cuts: [(child: Int, position: Double, mu: Int)] = []
        var previousMu: Int?
        for node in nodes {
            guard index < children.count else { return "" }
            var explicit = false
            var opens = false
            var closes = false
            var atom = node
            while case .supSub(let base?, _, _) = atom.kind { atom = base }
            var operatorMu: Int?
            switch atom.kind {
            case .kern, .spacing: explicit = true
            case .atom(let family, _):
                operatorMu = family == .rel ? 5 : family == .bin ? 4 : nil
                opens = family == .open
                closes = family == .close
            case .mclass(let name, _, _), .delimSizing(_, let name, _):
                operatorMu = name == "mrel" ? 5 : name == "mbin" ? 4 : nil
                opens = name == "mopen"
                closes = name == "mclose"
            case .tag, .enclose, .color, .cr: return ""
            default: break
            }
            if !explicit, case .kern = children[index].content {
                let width = children[index].width
                let mu = width * 18
                // The pinned engine also uses 4mu between two operators. Only
                // spacing beside a binary or relation atom is TeX operator glue.
                if depth == 0,
                    let kind = [previousMu, operatorMu].compactMap({ $0 }).first(where: {
                        abs(mu - Double($0)) < 0.000001
                    })
                {
                    cuts.append((index, x, kind))
                }
                index += 1
                x += width
                guard index < children.count else { return "" }
            }
            // An ambiguous alignment (e.g. an unsupported node itself returning
            // a bare kern) must not turn an explicit math skip into adjustable glue.
            if !explicit, case .kern = children[index].content { return "" }
            if !explicit { previousMu = operatorMu }
            if opens { depth += 1 }
            if closes { depth = max(0, depth - 1) }
            x += children[index].width
            index += 1
        }
        guard index == children.count, !cuts.isEmpty else { return "" }
        // Each accepted paint item produces one SVG child. Indexing in paint
        // order keeps rules and scripts with their atom even when ink overhangs.
        var items = 0
        var cut = 0
        var fields = ["\(list.items.count),\(fontSize)"]
        for (index, child) in children.enumerated() {
            if cut < cuts.count, cuts[cut].child == index {
                let position = String(format: "%.6f", cuts[cut].position)
                fields.append("\(items),\(position),\(cuts[cut].mu)")
                cut += 1
            }
            if case .kern = child.content { continue }
            items += toDisplayList(child).items.count
        }
        guard items == list.items.count else { return "" }
        return " data-math-glue=\"\(fields.joined(separator: ";"))\""
    }

    /// A numbered alignment stays a single grid so columns align across rows. SwaTex's measured
    /// row heights locate the labels even when a row contains a tall matrix or a stacked fraction.
    /// The surrounding block supplies the width of the paper, which a formula's SVG cannot know.
    private static func rowBaselines(in box: LayoutBox) -> [Double] {
        var grid = box
        while case .hbox(let children) = grid.content,
            let child = children.first(where: { $0.totalHeight > 0 })
        {
            grid = child
        }
        guard case .array(let array) = grid.content, grid.totalHeight > 0 else { return [] }
        var y = grid.height - array.offset
        return zip(array.rowHeights, array.rowDepths).map { height, depth in
            y += height
            let baseline = y / grid.totalHeight
            y += depth
            return baseline
        }
    }

    /// Only strip math-mode delimiters. Numbered or structured environments must paste intact.
    static func withoutDelimiters(_ source: String) -> String {
        for (open, close) in [
            ("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$"),
            ("\\begin{math}", "\\end{math}"), ("\\begin{displaymath}", "\\end{displaymath}"),
        ] {
            if source.hasPrefix(open), source.hasSuffix(close), source.count >= open.count + close.count {
                return String(source.dropFirst(open.count).dropLast(close.count))
            }
        }
        return source
    }

    /// The formula's source as written, marked so a reader sees that it could not be read.
    public static func fallback(_ source: String, display: Bool) -> String {
        display
            ? "<pre class=\"math-error\">\(HTML.escape(source))</pre>"
            : "<code class=\"math-error\">\(HTML.escape(source))</code>"
    }

    private static let face = try? NSRegularExpression(
        pattern: #"font-family="(KaTeX_[A-Za-z0-9]+)"[^>]*? font-weight="(normal|bold)" font-style="(normal|italic)""#)

    /// `@font-face` rules for the bundled fonts the formulas use, as data URLs, so the paper renders them without
    /// reading any file next to the document.
    public static func fontFaces(for html: String, includesAMSMarkers: Bool = false) -> String {
        guard includesAMSMarkers || html.contains("KaTeX_"), let face else { return "" }
        let nsHTML = html as NSString
        var fonts = face.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)).map { match in
            (
                nsHTML.substring(with: match.range(at: 1)), nsHTML.substring(with: match.range(at: 2)),
                nsHTML.substring(with: match.range(at: 3))
            )
        }
        if includesAMSMarkers { fonts.append(("KaTeX_AMS", "normal", "normal")) }
        var seen = Set<String>()
        var rules: [String] = []
        for (family, weight, style) in fonts {
            let key = "\(family) \(weight) \(style)"
            guard seen.insert(key).inserted, let data = fontData(family: family, weight: weight, style: style) else {
                continue
            }
            rules.append(
                "@font-face { font-family: \"\(family)\"; font-weight: \(weight); font-style: \(style); "
                    + "src: url(\"data:font/otf;base64,\(data.base64EncodedString())\") format(\"opentype\"); }")
        }
        return rules.joined(separator: "\n")
    }

    // CSS family keys are part of SwaTex's SVG protocol, also consumed by TikZ.
    // The embedded font programs have independent family and PostScript names.
    private static let resourceFamily = [
        "KaTeX_Main": "Main", "KaTeX_Math": "Letters", "KaTeX_AMS": "Symbols",
        "KaTeX_Caligraphic": "Calligraphic", "KaTeX_Fraktur": "Fraktur", "KaTeX_SansSerif": "Sans",
        "KaTeX_Script": "Script", "KaTeX_Typewriter": "Typewriter", "KaTeX_Size1": "SizeOne",
        "KaTeX_Size2": "SizeTwo", "KaTeX_Size3": "SizeThree", "KaTeX_Size4": "SizeFour",
    ]

    package static func fontData(family: String, weight: String, style: String) -> Data? {
        let variant =
            switch (weight == "bold", style == "italic") {
            case (true, true): "BoldItalic"
            case (true, false): "Bold"
            case (false, true): "Italic"
            case (false, false): "Regular"
            }
        guard let resource = resourceFamily[family],
            let url = Bundle.module.url(forResource: "SurimonoMath\(resource)-\(variant)", withExtension: "otf")
        else { return nil }
        return try? Data(contentsOf: url)
    }
}

import Foundation

/// How a code block is set, beside its colors. The defaults leave the theme's block as it is.
public struct CodeBlockOptions: Codable, Equatable, Sendable {
    public enum Frame: String, Codable, CaseIterable, Sendable {
        /// Whatever the theme gives a code block.
        case style
        case none, tint, rule, left
    }

    public enum LineNumbers: String, Codable, CaseIterable, Sendable {
        case none, all, everyFive
    }

    public enum LongLines: String, Codable, CaseIterable, Sendable {
        case wrap, shrink, cut
    }

    public enum LanguageLabel: String, Codable, CaseIterable, Sendable {
        case none, corner, band
    }

    public var frame: Frame
    public var lineNumbers: LineNumbers
    public var longLines: LongLines
    public var languageLabel: LanguageLabel

    public init(
        frame: Frame = .style, lineNumbers: LineNumbers = .none, longLines: LongLines = .wrap,
        languageLabel: LanguageLabel = .none
    ) {
        self.frame = frame
        self.lineNumbers = lineNumbers
        self.longLines = longLines
        self.languageLabel = languageLabel
    }

    private enum CodingKeys: String, CodingKey { case frame, lineNumbers, longLines, languageLabel }

    /// A value added by a later version falls back to the default without losing the other choices.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func field<Value: Decodable>(_ type: Value.Type, _ key: CodingKeys) -> Value? {
            try? values.decodeIfPresent(type, forKey: key)
        }
        frame = field(Frame.self, .frame) ?? .style
        lineNumbers = field(LineNumbers.self, .lineNumbers) ?? .none
        longLines = field(LongLines.self, .longLines) ?? .wrap
        languageLabel = field(LanguageLabel.self, .languageLabel) ?? .none
    }
}

/// The look of a document's code: the palette and the block's options, layered between the theme and the text size.
public struct CodeStyle: Equatable, Sendable {
    /// nil matches the print theme.
    public var palette: CodePalette?
    public var block: CodeBlockOptions
    /// The mark on a cut line; `%d` stands for the characters left out.
    public var cutFormat: String

    public init(palette: CodePalette? = nil, block: CodeBlockOptions = CodeBlockOptions(), cutFormat: String = "+%d") {
        self.palette = palette
        self.block = block
        self.cutFormat = cutFormat
    }

    /// The theme's own code blocks, with nothing added to the page.
    public var isDefault: Bool { palette == nil && block == CodeBlockOptions() }

    // Plain text, diagrams and math errors are `pre` elements too, but none of them is code. The classes also outrank
    // any theme's selector for a block.
    private static let block = "body.surimono pre:not(.surimono-plain, .mermaid-source, .math-error)"
    private static let padding = "0.65em 0.85em"
    private static let rule = "#8b8b86"

    /// The style sheet's part after the theme; empty when there is nothing to change.
    var css: String {
        guard !isDefault else { return "" }
        var rules: [String] = []
        if let palette { rules.append(palette.css) }
        rules += frameRules
        rules += lineRules
        rules += labelRules
        return rules.joined(separator: "\n")
    }

    private var frameRules: [String] {
        var rules: [String] = []
        let adjust = "-webkit-print-color-adjust: exact; print-color-adjust: exact;"
        switch block.frame {
        case .style: break
        case .none:
            rules.append(
                "\(Self.block) { background: none; border: 0; border-radius: 0; box-shadow: none; padding: 0; }")
        case .tint:
            // Over the paper rather than a fixed color, so a tinted paper keeps its warmth under the block.
            rules.append(
                "\(Self.block) { background: rgba(60, 48, 30, 0.055); border: 0; border-radius: 0; box-shadow: none; "
                    + "padding: \(Self.padding); \(adjust) }")
        case .rule:
            rules.append(
                "\(Self.block) { background: none; border: 0.5pt solid \(Self.rule); border-radius: 0; "
                    + "box-shadow: none; padding: \(Self.padding); }")
        case .left:
            rules.append(
                "\(Self.block) { background: none; border: 0; border-left: 0.28em solid \(Self.rule); "
                    + "border-radius: 0; box-shadow: none; padding: 0.1em 0 0.1em 0.85em; }")
        }
        if let ground = palette?.ground {
            // A dark ground needs room whatever the frame, or the text would touch its edge.
            let padding = block.frame == .left ? "" : " padding: \(Self.padding);"
            rules.append(
                "\(Self.block) { background: \(ground); color: \(palette?.ink ?? "inherit");\(padding) \(adjust) "
                    + "--code-no: #aab1bc; }")
            rules.append("\(Self.block) code { color: inherit; background: none; }")
        } else if let ink = palette?.ink {
            rules.append("\(Self.block) { color: \(ink); }")
            rules.append("\(Self.block) code { color: inherit; }")
        }
        return rules
    }

    private var lineRules: [String] {
        var rules: [String] = []
        let number = "var(--code-no, #5f5f5b)"
        if block.lineNumbers != .none || block.longLines == .cut {
            rules.append(".code-line, .code-src { display: block; }")
            rules.append(".code-src:empty::after { content: \"\\200b\"; }")
        }
        if block.lineNumbers != .none {
            rules.append(
                ".code-numbered .code-line { position: relative; padding-left: "
                    + "calc(var(--code-digits) * 1ch + 0.9em); }")
            rules.append(
                ".code-line[data-no]::before { content: attr(data-no); position: absolute; left: 0; "
                    + "top: 0.16em; width: calc(var(--code-digits) * 1ch / 0.86); font-size: 0.86em; "
                    + "text-align: right; color: \(number); }")
        }
        switch block.longLines {
        case .wrap: break
        case .shrink:
            rules.append("\(Self.block) code { font-size: calc(1em * var(--code-shrink, 1)); }")
        case .cut:
            // The ellipsis stands in if the mark cannot be measured; the mark then takes its place.
            rules.append(".code-src { white-space: pre; overflow: hidden; text-overflow: ellipsis; }")
            rules.append(".code-is-cut { display: flex; }")
            rules.append(".code-is-cut .code-src { flex: 0 1 auto; min-width: 0; text-overflow: clip; }")
            rules.append(
                ".code-cut { flex: none; margin-left: 0.3em; padding: 0 0.3em; font-size: 0.82em; "
                    + "border-left: 1.5px solid currentColor; color: \(number); }")
        }
        return rules
    }

    private var labelRules: [String] {
        let font = "font: 600 0.78em/1.4 -apple-system, \"Hiragino Sans\", sans-serif; font-style: normal;"
        let label = "content: attr(data-code-label); color: var(--code-no, #5f5f5b); \(font)"
        switch block.languageLabel {
        case .none: return []
        case .corner:
            return [
                "pre[data-code-label] { position: relative; }",
                "pre[data-code-label]::before { \(label) position: absolute; right: 0.7em; top: 0.35em; }",
            ]
        case .band:
            return [
                "pre[data-code-label]::before { \(label) display: block; margin-bottom: 0.4em; padding-bottom: 0.18em; "
                    + "border-bottom: 0.5pt solid \(Self.rule); }"
            ]
        }
    }
}

/// Adds to a fragment's code blocks what the style sheet alone cannot: an element for each line and the language's
/// name. Done on the finished fragment, so every converter's blocks get it and a default document stays as it is.
public enum CodeBlockMarkup {
    /// The form every converter writes a code block in; `pre` elements with attributes are something else.
    private static let open = "<pre>"
    private static let close = "</pre>"

    public static func containsCode(_ html: String) -> Bool { html.contains(open) }

    public static func apply(_ options: CodeBlockOptions, to html: String) -> String {
        let splitsLines = options.lineNumbers != .none || options.longLines == .cut
        guard splitsLines || options.languageLabel != .none else { return html }
        var result = ""
        result.reserveCapacity(html.utf8.count)
        var rest = html[...]
        while let start = rest.range(of: open), let end = rest[start.upperBound...].range(of: close) {
            result += rest[..<start.lowerBound]
            result += block(rest[start.upperBound..<end.lowerBound], options: options, splitsLines: splitsLines)
            rest = rest[end.upperBound...]
        }
        return result + rest
    }

    private static func block(_ content: Substring, options: CodeBlockOptions, splitsLines: Bool) -> String {
        var codeTag = ""
        var body = content
        var codeEnd = ""
        if content.hasPrefix("<code"), content.hasSuffix("</code>"), let tagEnd = content.firstIndex(of: ">") {
            codeTag = String(content[...tagEnd])
            body = content[content.index(after: tagEnd)...].dropLast("</code>".count)
            codeEnd = "</code>"
        }
        var attributes = ""
        // A block with markup of its own, from raw HTML, keeps its lines.
        let lines = splitsLines ? self.lines(of: body) : nil
        var text = String(body)
        if let lines {
            let digits = String(lines.count).count
            text = lines.enumerated().map { index, line in
                let number = options.lineNumbers.shows(line: index + 1) ? " data-no=\"\(index + 1)\"" : ""
                return "<span class=\"code-line\"\(number)><span class=\"code-src\">\(line)</span></span>"
            }.joined()
            if options.lineNumbers != .none {
                attributes += " class=\"code-numbered\" style=\"--code-digits: \(digits)\""
            }
        }
        if options.languageLabel != .none, let label = label(inTag: codeTag) {
            attributes += " data-code-label=\"\(HTML.escape(label))\""
        }
        return "<pre\(attributes)>\(codeTag)\(text)\(codeEnd)\(close)"
    }

    private static func label(inTag tag: String) -> String? {
        guard let start = tag.range(of: "language-") else { return nil }
        let info = HTML.unescape(String(tag[start.upperBound...].prefix { $0 != "\"" && $0 != " " }))
        return info.isEmpty ? nil : SyntaxHighlighter.displayName(for: info)
    }

    /// The lines of highlighted code, each closing the spans it leaves open for the next to open again.
    static func lines(of body: Substring) -> [String]? {
        var lines: [String] = []
        var current = ""
        var open: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character == "<" {
                guard let end = body[index...].firstIndex(of: ">") else { return nil }
                let tag = String(body[index...end])
                if tag == "</span>" {
                    guard let last = open.popLast() else { return nil }
                    // A span that ended with the line opens nothing on the next.
                    if current.hasSuffix(last) { current.removeLast(last.count) } else { current += tag }
                } else if tag.hasPrefix("<span class=\"hl-") {
                    open.append(tag)
                    current += tag
                } else {
                    return nil
                }
                index = body.index(after: end)
                continue
            }
            if character.isNewline {
                lines.append(current + String(repeating: "</span>", count: open.count))
                current = open.joined()
            } else {
                current.append(character)
            }
            index = body.index(after: index)
        }
        guard open.isEmpty else { return nil }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}

extension CodeBlockOptions.LineNumbers {
    func shows(line: Int) -> Bool {
        switch self {
        case .none: false
        case .all: true
        case .everyFive: line.isMultiple(of: 5)
        }
    }
}

/// Fits long lines to the width they print at. Only the page can tell: the width depends on the theme's fonts and
/// paddings. Runs with the theme's decorations in the app's isolated world; the document's own JavaScript stays off.
public enum CodeFitScript {
    /// nil when the lines need no fitting.
    /// - Parameter pixelsPerPoint: CSS pixels to a point of the page. The script measures at that width, which printing
    ///   lays out wider than the web view; a capture at the screen's scale draws a pixel to a point.
    public static func javaScript(for style: CodeStyle, pixelsPerPoint: Double) -> String? {
        let body: String
        switch style.block.longLines {
        case .wrap: return nil
        case .shrink: body = shrink
        case .cut: body = cut.replacingOccurrences(of: "$FORMAT", with: quoted(style.cutFormat))
        }
        return """
            {
              const root = document.documentElement;
              const width = root.style.width;
              root.style.width = (root.clientWidth * \(pixelsPerPoint)) + 'px';
            \(body)
              root.style.width = width;
            }
            """
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // The floor keeps code legible; a line still too long then wraps, as it does in the default. Font sizes round, so
    // the scale leaves a little room.
    private static let shrink = """
          for (const code of document.querySelectorAll('pre > code')) {
            const block = code.parentElement;
            block.style.removeProperty('--code-shrink');
            const style = getComputedStyle(block);
            const room = block.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
            code.style.display = 'inline-block';
            code.style.whiteSpace = 'pre';
            const needed = code.offsetWidth;
            code.style.removeProperty('display');
            code.style.removeProperty('white-space');
            if (needed > room && room > 0) {
              block.style.setProperty('--code-shrink', String(Math.max(0.55, room / needed * 0.98)));
            }
          }
        """

    private static let cut = """
          const format = $FORMAT;
          for (const line of document.querySelectorAll('.code-line')) {
            line.classList.remove('code-is-cut');
            for (const mark of line.querySelectorAll('.code-cut')) { mark.remove(); }
            const source = line.querySelector('.code-src');
            if (!source || source.scrollWidth <= source.clientWidth + 1) { continue; }
            const nodes = [];
            const walker = document.createTreeWalker(source, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) { nodes.push(walker.currentNode); }
            const total = nodes.reduce((sum, node) => sum + node.length, 0);
            const mark = document.createElement('span');
            mark.className = 'code-cut';
            // As wide as the mark can be, so that the text does not need it to shrink again afterwards.
            mark.textContent = format.replace('%d', String(total));
            line.classList.add('code-is-cut');
            line.appendChild(mark);
            const range = document.createRange();
            const rightEdge = offset => {
              let rest = offset;
              for (const node of nodes) {
                if (rest < node.length) {
                  range.setStart(node, rest);
                  range.setEnd(node, rest + 1);
                  return range.getBoundingClientRect().right;
                }
                rest -= node.length;
              }
              return Infinity;
            };
            // A second pass counts again with the mark at its real width.
            for (let pass = 0; pass < 2; pass += 1) {
              const limit = source.getBoundingClientRect().right;
              let low = 0;
              let high = total;
              while (low < high) {
                const middle = (low + high) >> 1;
                if (rightEdge(middle) > limit + 0.5) { high = middle; } else { low = middle + 1; }
              }
              mark.textContent = format.replace('%d', String(total - low));
            }
          }
        """
}

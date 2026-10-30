import Foundation
import Markdown

/// Markdown syntax beyond CommonMark and GFM: footnotes, highlights, superscripts and subscripts, ruby, emoji
/// shortcodes, definition lists, heading ids and a table of contents.
///
/// Inline syntax is rewritten into inline HTML before cmark parses the source, so the Markdown inside it still
/// parses (`==**bold**==`) and table pipes inside ruby stay out of cmark's way. Code blocks, HTML blocks, code spans,
/// tags and URLs are left as written.
enum MarkdownExtensions {
    /// Footnote definitions, numbered in the order the text first refers to them.
    final class Footnotes {
        let definitions: [String: String]
        private(set) var order: [String] = []
        private var referenceCounts: [String: Int] = [:]

        init(definitions: [String: String]) {
            self.definitions = definitions
        }

        func number(of id: String) -> Int? { order.firstIndex(of: id).map { $0 + 1 } }

        /// The reference's HTML, or nil for an id without a definition, which stays as written.
        fileprivate func reference(to label: String) -> String? {
            let id = label.lowercased()
            guard definitions[id] != nil else { return nil }
            let number: Int
            if let index = order.firstIndex(of: id) {
                number = index + 1
            } else {
                order.append(id)
                number = order.count
            }
            let count = referenceCounts[id, default: 0] + 1
            referenceCounts[id] = count
            let anchor = count == 1 ? "fnref-\(number)" : "fnref-\(number)-\(count)"
            return "<sup class=\"footnote-ref\"><a href=\"#fn-\(number)\" id=\"\(anchor)\">\(number)</a></sup>"
        }
    }

    /// Formulas taken out of the text before cmark parses it, so its emphasis and escapes cannot reach the LaTeX.
    /// Inline formulas leave a token in the text, which `restore(_:)` turns back into their HTML.
    final class Formulas {
        private var html: [String] = []
        /// Random for each document, so a token never matches text the document itself contains.
        private let nonce = String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement() ?? "x" })
        private lazy var pattern = try? NSRegularExpression(pattern: "\u{E000}\(nonce)([0-9]+)\u{E001}")

        fileprivate func token(_ latex: String, display: Bool, source: String) -> String {
            html.append(MathRenderer.html(latex, display: display) ?? MathRenderer.fallback(source, display: display))
            return "\u{E000}\(nonce)\(html.count - 1)\u{E001}"
        }

        /// A display formula on lines of its own, as an HTML block.
        fileprivate func block(_ latex: String, source: String) -> String {
            let formula = MathRenderer.html(latex, display: true) ?? MathRenderer.fallback(source, display: true)
            return "<div class=\"math-block\">\(formula)</div>"
        }

        /// Puts the formulas back into rendered HTML.
        func restore(_ text: String) -> String { replacingTokens(in: text) { $0 } }

        /// The text without its formula tokens, for titles, anchors and alternative text.
        func strip(_ text: String) -> String { replacingTokens(in: text) { _ in "" } }

        /// Only tokens this document issued are replaced; anything else stays as written.
        private func replacingTokens(in text: String, with replacement: (String) -> String) -> String {
            guard text.contains("\u{E000}"), let regex = pattern else { return text }
            let nsText = text as NSString
            var output = ""
            var cursor = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                guard let index = Int(nsText.substring(with: match.range(at: 1))), html.indices.contains(index) else {
                    continue
                }
                output += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                output += replacement(html[index])
                cursor = match.range.location + match.range.length
            }
            return output + nsText.substring(from: cursor)
        }
    }

    // MARK: - Source rewriting

    /// The parts of the source the extensions leave as written: whole lines of code blocks, HTML blocks and link
    /// reference definitions, and the columns of code spans that run over several lines. A code span on one line is
    /// recognized by the inline pattern itself, so syntax around it, such as `==a `b` c==`, still applies.
    struct Protection {
        var lines: [Bool]
        /// UTF-8 offsets within each line.
        var spans: [Int: [Range<Int>]] = [:]

        /// Whether the line's first character is left as written.
        func protectsStart(of line: Int) -> Bool {
            lines[line] || spans[line]?.contains(where: { $0.lowerBound == 0 }) == true
        }
    }

    /// Block quote markers and list markers in front of a line's own content.
    private static let containerPrefix = try? NSRegularExpression(
        pattern: #"^(?:[ \t]*(?:>|(?:[-+*]|[0-9]{1,9}[.)])(?=[ \t])))*[ \t]*"#)
    private static let referenceLabel = try? NSRegularExpression(pattern: #"^\[(?!\^)(?:[^\]\\]|\\.)+\]:"#)

    static func protection(_ lines: [String]) -> Protection {
        var result = Protection(lines: Array(repeating: false, count: lines.count))
        func visit(_ node: any Markup) {
            guard let range = node.range else {
                for child in node.children { visit(child) }
                return
            }
            if node is CodeBlock || node is HTMLBlock {
                let start = max(range.lowerBound.line - 1, 0)
                let end = min(range.upperBound.line - (range.upperBound.column == 1 ? 1 : 0), lines.count)
                for index in start..<max(end, start + 1) where index < lines.count { result.lines[index] = true }
                return
            }
            if node is InlineCode, range.lowerBound.line != range.upperBound.line {
                let first = range.lowerBound.line - 1
                let last = range.upperBound.line - 1
                for index in first...last where index >= 0 && index < lines.count {
                    let lower = index == first ? range.lowerBound.column - 1 : 0
                    let upper = index == last ? range.upperBound.column - 1 : lines[index].utf8.count
                    if lower < upper { result.spans[index, default: []].append(lower..<upper) }
                }
                return
            }
            for child in node.children { visit(child) }
        }
        visit(Document(parsing: lines.joined(separator: "\n"), options: [.disableSmartOpts]))
        for index in referenceDefinitionLines(lines, skipping: result.lines) { result.lines[index] = true }
        return result
    }

    /// Whether the text holds the closing mark, not counting one escaped with a backslash.
    private static func closes(_ text: Substring, _ closer: Character) -> Bool {
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == closer {
                return true
            }
        }
        return false
    }

    /// The lines of link reference definitions, which leave no node in the tree: the label line, a destination on
    /// the next line, and a title that may run over several lines. Block quote markers in front are skipped.
    private static func referenceDefinitionLines(_ lines: [String], skipping protected: [Bool]) -> Set<Int> {
        func content(_ index: Int) -> Substring {
            let line = lines[index]
            let prefix = containerPrefix?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
            guard let prefix, let range = Range(prefix.range, in: line) else { return Substring(line) }
            return line[range.upperBound...]
        }
        func trimmed(_ text: Substring) -> Substring { text.drop(while: { $0 == " " || $0 == "\t" }) }
        var result = Set<Int>()
        var index = 0
        while index < lines.count {
            let label = content(index)
            guard !protected[index], label.contains("]:"),
                let match = referenceLabel?.firstMatch(
                    in: String(label), range: NSRange(label.startIndex..., in: label)),
                let end = Range(match.range, in: String(label))?.upperBound
            else {
                index += 1
                continue
            }
            result.insert(index)
            var cursor = index
            var rest = trimmed(String(label)[end...])
            if rest.isEmpty {
                // The destination may start on the next line.
                guard cursor + 1 < lines.count, !trimmed(content(cursor + 1)).isEmpty else {
                    index += 1
                    continue
                }
                cursor += 1
                result.insert(cursor)
                rest = trimmed(content(cursor))
            }
            // Skip the destination, written in angle brackets or as a run without spaces.
            if rest.first == "<", let close = rest.firstIndex(of: ">") {
                rest = rest[rest.index(after: close)...]
            } else {
                rest = rest.drop(while: { $0 != " " && $0 != "\t" })
            }
            rest = trimmed(rest)
            if rest.isEmpty, cursor + 1 < lines.count, let first = trimmed(content(cursor + 1)).first,
                "\"'(".contains(first)
            {
                // The title may start on the next line.
                cursor += 1
                result.insert(cursor)
                rest = trimmed(content(cursor))
            }
            if let opener = rest.first, "\"'(".contains(opener) {
                // A title runs until its closing mark; a blank line ends the definition in any case.
                let closer: Character = opener == "(" ? ")" : opener
                var text = rest.dropFirst()
                while !closes(text, closer), cursor + 1 < lines.count, !trimmed(content(cursor + 1)).isEmpty {
                    cursor += 1
                    result.insert(cursor)
                    text = content(cursor)
                }
            }
            index = cursor + 1
        }
        return result
    }

    /// Takes the footnote definitions out of the text. A definition continues on lines indented by four spaces or a
    /// tab, which may be separated by blank lines.
    static func extractFootnotes(_ lines: [String]) -> (lines: [String], definitions: [String: String]) {
        guard
            let regex = try? NSRegularExpression(pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]?(.*)$"#),
            lines.contains(where: { $0.contains("[^") })
        else { return (lines, [:]) }
        let protection = protection(lines)
        var output: [String] = []
        var definitions: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard !protection.protectsStart(of: index),
                let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                let labelRange = Range(match.range(at: 1), in: line),
                let firstRange = Range(match.range(at: 2), in: line)
            else {
                output.append(line)
                index += 1
                continue
            }
            var body = [String(line[firstRange])]
            index += 1
            while index < lines.count {
                if let content = indentedContent(lines[index]) {
                    body.append(content)
                    index += 1
                } else if isBlank(lines[index]) {
                    // Blank lines belong to the note only when an indented line follows them.
                    var next = index
                    while next < lines.count, isBlank(lines[next]) { next += 1 }
                    guard next < lines.count, indentedContent(lines[next]) != nil else { break }
                    body += Array(repeating: "", count: next - index)
                    index = next
                } else {
                    break
                }
            }
            let id = line[labelRange].lowercased()
            if definitions[id] == nil { definitions[id] = body.joined(separator: "\n") }
        }
        return (output, definitions)
    }

    private static func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    private static func indentedContent(_ line: String) -> String? {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
        return nil
    }

    /// Rewrites the inline syntax of every line outside code and HTML blocks. The title on a `:::` line is plain text
    /// (`MarkdownCallouts` escapes it), so the line is left as written.
    static func rewriteInline(_ lines: [String], footnotes: Footnotes, formulas: Formulas) -> [String] {
        let protection = protection(lines)
        var output: [String] = []
        var index = 0
        // How far an unclosed formula was searched, by closing mark and container; a later opening of the same kind
        // before that line would find no end either.
        var searched: [String: Int] = [:]
        while index < lines.count {
            let line = lines[index]
            if protection.lines[index] || line.drop(while: { $0 == " " }).hasPrefix(":::") {
                output.append(line)
                index += 1
                continue
            }
            if protection.spans[index] == nil {
                switch displayBlock(lines, at: index, protection: protection, searched: &searched) {
                case .block(let block):
                    // An HTML block ends only at a blank line, so one follows to keep the next lines out of it.
                    output += [block.prefix + formulas.block(block.latex, source: block.source), block.blankLine]
                    index = block.end
                    continue
                case .none:
                    break
                }
            }
            index += 1
            guard let spans = protection.spans[index - 1] else {
                output.append(rewriteInline(line, footnotes, formulas))
                continue
            }
            let bytes = Array(line.utf8)
            func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
            var rewritten = ""
            var cursor = 0
            for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) where span.lowerBound >= cursor {
                rewritten += rewriteInline(text(cursor..<span.lowerBound), footnotes, formulas) + text(span)
                cursor = span.upperBound
            }
            output.append(rewritten + rewriteInline(text(cursor..<bytes.count), footnotes, formulas))
        }
        return output
    }

    private struct DisplayBlock {
        let prefix: String
        let latex: String
        let source: String
        let blankLine: String
        let end: Int
    }

    private enum DisplaySearch {
        case block(DisplayBlock)
        case none
    }

    /// A display formula that starts a line with `$$` or `\[` and ends a line with `$$` or `\]`, on one line or
    /// several. The following lines keep everything but the block quote markers of the opening line, so `- x` and
    /// `> 0` stay in the formula. A line outside those quotes, a line indented less than the opening line's content
    /// (the next list item, or text after the list), or a blank line (TeX allows none in display math) ends the
    /// search.
    private static func displayBlock(
        _ lines: [String], at index: Int, protection: Protection, searched: inout [String: Int]
    ) -> DisplaySearch {
        let line = lines[index]
        let prefixEnd =
            containerPrefix?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
            .flatMap { Range($0.range, in: line)?.upperBound } ?? line.startIndex
        let prefix = String(line[..<prefixEnd])
        let opening = line[prefixEnd...].trimmingCharacters(in: .whitespaces)
        let delimiters = [("$$", "$$"), ("\\[", "\\]")]
        guard let (opener, closer) = delimiters.first(where: { opening.hasPrefix($0.0) }) else { return .none }
        let rest = String(opening.dropFirst(opener.count))
        let blankLine = String(prefix.map { $0 == ">" ? ">" : " " }).trimmingCharacters(in: .whitespaces)
        if let close = rest.range(of: closer) {
            // `$$a$$` alone on its line; with text after it, the formula is inline and handled with the text.
            guard close.upperBound == rest.endIndex, close.lowerBound != rest.startIndex else { return .none }
            return .block(
                DisplayBlock(
                    prefix: prefix, latex: String(rest[..<close.lowerBound]), source: opening, blankLine: blankLine,
                    end: index + 1))
        }
        let containers = containers(of: prefix)
        let key = closer + containers.map { if case .list(let width) = $0 { "l\(width)" } else { "q" } }.joined()
        guard index >= searched[key, default: 0] else { return .none }
        var latex = [rest]
        var source = [opening]
        var cursor = index + 1
        func unclosed() -> DisplaySearch {
            searched[key] = cursor
            return .none
        }
        while cursor < lines.count {
            guard !protection.lines[cursor], let inside = content(of: lines[cursor], in: containers) else {
                return unclosed()
            }
            let text = inside.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return unclosed() }
            source.append(text)
            if text.hasSuffix(closer) {
                latex.append(String(text.dropLast(closer.count)))
                return .block(
                    DisplayBlock(
                        prefix: prefix, latex: latex.joined(separator: "\n"), source: source.joined(separator: "\n"),
                        blankLine: blankLine, end: cursor + 1))
            }
            latex.append(text)
            cursor += 1
        }
        return unclosed()
    }

    /// A block quote, or a list item (or plain indentation) whose content starts `width` columns in.
    private enum Container {
        case quote
        case list(width: Int)
    }

    private static let listMarker = try? NSRegularExpression(pattern: #"^(?:[-+*]|[0-9]{1,9}[.)])(?=[ \t]|$)"#)

    /// The opening line's containers in the order they nest, read from its prefix. Widths count columns, with a tab
    /// to the next multiple of four from where it stands.
    private static func containers(of prefix: String) -> [Container] {
        var result: [Container] = []
        var rest = Substring(prefix)
        var column = 0
        while !rest.isEmpty {
            let (leading, leadingCount) = whitespace(rest, from: column)
            let marker = rest.dropFirst(leadingCount)
            if marker.first == ">" {
                result.append(.quote)
                column += leading + 1
                rest = marker.dropFirst()
                if rest.first == " " {
                    rest = rest.dropFirst()
                    column += 1
                }
            } else if let match = listMarker?.firstMatch(
                in: String(marker), range: NSRange(marker.startIndex..., in: marker))
            {
                let markerEnd = column + leading + match.range.length
                let afterMarker = marker.dropFirst(match.range.length)
                let (gap, gapCount) = whitespace(afterMarker, from: markerEnd)
                // CommonMark: content starts one to four columns after the marker; with none or five or more, one.
                let padding = (1...4).contains(gap) ? gap : 1
                result.append(.list(width: leading + match.range.length + padding))
                column = markerEnd + gap
                rest = afterMarker.dropFirst(gapCount)
            } else {
                if leading > 0 { result.append(.list(width: leading)) }
                break
            }
        }
        return result
    }

    /// The line's content inside the containers, or nil when it has left one: fewer quote markers, or less
    /// indentation than a list item's content (the next item, or text after the list).
    private static func content(of line: String, in containers: [Container]) -> Substring? {
        var rest = Substring(line)
        var column = 0
        // Columns of a tab already passed but not yet taken by a container: one tab may indent two nested items.
        var spare = 0
        for container in containers {
            switch container {
            case .quote:
                spare = 0
                let (leading, leadingCount) = whitespace(rest, from: column)
                let marker = rest.dropFirst(leadingCount)
                guard marker.first == ">" else { return nil }
                column += leading + 1
                rest = marker.dropFirst()
                if rest.first == " " {
                    rest = rest.dropFirst()
                    column += 1
                }
            case .list(let width):
                guard spare + whitespace(rest, from: column).columns >= width else { return nil }
                var needed = width - min(spare, width)
                spare -= width - needed
                while needed > 0, let first = rest.first {
                    let step = first == "\t" ? 4 - column % 4 : 1
                    column += step
                    rest = rest.dropFirst()
                    spare = max(step - needed, 0)
                    needed = max(needed - step, 0)
                }
            }
        }
        return rest
    }

    /// The columns and characters of the leading spaces and tabs, starting at `column`.
    private static func whitespace(_ text: Substring, from column: Int) -> (columns: Int, count: Int) {
        var end = column
        var count = 0
        for character in text {
            if character == " " {
                end += 1
            } else if character == "\t" {
                end += 4 - end % 4
            } else {
                break
            }
            count += 1
        }
        return (end - column, count)
    }

    private static let inlinePattern: NSRegularExpression? = {
        // Formulas come first so that `\(` and `\[` open a formula rather than escape a bracket. An inline `$` must
        // touch its formula on both sides and not be followed by a digit, so prices such as $5 and $10 stay text.
        // Inside, a backslash and the next character go together (`\$` is LaTeX's dollar sign). A `$` escaped in the
        // text is consumed by the escape below before it could open a formula, so the opening is not checked for one.
        let math = [
            #"\$\$(?<displayMath>[^$\n]+?)\$\$"#,
            #"\\\[(?<displayMath2>.+?)\\\]"#,
            #"\\\((?<inlineMath2>.+?)\\\)"#,
            #"(?<!\$)\$(?<inlineMath>(?=[^\s$])(?:\\.|[^$\\\n])*?(?<=[^\s]))\$(?![0-9$])"#,
        ].joined(separator: "|")
        let verbatim = [
            #"\\[\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E]"#,  // a backslash escape
            #"(?<!`)(?<ticks>`+)(?:.*?[^`])?\k<ticks>(?!`)"#,  // a code span on one line
            #"<[A-Za-z/!?][^<>\n]*>"#,  // a tag or an autolink
            #"\]\((?:[^()\s]|\([^()\s]*\))*(?:\s+(?:"[^"]*"|'[^']*'))?\)"#,  // a link destination
            #"(?:https?://|www\.)[^\s<]+"#,  // a bare URL
        ].joined(separator: "|")
        let syntax = [
            #"\[\^(?<footnote>[^\]\s]+)\]"#,
            #"\{(?<rubyBase>[^{}|\n]+)\|(?<rubyText>[^{}\n]+)\}"#,
            #"(?<![=\\])==(?=[^\s=])(?<mark>.+?)(?<=[^\s\\])==(?!=)"#,
            #"(?<![\\^])\^(?=[^\s^])(?<sup>[^\s^]+?)\^(?!\^)"#,
            #"(?<![~\\])~(?=[^\s~])(?<sub>[^\s~]+?)~(?!~)"#,
        ].joined(separator: "|")
        return try? NSRegularExpression(pattern: "\(math)|(?<verbatim>\(verbatim))|\(syntax)")
    }()

    private static func rewriteInline(_ text: String, _ footnotes: Footnotes, _ formulas: Formulas) -> String {
        guard let regex = inlinePattern, text.contains(where: { "[{=^~$\\".contains($0) }) else { return text }
        let nsText = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            output += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let whole = nsText.substring(with: match.range)
            func capture(_ name: String) -> String? {
                let range = match.range(withName: name)
                return range.location == NSNotFound ? nil : nsText.substring(with: range)
            }
            if let latex = capture("displayMath") ?? capture("displayMath2") {
                output += formulas.token(latex, display: true, source: whole)
            } else if let latex = capture("inlineMath") ?? capture("inlineMath2") {
                output += formulas.token(latex, display: false, source: whole)
            } else if capture("verbatim") != nil {
                output += whole
            } else if let label = capture("footnote") {
                output += footnotes.reference(to: label) ?? whole
            } else if let base = capture("rubyBase"), let reading = capture("rubyText") {
                output += ruby(base: base, reading: reading)
            } else if let content = capture("mark") {
                output += "<mark>" + rewriteInline(content, footnotes, formulas) + "</mark>"
            } else if let content = capture("sup") {
                output += "<sup>" + content + "</sup>"
            } else if let content = capture("sub") {
                output += "<sub>" + content + "</sub>"
            } else {
                output += whole
            }
        }
        return output + nsText.substring(from: cursor)
    }

    /// `{漢字|かんじ}` reads the whole word; `{漢字|かん|じ}` gives each character its own reading.
    private static func ruby(base: String, reading: String) -> String {
        let readings = reading.components(separatedBy: "|")
        let characters = Array(base)
        let pairs: [(String, String)] =
            readings.count > 1 && readings.count == characters.count
            ? zip(characters, readings).map { (String($0), $1) }
            : [(base, readings.joined())]
        let body = pairs.map { "\(HTML.escape($0))<rp>(</rp><rt>\(HTML.escape($1))</rt><rp>)</rp>" }.joined()
        return "<ruby>\(body)</ruby>"
    }

    // MARK: - Emoji

    private static let emojiTable: [String: String] = {
        guard let url = try? CoreResources.url("emoji", extension: "json"), let data = try? Data(contentsOf: url),
            let table = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return table
    }()

    private static let emojiPattern = try? NSRegularExpression(pattern: #":([a-z0-9_+\-]+):"#)

    /// Replaces GitHub's emoji shortcodes, such as `:tada:`; unknown names stay as written.
    static func emojified(_ text: String) -> String {
        guard text.contains(":"), let regex = emojiPattern else { return text }
        let nsText = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            guard match.range.location >= cursor, let emoji = emojiTable[nsText.substring(with: match.range(at: 1))]
            else { continue }
            output += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + emoji
            cursor = match.range.location + match.range.length
        }
        return output + nsText.substring(from: cursor)
    }

    // MARK: - Headings

    struct HeadingAnchor: Equatable {
        let level: Int
        let id: String
        let text: String
    }

    private static let customID = try? NSRegularExpression(pattern: #"\s*\{#([^}\s]+)\}\s*$"#)

    /// The id written as `{#id}` at the end of a heading, and the text without it.
    static func splitCustomID(_ text: String) -> (text: String, id: String?) {
        let nsText = text as NSString
        guard let regex = customID,
            let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length))
        else { return (text, nil) }
        return (nsText.substring(to: match.range.location), nsText.substring(with: match.range(at: 1)))
    }

    /// The heading's text as a reader sees it: the inline HTML of rewritten syntax, such as a footnote reference,
    /// does not count.
    static func plainText(_ node: any Markup, formulas: Formulas? = nil) -> String {
        switch node {
        case let text as Text: return formulas.map { $0.strip(emojified(text.string)) } ?? emojified(text.string)
        case let code as InlineCode: return code.code
        case is SoftBreak, is LineBreak: return " "
        case is InlineHTML: return ""
        default:
            // A footnote reference's number is markup of its own, not part of the text around it.
            var insideReference = false
            return node.children.map { child -> String in
                if let html = child as? InlineHTML {
                    if html.rawHTML.hasPrefix("<sup class=\"footnote-ref\"") { insideReference = true }
                    if html.rawHTML == "</sup>" { insideReference = false }
                    return ""
                }
                return insideReference ? "" : plainText(child, formulas: formulas)
            }.joined()
        }
    }

    /// GitHub's anchors: lower case, spaces to hyphens, punctuation dropped. Japanese and other letters stay.
    static func slug(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.filter { scalar in
            scalar == " " || scalar == "-" || scalar == "_"
                || CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")
    }

    /// Every heading's anchor in document order; a repeated id gets `-1`, `-2`… as on GitHub.
    static func headingAnchors(in document: any Markup, formulas: Formulas? = nil) -> [HeadingAnchor] {
        var anchors: [HeadingAnchor] = []
        var used: [String: Int] = [:]
        func visit(_ node: any Markup) {
            if let heading = node as? Heading {
                let (text, custom) = splitCustomID(plainText(heading, formulas: formulas))
                let base = custom ?? (slug(text).isEmpty ? "section" : slug(text))
                var id = base
                if let count = used[base] {
                    var next = count
                    repeat {
                        next += 1
                        id = "\(base)-\(next)"
                    } while used[id] != nil
                    used[base] = next
                }
                used[id] = used[id] ?? 0
                anchors.append(HeadingAnchor(level: heading.level, id: id, text: text))
                return
            }
            for child in node.children { visit(child) }
        }
        visit(document)
        return anchors
    }

    /// `[TOC]`, `[[toc]]` or GitLab's `[[_TOC_]]` alone in a paragraph. cmark reads `_TOC_` as emphasis.
    static func isTableOfContentsMarker(_ paragraph: Paragraph) -> Bool {
        guard paragraph.children.allSatisfy({ $0 is Text || ($0 is Emphasis && $0.children.allSatisfy { $0 is Text }) })
        else { return false }
        let text = plainText(paragraph).trimmingCharacters(in: .whitespaces).lowercased()
        return ["[toc]", "[[toc]]"].contains(text)
    }

    /// Nested links to the headings. The top level is the highest heading level, or the next one when a single
    /// heading (usually the title) has the highest level; three levels are listed.
    static func tableOfContents(_ anchors: [HeadingAnchor]) -> String {
        guard let highest = anchors.map(\.level).min() else { return "" }
        let top =
            anchors.filter { $0.level == highest }.count == 1 && anchors.contains(where: { $0.level > highest })
            ? anchors.filter { $0.level > highest }.map(\.level).min() ?? highest : highest
        let entries = anchors.filter { $0.level >= top && $0.level < top + 3 }
        guard !entries.isEmpty else { return "" }
        var html = "<nav class=\"toc\">"
        var depth = 0
        var open: [Bool] = []
        for entry in entries {
            let level = entry.level - top + 1
            while depth < level {
                html += "<ul>"
                depth += 1
                open.append(false)
            }
            while depth > level {
                if open.removeLast() { html += "</li>" }
                html += "</ul>"
                depth -= 1
            }
            if open.last == true { html += "</li>" }
            html += "<li><a href=\"#\(HTML.escape(entry.id))\">\(HTML.escape(entry.text))</a>"
            open[open.count - 1] = true
        }
        while depth > 0 {
            if open.removeLast() { html += "</li>" }
            html += "</ul>"
            depth -= 1
        }
        return html + "</nav>\n"
    }

    // MARK: - Definition lists

    /// Whether an inline line opens a definition, `: text`. Text nodes have already decoded escapes and character
    /// references, so only a colon written as such in the source opts in.
    static func definitionBody(_ line: [any InlineMarkup], sourceLines: [String]) -> [any InlineMarkup]? {
        guard let first = line.first as? Text, first.string.hasPrefix(": ") || first.string.hasPrefix(":\t"),
            let start = first.range?.lowerBound, start.line >= 1, start.line <= sourceLines.count, start.column >= 1,
            sourceLines[start.line - 1].utf8.dropFirst(start.column - 1).first == UInt8(ascii: ":")
        else { return nil }
        let rest = String(first.string.dropFirst(2)).drop(while: { $0 == " " || $0 == "\t" })
        return (rest.isEmpty ? [] : [Text(String(rest))]) + line.dropFirst()
    }

    /// A paragraph's inline content split at its line breaks.
    static func lines(of paragraph: Paragraph) -> [[any InlineMarkup]] {
        var lines: [[any InlineMarkup]] = [[]]
        for child in paragraph.children {
            if child is SoftBreak || child is LineBreak {
                lines.append([])
            } else if let inline = child as? any InlineMarkup {
                lines[lines.count - 1].append(inline)
            }
        }
        return lines
    }
}

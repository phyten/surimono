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
        private var numbers: [String: Int] = [:]
        private var referenceCounts: [String: Int] = [:]

        init(definitions: [String: String]) {
            self.definitions = definitions
        }

        /// Rendering a note may discover another. Both the printed section and the prose reader consume this order.
        func forEachReferenced(_ visit: (Int, String) -> Void) {
            var index = 0
            while index < order.count, !PreviewConversion.expired {
                visit(index, order[index])
                index += 1
            }
        }

        func number(of id: String) -> Int? { numbers[id] }

        /// The reference's HTML, or nil for an id without a definition, which stays as written.
        fileprivate func reference(to label: String) -> String? {
            let id = label.lowercased()
            guard definitions[id] != nil else { return nil }
            let number: Int
            if let existing = numbers[id] {
                number = existing
            } else {
                order.append(id)
                number = order.count
                numbers[id] = number
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
        let citations: MarkdownCitations?

        init(citations: MarkdownCitations? = nil) { self.citations = citations }

        fileprivate lazy var escapedCitationSign = "\u{E004}\(nonce)\u{E005}"

        /// Random for each document, so a token never matches text the document itself contains.
        private let nonce = String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement() ?? "x" })
        private lazy var pattern = try? NSRegularExpression(pattern: "\u{E000}\(nonce)([0-9]+)\u{E001}")

        fileprivate func token(_ latex: String, display: Bool, source: String) -> String {
            html.append(MathRenderer.html(latex, display: display) ?? MathRenderer.fallback(source, display: display))
            return "\u{E000}\(nonce)\(html.count - 1)\u{E001}"
        }

        /// A display formula on lines of its own, as an HTML block.
        fileprivate func block(_ latex: String, source: String) -> String {
            let formula =
                MathRenderer.html(
                    latex, display: true, macros: "", rowNumberHTML: [], reportTruncation: false,
                    originalSource: MathRenderer.withoutDelimiters(source))
                ?? MathRenderer.fallback(source, display: true)
            return "<div class=\"math-block\">\(formula)</div>"
        }

        /// Puts the formulas back into rendered HTML.
        func restore(_ text: String) -> String { replacingTokens(in: text) { $0 } }

        /// The text without its formula tokens, for titles, anchors and alternative text.
        func strip(_ text: String) -> String { replacingTokens(in: text) { _ in "" } }

        /// Only tokens this document issued are replaced; anything else stays as written.
        private func replacingTokens(in text: String, with replacement: (String) -> String) -> String {
            let text =
                citations != nil && text.contains("\u{E004}")
                ? text.replacingOccurrences(of: escapedCitationSign, with: "@") : text
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
        var paragraphEnds: [Int: Int] = [:]

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
            if PreviewConversion.expired { return }
            guard let range = node.range else {
                for child in node.children { visit(child) }
                return
            }
            if node is Paragraph {
                let start = max(range.lowerBound.line - 1, 0)
                let end = min(range.upperBound.line, lines.count)
                for index in start..<end { result.paragraphEnds[index] = end }
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
        visit(MarkdownNesting.document(parsing: lines.joined(separator: "\n"), options: [.disableSmartOpts]))
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
        let mapped = extractFootnotes(MarkdownSourceLines.unmapped(lines))
        return (mapped.body.lines, mapped.definitions.mapValues { $0.lines.joined(separator: "\n") })
    }

    static func extractFootnotes(_ source: MarkdownSourceLines)
        -> (body: MarkdownSourceLines, definitions: [String: MarkdownSourceLines])
    {
        let lines = source.lines
        guard
            let regex = try? NSRegularExpression(pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]?(.*)$"#),
            lines.contains(where: { $0.contains("[^") })
        else { return (source, [:]) }
        let protection = protection(lines)
        var output = MarkdownSourceLines()
        var definitions: [String: MarkdownSourceLines] = [:]
        var index = 0
        while index < lines.count {
            if PreviewConversion.expired { return (output, definitions) }
            let line = lines[index]
            guard !protection.protectsStart(of: index),
                let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                let labelRange = Range(match.range(at: 1), in: line),
                let firstRange = Range(match.range(at: 2), in: line)
            else {
                output.append(line, from: source.origins[index])
                index += 1
                continue
            }
            let start = index
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
            if definitions[id] == nil {
                definitions[id] = MarkdownSourceLines(body, origins: Array(source.origins[start..<index]))
            }
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
    static func rewriteInline(_ lines: [String], footnotes: Footnotes, formulas: Formulas, proof: ProofMarks = .shown)
        -> [String]
    {
        rewriteInline(MarkdownSourceLines.unmapped(lines), footnotes: footnotes, formulas: formulas, proof: proof).lines
    }

    /// When the prose reader supplies a callback, report each inline formula's input line and UTF-16 range.
    /// Preserve the spelling and columns of those lines, and omit typesetting for display blocks.
    static func rewriteInline(
        _ source: MarkdownSourceLines, footnotes: Footnotes, formulas: Formulas, proof: ProofMarks = .shown,
        proseFormula: ((Int, NSRange) -> Void)? = nil
    ) -> MarkdownSourceLines {
        let blocksOnly = proseFormula != nil
        let lines = source.lines
        let protection = protection(lines)
        var output = MarkdownSourceLines()
        var index = 0
        // How far an unclosed formula was searched, by closing mark and container; a later opening of the same kind
        // before that line would find no end either.
        var searched: [String: Int] = [:]
        // By paragraph end and container nesting, the last search of the paragraph that did not join. Searching it
        // again from each later line took quadratic time: 8,000 lines with a brace each took over ten seconds.
        var scanned: [Int: [[Container]: ParagraphScan]] = [:]
        // The first protected line at or after each line, found once: checking every line of the rest of the
        // paragraph again from each line with a brace was quadratic when one code span ended a long paragraph.
        var nextProtected = [Int](repeating: lines.count, count: lines.count + 1)
        for line in stride(from: lines.count - 1, through: 0, by: -1) {
            nextProtected[line] =
                protection.lines[line] || protection.spans[line] != nil ? line : nextProtected[line + 1]
        }
        // By paragraph end and container nesting, the line that could not join: it is read in that nesting alone, so
        // an attempt from an earlier line with the same nesting stops there too.
        var unjoinable: [Int: [[Container]: Int]] = [:]
        // Tests compare the memos with a search from every line, as origin/master made.
        let remembers = Thread.current.threadDictionary[searchesEveryLineKey] == nil
        let count = Thread.current.threadDictionary[countsScannedLinesKey] as? LineCount
        while index < lines.count {
            if PreviewConversion.expired { return output }
            let line = lines[index]
            if protection.lines[index] || line.drop(while: { $0 == " " }).hasPrefix(":::") {
                output.append(line, from: source.origins[index])
                index += 1
                continue
            }
            if let end = protection.paragraphEnds[index],
                end > index + 1, line.contains("{")
            {
                if !remembers {
                    unjoinable = [:]
                    scanned = [:]
                }
                switch multilineProof(
                    lines, start: index, end: end, nextProtected: nextProtected,
                    unjoinable: &unjoinable[end, default: [:]], scanned: &scanned[end, default: [:]],
                    counting: count)
                {
                case .joined(let joined):
                    if blocksOnly {
                        // Joining removes list and quote prefixes. Restore their widths when reporting a match.
                        let pieces = joined.text.components(separatedBy: "\n")
                        var piece = 0
                        var start = 0
                        let lengths = pieces.map { $0.utf16.count }
                        let prefixes = zip(lines[index..<end], lengths).map { $0.utf16.count - $1 }
                        _ = rewriteInline(joined.text, footnotes, nil, proof) { range in
                            while piece + 1 < lengths.count, range.location > start + lengths[piece] {
                                start += lengths[piece] + 1
                                piece += 1
                            }
                            let line = index + piece
                            let prefix = prefixes[piece]
                            proseFormula?(
                                line, NSRange(location: range.location - start + prefix, length: range.length))
                        }
                        for number in index..<end { output.append(lines[number], from: source.origins[number]) }
                        index = end
                        continue
                    }
                    let rewritten = rewriteInline(joined.text, footnotes, formulas, proof)
                    let pieces = rewritten.components(separatedBy: "\n")
                    let origins = source.origins[index..<end].reduce(into: Set<Int>()) { $0.formUnion($1) }
                    for (offset, piece) in pieces.enumerated() {
                        output.append((offset == 0 ? joined.firstPrefix : joined.continuation) + piece, from: origins)
                    }
                    index = end
                    continue
                case .notJoinable:
                    break
                }
            }
            if protection.spans[index] == nil {
                switch displayBlock(lines, at: index, protection: protection, searched: &searched) {
                case .block(let block):
                    // An HTML block ends only at a blank line, so one follows to keep the next lines out of it.
                    let origins = source.origins[index..<block.end].reduce(into: Set<Int>()) { $0.formUnion($1) }
                    output.append(
                        block.prefix
                            + (blocksOnly
                                ? "<div class=\"math-block\"></div>"
                                : formulas.block(block.latex, source: block.source)),
                        from: origins)
                    output.append(block.blankLine, from: [])
                    index = block.end
                    continue
                case .none:
                    break
                }
            }
            index += 1
            if blocksOnly, footnotes.definitions.isEmpty || !line.utf8.contains(0x5E),
                !line.utf8.contains(0x24), !line.utf8.contains(0x5C)
            {
                output.append(line, from: source.origins[index - 1])
                continue
            }
            // Use the converter's protected spans and recursive inline scanner to discover references, even in
            // headings or quotes the prose reader skips. Its parser still needs the original source columns.
            let inlineFormulas = blocksOnly ? nil : formulas
            func rewrite(_ chunk: String, from column: Int) -> String {
                rewriteInline(
                    chunk, footnotes, inlineFormulas, proof, base: column,
                    foundFormula: proseFormula.map { record in
                        { record(index - 1, $0) }
                    })
            }
            guard let spans = protection.spans[index - 1] else {
                let rewritten = rewrite(line, from: 0)
                output.append(blocksOnly ? line : rewritten, from: source.origins[index - 1])
                continue
            }
            let bytes = Array(line.utf8)
            // The spans are cmark's byte columns. They were past the end of a line whose NUL characters cmark had
            // widened to U+FFFD, and the out-of-range slice ended the app; clamped, a stray column cannot.
            func text(_ range: Range<Int>) -> String {
                let lower = min(range.lowerBound, bytes.count)
                return String(decoding: bytes[lower..<min(max(range.upperBound, lower), bytes.count)], as: UTF8.self)
            }
            var rewritten = ""
            var cursor = 0
            var column = 0
            for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) where span.lowerBound >= cursor {
                let before = text(cursor..<span.lowerBound)
                let protected = text(span)
                rewritten += rewrite(before, from: column) + protected
                column += before.utf16.count + protected.utf16.count
                cursor = span.upperBound
            }
            // A span can end past the line (a code span that goes on to the next line), and the rest is then empty.
            rewritten += rewrite(text(min(cursor, bytes.count)..<bytes.count), from: column)
            output.append(blocksOnly ? line : rewritten, from: source.origins[index - 1])
        }
        return output
    }

    private static let searchesEveryLineKey = "app.surimono.searchesEveryParagraphLine"

    /// Runs `body` with the paragraph memos off on this thread, so that each line with a brace searches the rest of
    /// its paragraph again (tests compare the two).
    static func searchingEveryLine<Value>(_ body: () -> Value) -> Value {
        let dictionary = Thread.current.threadDictionary
        dictionary[searchesEveryLineKey] = true
        defer { dictionary[searchesEveryLineKey] = nil }
        return body()
    }

    private static let countsScannedLinesKey = "app.surimono.countsScannedParagraphLines"

    private final class LineCount {
        var value = 0
    }

    /// Runs `body` and returns how many paragraph lines the joining searches on this thread put together or went
    /// through, so that tests can bound the work without timing it.
    static func countingScannedLines(_ body: () -> Void) -> Int {
        let dictionary = Thread.current.threadDictionary
        let count = LineCount()
        dictionary[countsScannedLinesKey] = count
        defer { dictionary[countsScannedLinesKey] = nil }
        body()
        return count.value
    }

    private struct JoinedParagraph {
        let text: String
        let firstPrefix: String
        let continuation: String
    }

    private enum JoinAttempt {
        case joined(JoinedParagraph)
        /// No revision mark crosses a line, or the lines cannot be joined at all.
        case notJoinable
    }

    /// The searches of a paragraph that did not join, from `start` and from later lines of it, over one joined text.
    ///
    /// Searched again from a later line that no match of the latest search continued onto, with the same nesting
    /// and the same text for that line, the joined text is the end of this one, the search goes as it did from that
    /// line on, and so it does not join either. From a line that a match continued onto, the search reads the same
    /// text from that line's offset; the expression sees the line break before it, which no look-behind of it rules
    /// out and after which no mark closes, as at the start of a text of its own. Each step depends only on where the expression matched, so
    /// once the search matches where an earlier one did, it goes on as that one did, which did not join. Searching
    /// the whole rest again from each such line took quadratic time on a paragraph of links whose titles start on
    /// the next line.
    private final class ParagraphScan {
        /// Where the expression matched, the match made there when it is not empty, and where it matched next.
        struct Step {
            let match: NSRange?
            var next: Int?
        }

        let start: Int
        let parts: [String]
        let text: String
        private let nsText: NSString
        private let lineStarts: [Int]
        private var scanner: InlineScanner
        /// The steps of every search so far, by where the expression matched. A step's next one is the same in every
        /// search that comes to it.
        private var steps: [Int: Step] = [:]
        /// The next step of the latest search not yet walked by `continues(onto:)`, and the last match walked.
        private var walked: Int?
        private var lastWalked: NSRange?

        init(start: Int, parts: [String]) {
            self.start = start
            self.parts = parts
            text = parts.joined(separator: "\n")
            nsText = text as NSString
            var offsets: [Int] = []
            var offset = 0
            for part in parts {
                offsets.append(offset)
                offset += (part as NSString).length + 1
            }
            lineStarts = offsets
            scanner = InlineScanner(nsText)
        }

        func offset(ofLine line: Int) -> Int { lineStarts[line - start] }

        func text(fromLine line: Int) -> String { nsText.substring(from: offset(ofLine: line)) }

        private func line(of position: Int) -> Int {
            var low = 0
            var high = lineStarts.count
            while low + 1 < high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= position { low = middle } else { high = middle }
            }
            return low
        }

        /// Searches from `line`, which becomes the latest search, and tells whether a revision mark crosses a line.
        func search(from line: Int, counting count: LineCount?) -> Bool {
            let length = nsText.length
            var cursor = offset(ofLine: line)
            var previous: Int?
            var head: Int?
            func link(to position: Int) {
                if let previous { steps[previous]?.next = position } else { head = position }
            }
            defer {
                walked = head
                lastWalked = nil
            }
            while cursor < length {
                if PreviewConversion.expired { return false }
                guard let step = nextInline(in: nsText, from: cursor, scanner: &scanner) else {
                    count?.value += self.line(of: length - 1) - self.line(of: cursor) + 1
                    break
                }
                count?.value += self.line(of: max(step.cursor, cursor + 1) - 1) - self.line(of: cursor) + 1
                if steps[step.position] != nil {
                    link(to: step.position)
                    break
                }
                if let match = step.match {
                    let crosses = [
                        "criticAdd", "criticDelete", "criticOld", "criticNew", "criticMark", "criticComment",
                    ]
                    .contains { match.groups[$0].map { nsText.substring(with: $0).contains("\n") } == true }
                    if crosses { return true }
                }
                steps[step.position] = Step(match: step.match.flatMap { $0.range.length > 0 ? $0.range : nil })
                link(to: step.position)
                previous = step.position
                cursor = step.cursor
            }
            return false
        }

        /// Whether a match of the latest search continued onto `line`. Asked for later and later lines, so each
        /// step is walked once per search.
        func continues(onto line: Int) -> Bool {
            let lineStart = offset(ofLine: line)
            while let position = walked, position < lineStart, let step = steps[position] {
                if let match = step.match { lastWalked = match }
                walked = step.next
            }
            guard let match = lastWalked else { return false }
            return match.location + match.length - 1 >= lineStart
        }
    }

    /// Only join soft lines of one AST paragraph. Container markers are structural, not revision text.
    private static func multilineProof(
        _ lines: [String], start: Int, end: Int, nextProtected: [Int], unjoinable: inout [[Container]: Int],
        scanned: inout [[Container]: ParagraphScan], counting count: LineCount?
    ) -> JoinAttempt {
        guard nextProtected[start] >= end else { return .notJoinable }
        let first = lines[start]
        let prefixEnd =
            containerPrefix?.firstMatch(in: first, range: NSRange(first.startIndex..., in: first))
            .flatMap { Range($0.range, in: first)?.upperBound } ?? first.startIndex
        let prefix = String(first[..<prefixEnd])
        let nesting = containers(of: prefix)
        if let line = unjoinable[nesting], line > start { return .notJoinable }
        let own = String(first[prefixEnd...])
        if let earlier = scanned[nesting], start > earlier.start, start - earlier.start < earlier.parts.count,
            earlier.parts[start - earlier.start] == own
        {
            guard earlier.continues(onto: start) else { return .notJoinable }
            guard earlier.search(from: start, counting: count) else { return .notJoinable }
            // The first search of the paragraph already read the lines after this one in this nesting.
            let body = content(of: lines[start + 1], in: nesting) ?? ""
            return .joined(
                JoinedParagraph(
                    text: earlier.text(fromLine: start), firstPrefix: prefix,
                    continuation: String(lines[start + 1].dropLast(body.count))))
        }
        var parts = [own]
        var continuation = ""
        for index in (start + 1)..<end {
            guard let body = content(of: lines[index], in: nesting) else {
                unjoinable[nesting] = index
                return .notJoinable
            }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            // Display math still goes through its dedicated block reader.
            guard !trimmed.hasPrefix("$$"), !trimmed.hasPrefix("\\[") else {
                unjoinable[nesting] = index
                return .notJoinable
            }
            if index == start + 1 { continuation = String(lines[index].dropLast(body.count)) }
            parts.append(String(body))
        }
        count?.value += parts.count
        let scan = ParagraphScan(start: start, parts: parts)
        if scan.search(from: start, counting: count) {
            return .joined(JoinedParagraph(text: scan.text, firstPrefix: prefix, continuation: continuation))
        }
        scanned[nesting] = scan
        return .notJoinable
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
        var source = [String(line[prefixEnd...].drop(while: { $0.isWhitespace }))]
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
            if text.hasSuffix(closer) {
                source.append(String(inside.prefix { $0.isWhitespace }) + text)
                latex.append(String(text.dropLast(closer.count)))
                return .block(
                    DisplayBlock(
                        prefix: prefix, latex: latex.joined(separator: "\n"), source: source.joined(separator: "\n"),
                        blankLine: blankLine, end: cursor + 1))
            }
            source.append(String(inside))
            latex.append(text)
            cursor += 1
        }
        return unclosed()
    }

    /// A block quote, or a list item (or plain indentation) whose content starts `width` columns in.
    private enum Container: Hashable {
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
        //
        // The constructs whose contents run to a distant closer (`\(…\)`, `\[…\]`, `==…==` and the CriticMarkup
        // marks) are matched only by their opening here; `InlineScanner` finds the closer from positions indexed once
        // per text. Matched by the expression, each opening without a closer searched the rest of its line or
        // paragraph: 11,000 `\(` on one line took seconds.
        let math = [
            #"\$\$(?<displayMath>[^$\n]+?)\$\$"#,
            #"(?<displayMath2Open>\\\[)"#,
            #"(?<inlineMath2Open>\\\()"#,
            #"(?<!\$)\$(?<inlineMath>(?=[^\s$])(?:\\.|[^$\\\n])*?(?<=[^\s]))\$(?![0-9$])"#,
        ].joined(separator: "|")
        let verbatim = [
            #"\\[\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E]"#,  // a backslash escape
            #"(?<codeOpen>(?<!`)`+)"#,  // a code span's opening; `InlineScanner.codeSpanEnd` finds its end
            #"<[A-Za-z/!?][^<>\n]*>"#,  // a tag or an autolink
            #"\]\((?:[^()\s]|\([^()\s]*\))*(?:\s+(?:"[^"]*"|'[^']*'))?\)"#,  // a link destination
            #"(?:https?://|www\.)[^\s<]+"#,  // a bare URL
        ].joined(separator: "|")
        let syntax = [
            #"(?<criticAddOpen>\{\+\+)"#,
            #"(?<criticDeleteOpen>\{--)"#,
            #"(?<criticSubstituteOpen>\{~~)"#,
            #"(?<criticMarkOpen>\{==)"#,
            #"(?<criticCommentOpen>\{>>)"#,
            #"(?<criticUnclosed>\{(?:\+\+|--|~~|==|>>))"#,
            #"\[\^(?<footnote>[^\]\s]+)\]"#,
            #"\{(?<rubyBase>[^{}|\n]+)\|(?<rubyText>[^{}\n]+)\}"#,
            #"(?<markOpen>(?<![=\\])==(?=[^\s=]))"#,
            #"(?<![\\^])\^(?=[^\s^])(?<sup>[^\s^]+?)\^(?!\^)"#,
            #"(?<![~\\])~(?=[^\s~])(?<sub>[^\s~]+?)~(?!~)"#,
        ].joined(separator: "|")
        return try? NSRegularExpression(pattern: "\(math)|(?<verbatim>\(verbatim))|\(syntax)")
    }()

    /// One match of the inline syntax: its range and those of its named groups, in UTF-16 offsets.
    struct InlineMatch {
        var range: NSRange
        var groups: [String: NSRange]
    }

    private static let groupNames = [
        "displayMath", "displayMath2Open", "inlineMath2Open", "inlineMath", "verbatim", "criticAddOpen",
        "criticDeleteOpen", "criticSubstituteOpen", "criticMarkOpen", "criticCommentOpen", "criticUnclosed", "footnote",
        "rubyBase", "rubyText", "markOpen", "sup", "sub", "codeOpen",
    ]

    /// The matches of the inline syntax in `text`, left to right, as the full expression with lazy contents matched
    /// them. Each closer is found by a binary search in positions indexed once per text, so a text of n characters
    /// takes O(n log n) time.
    static func inlineMatches(_ text: NSString) -> [InlineMatch] {
        var scanner = InlineScanner(text)
        var matches: [InlineMatch] = []
        var cursor = 0
        while cursor < text.length, let step = nextInline(in: text, from: cursor, scanner: &scanner) {
            if let match = step.match { matches.append(match) }
            cursor = step.cursor
        }
        return matches
    }

    /// One step of `inlineMatches`: where the expression matched next, the match made there (none for an opening
    /// that the expression would have passed over), and where the search goes on.
    private struct InlineStep {
        let position: Int
        let match: InlineMatch?
        let cursor: Int
    }

    /// The next step from `cursor`. With transparent bounds the expression sees the text before `cursor`, so a step
    /// depends on where the expression matched and not on where the search started.
    private static func nextInline(in text: NSString, from cursor: Int, scanner: inout InlineScanner) -> InlineStep? {
        guard let regex = inlinePattern else { return nil }
        let length = text.length
        let options: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        guard
            let match = regex.firstMatch(
                in: text as String, options: options, range: NSRange(location: cursor, length: length - cursor))
        else { return nil }
        var groups: [String: NSRange] = [:]
        for name in groupNames {
            let range = match.range(withName: name)
            if range.location != NSNotFound { groups[name] = range }
        }
        let start = match.range.location
        if groups["displayMath2Open"] != nil || groups["inlineMath2Open"] != nil {
            let display = groups["displayMath2Open"] != nil
            if let close = scanner.lineCloser(display ? "\\]" : "\\)", from: start + 3, lineFrom: start + 2) {
                let found = InlineMatch(
                    range: NSRange(location: start, length: close + 2 - start),
                    groups: [
                        display ? "displayMath2" : "inlineMath2": NSRange(
                            location: start + 2, length: close - start - 2)
                    ])
                return InlineStep(position: start, match: found, cursor: close + 2)
            }
            // Without a closer the expression went on to the backslash escape.
            let escape = InlineMatch(range: NSRange(location: start, length: 2), groups: ["verbatim": match.range])
            return InlineStep(position: start, match: escape, cursor: start + 2)
        }
        if let kind = ["criticAdd", "criticDelete", "criticMark", "criticComment"].first(where: {
            groups[$0 + "Open"] != nil
        }) {
            let closer = ["criticAdd": "++}", "criticDelete": "--}", "criticMark": "==}", "criticComment": "<<}"]
            if let name = closer[kind], let close = scanner.closer(name, from: start + 3) {
                let found = InlineMatch(
                    range: NSRange(location: start, length: close + 3 - start),
                    groups: [kind: NSRange(location: start + 3, length: close - start - 3)])
                return InlineStep(position: start, match: found, cursor: close + 3)
            }
            let unclosed = InlineMatch(range: match.range, groups: ["criticUnclosed": match.range])
            return InlineStep(position: start, match: unclosed, cursor: start + 3)
        }
        if groups["criticSubstituteOpen"] != nil {
            if let arrow = scanner.closer("~>", from: start + 3), let close = scanner.closer("~~}", from: arrow + 2) {
                let found = InlineMatch(
                    range: NSRange(location: start, length: close + 3 - start),
                    groups: [
                        "criticOld": NSRange(location: start + 3, length: arrow - start - 3),
                        "criticNew": NSRange(location: arrow + 2, length: close - arrow - 2),
                    ])
                return InlineStep(position: start, match: found, cursor: close + 3)
            }
            let unclosed = InlineMatch(range: match.range, groups: ["criticUnclosed": match.range])
            return InlineStep(position: start, match: unclosed, cursor: start + 3)
        }
        if let opening = groups["codeOpen"] {
            // `(?<!`)(?<ticks>`+)(?:.*?[^`])?\k<ticks>(?!`)`, whose backtracking over each shorter opening took
            // seconds on one run of 17,000 backticks.
            if let end = scanner.codeSpanEnd(at: start, length: opening.length) {
                let range = NSRange(location: start, length: end - start)
                return InlineStep(
                    position: start, match: InlineMatch(range: range, groups: ["verbatim": range]), cursor: end)
            }
            // No other alternative starts with a backtick, and none of this run's later backticks opens one.
            return InlineStep(position: start, match: nil, cursor: start + opening.length)
        }
        if groups["markOpen"] != nil {
            if let close = scanner.markCloser(from: start + 3, lineFrom: start + 2) {
                let found = InlineMatch(
                    range: NSRange(location: start, length: close + 2 - start),
                    groups: ["mark": NSRange(location: start + 2, length: close - start - 2)])
                return InlineStep(position: start, match: found, cursor: close + 2)
            }
            // No other alternative starts with `=`: the expression moved on to the next character.
            return InlineStep(position: start, match: nil, cursor: start + 1)
        }
        return InlineStep(
            position: start, match: InlineMatch(range: match.range, groups: groups),
            cursor: max(match.range.location + match.range.length, start + 1))
    }

    /// A tag alone on the first line of a paragraph would open an HTML block, and the Markdown inside would print as
    /// written. White space with a line break at an edge of the marked text therefore goes outside the element, up
    /// to and with the break: the words around it stay apart, and two spaces before the break remain a hard break.
    /// What follows the break is dropped, since four spaces at the start of a paragraph would make it code. Spaces
    /// on the same line stay inside.
    private static func criticElement(_ name: String, _ body: String) -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return body }
        func edge(_ space: String) -> (outside: String, inside: String) {
            guard let line = space.firstIndex(where: \.isNewline) else { return ("", space) }
            return (String(space[...line]), "")
        }
        let leading = edge(String(body.prefix { $0.isWhitespace }))
        // After the element the indent stays: without it a `#` that follows would become a heading.
        let tail = String(body.reversed().prefix { $0.isWhitespace }.reversed())
        let trailing = tail.contains(where: \.isNewline) ? (outside: tail, inside: "") : (outside: "", inside: tail)
        return leading.outside + "<\(name) class=\"critic\">" + leading.inside + text + trailing.inside
            + "</\(name)>" + trailing.outside
    }

    private static func rewriteInline(
        _ text: String, _ footnotes: Footnotes, _ formulas: Formulas?, _ proof: ProofMarks,
        base: Int = 0, foundFormula: ((NSRange) -> Void)? = nil
    )
        -> String
    {
        guard text.contains(where: { "[{=^~$\\".contains($0) }) else { return text }
        let nsText = text as NSString
        var output = ""
        var cursor = 0
        for match in inlineMatches(nsText) {
            output += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let whole = nsText.substring(with: match.range)
            func capture(_ name: String) -> String? {
                match.groups[name].map { nsText.substring(with: $0) }
            }
            func nested(_ content: String, _ group: String) -> String {
                rewriteInline(
                    content, footnotes, formulas, proof, base: base + (match.groups[group]?.location ?? 0),
                    foundFormula: foundFormula)
            }
            let display = capture("displayMath") ?? capture("displayMath2")
            if let latex = display ?? capture("inlineMath") ?? capture("inlineMath2") {
                foundFormula?(NSRange(location: base + match.range.location, length: match.range.length))
                output += formulas?.token(latex, display: display != nil, source: whole) ?? whole
            } else if capture("verbatim") != nil {
                if whole == #"\@"#, let formulas, formulas.citations != nil {
                    output += formulas.escapedCitationSign
                } else {
                    output += whole
                }
            } else if capture("criticUnclosed") != nil {
                output += whole.unicodeScalars.map { "&#\($0.value);" }.joined()
            } else if let comment = capture("criticComment") {
                if proof == .shown {
                    // Numeric entities keep Markdown punctuation inert while retaining literal comment text.
                    let escaped = comment.unicodeScalars.map { "&#\($0.value);" }.joined()
                    output += "<span class=\"critic-comment\">" + escaped + "</span>"
                }
            } else if let added = capture("criticAdd") {
                if proof != .original {
                    let body = nested(added, "criticAdd")
                    output += proof == .shown ? criticElement("ins", body) : body
                }
            } else if let deleted = capture("criticDelete") {
                if proof != .accepted {
                    let body = nested(deleted, "criticDelete")
                    output += proof == .shown ? criticElement("del", body) : body
                }
            } else if let old = capture("criticOld"), let new = capture("criticNew") {
                if proof != .accepted {
                    let body = nested(old, "criticOld")
                    output += proof == .shown ? criticElement("del", body) : body
                }
                if proof != .original {
                    let body = nested(new, "criticNew")
                    output += proof == .shown ? criticElement("ins", body) : body
                }
            } else if let marked = capture("criticMark") {
                let body = nested(marked, "criticMark")
                output += proof == .shown ? criticElement("mark", body) : body
            } else if let label = capture("footnote") {
                output += footnotes.reference(to: label) ?? whole
            } else if let base = capture("rubyBase"), let reading = capture("rubyText") {
                output += ruby(base: base, reading: reading)
            } else if let content = capture("mark") {
                output += "<mark>" + nested(content, "mark") + "</mark>"
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
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json"),
            let data = try? Data(contentsOf: url),
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
            var insideComment = false
            return node.children.map { child -> String in
                if let html = child as? InlineHTML {
                    if html.rawHTML.hasPrefix("<sup class=\"footnote-ref\"") { insideReference = true }
                    if html.rawHTML == "</sup>" { insideReference = false }
                    if html.rawHTML == "<span class=\"critic-comment\">" { insideComment = true }
                    if html.rawHTML == "</span>" { insideComment = false }
                    return ""
                }
                return insideReference || insideComment ? "" : plainText(child, formulas: formulas)
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

    /// `fn-` or `fnref-` and then only digits and hyphens: every id the footnotes use, and every suffix of one.
    static func isNoteID(_ id: String) -> Bool {
        guard let prefix = ["fnref-", "fn-"].first(where: id.hasPrefix) else { return false }
        let rest = id.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// Reserve each final ID, including IDs that already look like a generated suffix.
    static func headingID(_ requested: String, used: inout [String: Int], hasFootnotes: Bool = false) -> String {
        let base = requested.isEmpty ? "section" : requested
        func headingName(_ candidate: String) -> String {
            hasFootnotes && isNoteID(candidate) ? "section-" + candidate : candidate
        }
        var suffix = used[base] ?? 0
        var id = headingName(base)
        while used[id] != nil {
            suffix += 1
            id = headingName("\(base)-\(suffix)")
        }
        used[base] = suffix
        used[id] = 0
        return id
    }

    /// Every heading's anchor in document order; a repeated id gets `-1`, `-2`… as on GitHub.
    static func headingAnchors(in document: any Markup, formulas: Formulas?, hasFootnotes: Bool) -> [HeadingAnchor] {
        var anchors: [HeadingAnchor] = []
        var used: [String: Int] = [:]
        func visit(_ node: any Markup) {
            if PreviewConversion.expired { return }
            if let heading = node as? Heading {
                let (text, custom) = splitCustomID(plainText(heading, formulas: formulas))
                let id = headingID(custom ?? slug(text), used: &used, hasFootnotes: hasFootnotes)
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
    /// heading (usually the title) has the highest level.
    static func tableOfContents(_ anchors: [HeadingAnchor], levels: Int = 3) -> String {
        guard let highest = anchors.map(\.level).min() else { return "" }
        let top =
            anchors.filter { $0.level == highest }.count == 1 && anchors.contains(where: { $0.level > highest })
            ? anchors.filter { $0.level > highest }.map(\.level).min() ?? highest : highest
        let entries = anchors.filter { $0.level >= top && $0.level - top < levels }
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

/// Where the closers of the long inline constructs are, indexed in one pass over the text so that each opening finds
/// its closer by binary search instead of searching the rest of the text.
private struct InlineScanner {
    private let text: NSString
    private var positions: [String: [Int]]?
    private var terminators: [Int] = []
    private var markClosers: [Int] = []
    private var codeSpanEnds: [Int: Int?]?

    init(_ text: NSString) { self.text = text }

    /// The line terminators of ICU's `.`, which the contents of `\(…\)`, `\[…\]` and `==…==` do not cross.
    private static func isTerminator(_ unit: unichar) -> Bool {
        (0x0A...0x0D).contains(unit) || unit == 0x85 || unit == 0x2028 || unit == 0x2029
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace
    }

    private mutating func index() -> [String: [Int]] {
        if let positions { return positions }
        let tokens = ["\\)", "\\]", "++}", "--}", "==}", "<<}", "~>", "~~}"]
        var found: [String: [Int]] = Dictionary(uniqueKeysWithValues: tokens.map { ($0, []) })
        let length = text.length
        var units = [unichar](repeating: 0, count: length)
        text.getCharacters(&units, range: NSRange(location: 0, length: length))
        func at(_ offset: Int) -> unichar { offset < length ? units[offset] : 0 }
        for offset in 0..<length {
            let unit = units[offset]
            if Self.isTerminator(unit) { terminators.append(offset) }
            switch unit {
            case 0x5C:  // \
                if at(offset + 1) == 0x29 { found["\\)", default: []].append(offset) }
                if at(offset + 1) == 0x5D { found["\\]", default: []].append(offset) }
            case 0x2B where at(offset + 1) == 0x2B && at(offset + 2) == 0x7D: found["++}", default: []].append(offset)
            case 0x2D where at(offset + 1) == 0x2D && at(offset + 2) == 0x7D: found["--}", default: []].append(offset)
            case 0x3C where at(offset + 1) == 0x3C && at(offset + 2) == 0x7D: found["<<}", default: []].append(offset)
            case 0x7E:  // ~
                if at(offset + 1) == 0x3E { found["~>", default: []].append(offset) }
                if at(offset + 1) == 0x7E && at(offset + 2) == 0x7D { found["~~}", default: []].append(offset) }
            case 0x3D where at(offset + 1) == 0x3D:  // ==
                if at(offset + 2) == 0x7D { found["==}", default: []].append(offset) }
                // `(?<=[^\s\\])==(?!=)`: the closing `==` of a mark.
                if offset > 0, !Self.isWhitespace(units[offset - 1]), units[offset - 1] != 0x5C,
                    at(offset + 2) != 0x3D
                {
                    markClosers.append(offset)
                }
            default: break
            }
        }
        positions = found
        return found
    }

    private static func first(in sorted: [Int], from offset: Int) -> Int? {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < offset { low = middle + 1 } else { high = middle }
        }
        return low < sorted.count ? sorted[low] : nil
    }

    /// Where a code span opened by the backtick run of `length` at `start` ends, as
    /// `(?<!`)(?<ticks>`+)(?:.*?[^`])?\k<ticks>(?!`)` ends it: the longest opening (at most `length`) that has a
    /// closing run of exactly its length, after content that does not cross a line terminator except as its last
    /// character, and for that opening the earliest closing; an opening of half an even run closes inside the run
    /// itself, after the content-bearing closings of the same length.
    mutating func codeSpanEnd(at start: Int, length: Int) -> Int? {
        if codeSpanEnds == nil { codeSpanEnds = Self.codeSpanEnds(in: text) }
        guard let answer = codeSpanEnds?[start] else { return nil }
        return answer
    }

    /// For each backtick run's start, where the code span it opens ends, or nil when it opens none. One pass from
    /// the end of each line: the runs that may close one (later on its line, or the first on the next line when it
    /// starts right after the line's terminator) are kept as the earliest run of each length.
    private static func codeSpanEnds(in text: NSString) -> [Int: Int?] {
        let length = text.length
        var units = [unichar](repeating: 0, count: length)
        text.getCharacters(&units, range: NSRange(location: 0, length: length))
        var runs: [(start: Int, length: Int, line: Int)] = []
        var terminatorAfterLine: [Int] = []
        var line = 0
        var offset = 0
        while offset < length {
            if units[offset] == 0x60 {
                var end = offset
                while end < length, units[end] == 0x60 { end += 1 }
                runs.append((offset, end - offset, line))
                offset = end
                continue
            }
            if isTerminator(units[offset]) {
                terminatorAfterLine.append(offset)
                line += 1
            }
            offset += 1
        }
        var answers: [Int: Int?] = [:]
        var earliest: [Int: Int] = [:]
        var lengths: [Int] = []
        var currentLine = -1
        func insert(_ index: Int) {
            let run = runs[index]
            if earliest[run.length] == nil {
                var low = 0
                var high = lengths.count
                while low < high {
                    let middle = (low + high) / 2
                    if lengths[middle] < run.length { low = middle + 1 } else { high = middle }
                }
                lengths.insert(run.length, at: low)
            }
            earliest[run.length] = index
        }
        for index in stride(from: runs.count - 1, through: 0, by: -1) {
            let run = runs[index]
            if run.line != currentLine {
                currentLine = run.line
                earliest = [:]
                lengths = []
                // The first run of the next line closes this line's spans when it starts right after the terminator.
                if run.line < terminatorAfterLine.count, index + 1 < runs.count {
                    let next = runs[index + 1]
                    if next.line == run.line + 1, next.start == terminatorAfterLine[run.line] + 1 { insert(index + 1) }
                }
            }
            // The longest closing length the opening can shorten to.
            var low = 0
            var high = lengths.count
            while low < high {
                let middle = (low + high) / 2
                if lengths[middle] <= run.length { low = middle + 1 } else { high = middle }
            }
            let closing = low > 0 ? lengths[low - 1] : nil
            let inside = run.length % 2 == 0 ? run.length / 2 : nil
            if let closing, let close = earliest[closing], closing >= inside ?? 0 {
                answers[run.start] = .some(runs[close].start + closing)
            } else if inside != nil {
                answers[run.start] = .some(run.start + run.length)
            } else {
                answers[run.start] = .some(nil)
            }
            insert(index)
        }
        return answers
    }

    /// The first `token` at or after `offset`.
    mutating func closer(_ token: String, from offset: Int) -> Int? {
        Self.first(in: index()[token] ?? [], from: offset)
    }

    /// The first `token` at or after `offset` with no line terminator between `lineFrom` and it.
    mutating func lineCloser(_ token: String, from offset: Int, lineFrom: Int) -> Int? {
        guard let close = closer(token, from: offset) else { return nil }
        if let end = Self.first(in: terminators, from: lineFrom), end < close { return nil }
        return close
    }

    /// The first closing `==` of a mark at or after `offset`, on the line that starts at `lineFrom`.
    mutating func markCloser(from offset: Int, lineFrom: Int) -> Int? {
        _ = index()
        guard let close = Self.first(in: markClosers, from: offset) else { return nil }
        if let end = Self.first(in: terminators, from: lineFrom), end < close { return nil }
        return close
    }
}

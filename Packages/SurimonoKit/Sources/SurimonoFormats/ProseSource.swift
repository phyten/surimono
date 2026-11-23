import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// One paragraph of a document's running text, as a reader sees it, with the way back to the source.
///
/// `text` is the paragraph without its markup: emphasis marks, link targets and the like are left out, and what is
/// shown but is not prose (inline code, a formula, a bare URL) is one U+FFFC each, so the words on either side of it
/// do not read as neighbours. Every offset is in UTF-16 code units, the unit of `NSRange` and of PDFKit's strings.
public struct ProseParagraph: Equatable, Sendable {
    /// What stands in `text` for inline code, a formula or a URL.
    public static let placeholder: Character = "\u{FFFC}"

    /// The paragraph's place among the document's prose paragraphs, from 0.
    public let index: Int
    /// The one-based source lines the paragraph is written on, numbered as `MarkdownBlock.lines` numbers them (front
    /// matter included), so a paragraph can be matched to the block the converter made of it.
    public let lines: ClosedRange<Int>
    /// The paragraph in the source, from its first character to its last.
    public let sourceRange: Range<Int>
    public let text: String

    /// A stretch of `text` and where it came from. A copied stretch has the same length on both sides; a
    /// placeholder is one unit of `text` for `sourceLength` units of the source.
    struct Run: Equatable, Sendable {
        var text: Int
        var source: Int
        var length: Int
        var sourceLength: Int
    }

    let runs: [Run]

    /// The part of the source that a range of `text` was read from. The answer runs from the first character of the
    /// range to its last, and so takes in any markup between them; an empty range gives an empty one.
    public func sourceRange(of range: Range<Int>) -> Range<Int> {
        guard let first = run(holding: range.lowerBound) else { return sourceRange.upperBound..<sourceRange.upperBound }
        let lower = first.length == first.sourceLength ? first.source + range.lowerBound - first.text : first.source
        guard !range.isEmpty, let last = run(holding: range.upperBound - 1) else { return lower..<lower }
        let upper =
            last.length == last.sourceLength
            ? last.source + range.upperBound - last.text : last.source + last.sourceLength
        return lower..<max(lower, upper)
    }

    private func run(holding offset: Int) -> Run? {
        var low = 0
        var high = runs.count
        while low < high {
            let middle = (low + high) / 2
            if runs[middle].text + runs[middle].length <= offset { low = middle + 1 } else { high = middle }
        }
        return low < runs.count && runs[low].text <= offset ? runs[low] : nil
    }
}

/// The running text of a document, paragraph by paragraph, for the analysis of its writing. Nothing here judges the
/// text; it only says what is prose and where it stands in the source.
public struct ProseSource: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case markdown
        /// Plain text has no soft line breaks of its own: a line is as the writer broke it.
        case plainText
    }

    public let kind: Kind
    public let paragraphs: [ProseParagraph]

    /// The prose of a document of `format`, or nil for a format whose prose is not read yet.
    public init?(text: String, format: DocumentFormat) {
        switch format {
        case .markdown: self = Self.markdown(text)
        case .plainText: self = Self.plainText(text)
        default: return nil
        }
    }

    init(kind: Kind, paragraphs: [ProseParagraph]) {
        self.kind = kind
        self.paragraphs = paragraphs
    }

    /// The paragraphs of a Markdown text. Offsets are into `text` as given (its line endings are not rewritten).
    ///
    /// Left out: front matter, headings, code blocks, HTML blocks, tables, block quotes (callouts with them), the
    /// lines of `:::` containers, list and task markers, and within a paragraph inline code, formulas, URLs, link
    /// targets, tags, footnote marks and the reading of a ruby.
    public static func markdown(_ text: String) -> ProseSource {
        let source = SourceLines(text)
        var lines = source.lines
        if let end = MarkdownConverter.frontMatterEnd(in: lines) {
            for index in 0...end { lines[index] = "" }
        }
        // A container line ends the paragraph before it, as it does for the converter; blank, it does the same here
        // and is not read as words.
        for index in lines.indices where lines[index].drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(":::") {
            lines[index] = ""
        }
        var builder = Builder(source: source)
        for block in paragraphBlocks(lines) {
            guard block.firstLine >= 1, block.lastLine >= block.firstLine, block.lastLine <= lines.count else {
                continue
            }
            let line = block.firstLine - 1
            let start =
                source.ranges[line].lowerBound
                + min(utf16Length(ofBytes: block.firstColumn - 1, in: lines[line]), source.ranges[line].count)
            builder.addMarkdown(
                start..<source.ranges[block.lastLine - 1].upperBound, lines: block.firstLine...block.lastLine)
        }
        return ProseSource(kind: .markdown, paragraphs: builder.paragraphs)
    }

    /// The paragraphs of a plain text: runs of lines between blank lines. Only URLs are left out.
    public static func plainText(_ text: String) -> ProseSource {
        let source = SourceLines(text)
        var builder = Builder(source: source)
        var first: Int?
        func isBlank(_ index: Int) -> Bool {
            source.units[source.ranges[index]].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x3000 }
        }
        for index in 0...source.ranges.count {
            if index < source.ranges.count, !isBlank(index) {
                first = first ?? index
            } else if let start = first {
                builder.addPlain(
                    source.ranges[start].lowerBound..<source.ranges[index - 1].upperBound, lines: (start + 1)...index)
                first = nil
            }
        }
        return ProseSource(kind: .plainText, paragraphs: builder.paragraphs)
    }

    // MARK: - Reading

    /// The text as UTF-16 and as lines. cmark ends a line at LF, CR LF or a lone CR, and so does this.
    private struct SourceLines {
        let units: [UInt16]
        var ranges: [Range<Int>] = []
        var lines: [String] = []

        init(_ text: String) {
            units = Array(text.utf16)
            var start = 0
            var index = 0
            while index < units.count {
                let unit = units[index]
                if unit == 0x0A || unit == 0x0D {
                    ranges.append(start..<index)
                    if unit == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
                    start = index + 1
                }
                index += 1
            }
            ranges.append(start..<units.count)
            // cmark reads NUL as U+FFFD and counts its columns so; both are one UTF-16 unit, so offsets stay.
            lines = ranges.map {
                String(decoding: units[$0], as: UTF16.self).replacingOccurrences(of: "\0", with: "\u{FFFD}")
            }
        }
    }

    private struct Block {
        var firstLine: Int
        var firstColumn: Int
        var lastLine: Int
    }

    /// Where cmark finds the paragraphs that are running text: those of the document itself and of its lists. The
    /// tree is walked without recursion, and nothing below a paragraph is visited: cmark's positions for blocks are
    /// exact, while those of the inlines after a hard break are not.
    private static func paragraphBlocks(_ lines: [String]) -> [Block] {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            if let extensionPointer = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, extensionPointer)
            }
        }
        var bytes = Array(lines.joined(separator: "\n").utf8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress.map {
                cmark_parser_feed(parser, UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self), buffer.count)
            }
        }
        guard let root = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(root) }
        guard let iterator = cmark_iter_new(root) else { return [] }
        defer { cmark_iter_free(iterator) }
        var blocks: [Block] = []
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            guard event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else { continue }
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_DOCUMENT || type == CMARK_NODE_LIST || type == CMARK_NODE_ITEM { continue }
            if type == CMARK_NODE_PARAGRAPH {
                blocks.append(
                    Block(
                        firstLine: Int(cmark_node_get_start_line(node)),
                        firstColumn: max(1, Int(cmark_node_get_start_column(node))),
                        lastLine: Int(cmark_node_get_end_line(node))))
            }
            // Headings, code, HTML, tables, block quotes and everything inside them are not read.
            cmark_iter_reset(iterator, node, CMARK_EVENT_EXIT)
        }
        return blocks
    }

    /// The UTF-16 length of the first `bytes` UTF-8 bytes of `line` (cmark counts columns in bytes).
    private static func utf16Length(ofBytes bytes: Int, in line: String) -> Int {
        var seen = 0
        var length = 0
        for scalar in line.unicodeScalars {
            if seen >= bytes { break }
            seen += UTF8.width(scalar)
            length += UTF16.width(scalar)
        }
        return length
    }

    // MARK: - Paragraphs

    private struct Builder {
        let source: SourceLines
        var paragraphs: [ProseParagraph] = []

        private enum Mark: UInt8 {
            case kept, dropped, shown, shownStart
        }

        private static let url = try? NSRegularExpression(pattern: #"(?:https?://|www\.)[^\s<]+"#)
        private static let mathGroups = ["displayMath", "inlineMath", "displayMath2", "inlineMath2"]
        private static let innerGroups = [
            "criticAdd", "criticDelete", "criticMark", "criticOld", "criticNew", "mark", "sup", "sub", "rubyBase",
        ]

        mutating func addPlain(_ range: Range<Int>, lines: ClosedRange<Int>) {
            var marks = [Mark](repeating: .kept, count: range.count)
            let text = String(decoding: source.units[range], as: UTF16.self) as NSString
            for match in Self.url?.matches(in: text as String, range: NSRange(location: 0, length: text.length)) ?? [] {
                Self.show(match.range, in: &marks)
            }
            add(range, lines: lines, marks: marks)
        }

        mutating func addMarkdown(_ range: Range<Int>, lines: ClosedRange<Int>) {
            var range = range
            let units = source.units
            func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }
            while range.lowerBound < range.upperBound, isSpace(units[range.lowerBound]) {
                range = (range.lowerBound + 1)..<range.upperBound
            }
            // A task marker belongs to the list, whichever side of it cmark starts the paragraph on.
            if range.count >= 4, units[range.lowerBound] == 0x5B, units[range.lowerBound + 2] == 0x5D,
                [0x20, 0x78, 0x58].contains(units[range.lowerBound + 1]), isSpace(units[range.lowerBound + 3])
            {
                range = (range.lowerBound + 4)..<range.upperBound
            }
            let text = String(decoding: units[range], as: UTF16.self) as NSString
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "[TOC]" else { return }
            var marks = [Mark](repeating: .kept, count: range.count)
            Self.markSyntax(text, base: 0, depth: 0, in: &marks)
            Self.markDelimiters(Array(units[range]), in: &marks)
            add(range, lines: lines, marks: marks)
        }

        private static func show(_ range: NSRange, in marks: inout [Mark]) {
            guard range.length > 0, range.location >= 0, range.location + range.length <= marks.count else { return }
            for index in range.location..<(range.location + range.length) { marks[index] = .shown }
            marks[range.location] = .shownStart
        }

        private static func set(_ mark: Mark, _ range: NSRange, in marks: inout [Mark]) {
            guard range.length > 0, range.location >= 0, range.location + range.length <= marks.count else { return }
            for index in range.location..<(range.location + range.length) { marks[index] = mark }
        }

        /// Marks what the converter's own inline scanner finds, so that the analysis leaves out exactly what the
        /// converter does not treat as words. The contents of a mark or an edit are scanned again, a few levels deep.
        private static func markSyntax(_ text: NSString, base: Int, depth: Int, in marks: inout [Mark]) {
            for match in MarkdownExtensions.inlineMatches(text) {
                let range = NSRange(location: match.range.location + base, length: match.range.length)
                if mathGroups.contains(where: { match.groups[$0] != nil }) {
                    show(range, in: &marks)
                } else if match.groups["verbatim"] != nil {
                    switch text.character(at: match.range.location) {
                    case 0x5C: set(.dropped, NSRange(location: range.location, length: 1), in: &marks)  // an escape
                    case 0x60: show(range, in: &marks)  // a code span
                    case 0x5D: set(.dropped, range, in: &marks)  // a link's target
                    case 0x3C:  // a tag is not shown; an autolink is
                        let body = text.substring(with: match.range)
                        if body.contains("://") || body.contains("@") {
                            show(range, in: &marks)
                        } else {
                            set(.dropped, range, in: &marks)
                        }
                    default: show(range, in: &marks)  // a bare URL
                    }
                } else {
                    set(.dropped, range, in: &marks)
                    for name in innerGroups {
                        guard let inner = match.groups[name] else { continue }
                        set(.kept, NSRange(location: inner.location + base, length: inner.length), in: &marks)
                        if depth < 3 {
                            markSyntax(
                                text.substring(with: inner) as NSString, base: inner.location + base, depth: depth + 1,
                                in: &marks)
                        }
                    }
                }
            }
        }

        /// Drops the marks of emphasis, links and hard breaks that are left among the kept characters.
        private static func markDelimiters(_ units: [UInt16], in marks: inout [Mark]) {
            func unit(_ index: Int) -> UInt16 { index >= 0 && index < units.count ? units[index] : 0x20 }
            func isWordUnit(_ value: UInt16) -> Bool {
                guard let scalar = Unicode.Scalar(value) else { return true }
                return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            }
            var index = 0
            while index < units.count {
                defer { index += 1 }
                guard marks[index] == .kept else { continue }
                switch units[index] {
                case 0x2A, 0x5B: marks[index] = .dropped  // * [
                case 0x7E where unit(index - 1) == 0x7E || unit(index + 1) == 0x7E: marks[index] = .dropped  // ~~
                case 0x5F where !isWordUnit(unit(index - 1)) || !isWordUnit(unit(index + 1)):  // _ at a word's edge
                    marks[index] = .dropped
                case 0x21 where unit(index + 1) == 0x5B: marks[index] = .dropped  // ![
                case 0x5C where unit(index + 1) == 0x0A || unit(index + 1) == 0x0D: marks[index] = .dropped
                case 0x5D:  // ] and the label of a reference link after it
                    marks[index] = .dropped
                    guard unit(index + 1) == 0x5B else { continue }
                    var end = index + 2
                    while end < units.count, units[end] != 0x5D, units[end] != 0x0A { end += 1 }
                    guard end < units.count, units[end] == 0x5D else { continue }
                    for inside in (index + 1)...end where marks[inside] == .kept { marks[inside] = .dropped }
                    index = end
                default: break
                }
            }
        }

        private mutating func add(_ range: Range<Int>, lines: ClosedRange<Int>, marks: [Mark]) {
            var text: [UInt16] = []
            text.reserveCapacity(range.count)
            var runs: [ProseParagraph.Run] = []
            var index = 0
            while index < marks.count {
                switch marks[index] {
                case .kept:
                    let start = index
                    while index < marks.count, marks[index] == .kept { index += 1 }
                    runs.append(
                        .init(
                            text: text.count, source: range.lowerBound + start, length: index - start,
                            sourceLength: index - start))
                    text.append(contentsOf: source.units[(range.lowerBound + start)..<(range.lowerBound + index)])
                case .shownStart:
                    let start = index
                    index += 1
                    while index < marks.count, marks[index] == .shown { index += 1 }
                    runs.append(
                        .init(
                            text: text.count, source: range.lowerBound + start, length: 1, sourceLength: index - start))
                    text.append(0xFFFC)
                case .dropped, .shown: index += 1
                }
            }
            let prose = String(decoding: text, as: UTF16.self)
            guard prose.unicodeScalars.contains(where: \.properties.isAlphabetic) else { return }
            paragraphs.append(
                ProseParagraph(
                    index: paragraphs.count, lines: lines, sourceRange: range,
                    text: prose, runs: runs))
        }
    }
}

import Foundation
import Markdown
import cmark_gfm

/// One paragraph of a document's running text, as a reader sees it on the paper, with the way back to the source.
///
/// `text` is the paragraph without its markup: emphasis marks and link targets are left out, escapes and character
/// references are what they stand for, and what is shown but is not prose (inline code, a formula, a URL, an image)
/// is one U+FFFC each, so the words on either side of it do not read as neighbours. Every offset is in UTF-16 code
/// units, the unit of `NSRange` and of PDFKit's strings.
public struct ProseParagraph: Equatable, Sendable {
    /// What stands in `text` for inline code, a formula, a URL or an image.
    public static let placeholder: Character = "\u{FFFC}"

    /// The paragraph's place among the document's prose paragraphs, from 0.
    public let index: Int
    /// The one-based source lines the paragraph's text is written on, numbered as `MarkdownBlock.lines` numbers them
    /// (front matter included), so a paragraph can be matched to the block the converter made of it.
    public let lines: ClosedRange<Int>
    /// The paragraph in the source, from its first character to its last.
    public let sourceRange: Range<Int>
    public let text: String

    /// A stretch of `text` and where it came from. A copied stretch is the source unit for unit; any other (a
    /// placeholder, a decoded character reference, a line break) stands for the whole of its source stretch.
    struct Run: Equatable, Sendable {
        var text: Int
        var source: Int
        var length: Int
        var sourceLength: Int
        var isCopy: Bool
    }

    let runs: [Run]

    /// The part of the source that a range of `text` was read from. The answer runs from the first character of the
    /// range to its last, and so takes in any markup between them; an empty range gives an empty one. A range that
    /// reaches outside `text` is held within it.
    public func sourceRange(of range: Range<Int>) -> Range<Int> {
        let length = runs.last.map { $0.text + $0.length } ?? 0
        let range = range.clamped(to: 0..<length)
        guard let first = run(holding: range.lowerBound) else { return sourceRange.upperBound..<sourceRange.upperBound }
        let lower = first.isCopy ? first.source + range.lowerBound - first.text : first.source
        guard !range.isEmpty, let last = run(holding: range.upperBound - 1) ?? runs.last else { return lower..<lower }
        let upper =
            last.isCopy
            ? last.source + min(range.upperBound - last.text, last.length) : last.source + last.sourceLength
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
package struct ProseSource: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case markdown
        /// Plain text has no soft line breaks of its own: a line is as the writer broke it.
        case plainText
    }

    package let kind: Kind
    package let paragraphs: [ProseParagraph]

    /// The prose of a document of `format`, or nil for a format whose prose is not read yet.
    /// - Throws: `CancellationError` when the task it runs for is cancelled: between the lines and the blocks it
    ///   reads. The converter's own passes and the Markdown parser run to their end once started.
    package static func read(_ text: String, format: DocumentFormat) throws -> ProseSource? {
        switch format {
        case .markdown: return try markdown(text)
        case .plainText: return try plainText(text)
        default: return nil
        }
    }

    /// The paragraphs of a Markdown text. Offsets are into `text` as given (its line endings are not rewritten).
    ///
    /// The text goes through the converter's own passes over lines (front matter, deep nesting, page breaks,
    /// footnote definitions, display formulas, `:::` containers) and is then parsed as the converter parses it, so a
    /// paragraph here is a paragraph on the paper. Read: the paragraphs of the document, of its lists and of its
    /// footnotes, and the terms and descriptions of definition lists, each as a paragraph of its own. Not read:
    /// headings, code blocks, HTML blocks, tables, block quotes (callouts with them) and the titles of containers.
    /// Within a paragraph, cmark's tree says what is text: inline code, formulas, URLs and images are placeholders;
    /// link targets, tags, the marks of defined footnotes and the reading of a ruby are left out.
    package static func markdown(_ text: String) throws -> ProseSource {
        // swift-markdown builds its tree with a call per level, which needs the converter's stack.
        let paragraphs = StackSpace.onLargeStack(
            { () -> [ProseParagraph]? in
                var reader = MarkdownProseReader(source: SourceText(text))
                return reader.read() ? reader.paragraphs : nil
            },
            // Without that stack a deep document could end the app; such a document is then left unread.
            withoutThread: { () -> [ProseParagraph]? in [] })
        guard let paragraphs else { throw CancellationError() }
        return ProseSource(kind: .markdown, paragraphs: paragraphs)
    }

    /// The paragraphs of a plain text: runs of lines between blank lines. Only URLs and mail addresses are left
    /// out, where the converter's rule for bare addresses ends them.
    package static func plainText(_ text: String) throws -> ProseSource {
        let source = SourceText(text)
        var paragraphs: [ProseParagraph] = []
        var segments = ProseSegments(source: source)
        var first: Int?
        func isBlank(_ index: Int) -> Bool {
            source.units[source.ranges[index]].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x3000 }
        }
        for index in 0...source.ranges.count {
            if index % 512 == 0 { try Task.checkCancellation() }
            if index < source.ranges.count, !isBlank(index) {
                first = first ?? index
            } else if let start = first {
                let range = source.ranges[start].lowerBound..<source.ranges[index - 1].upperBound
                segments.cursor = range.lowerBound
                for link in MarkdownConverter.autolinks(in: String(decoding: source.units[range], as: UTF16.self)) {
                    let lower = range.lowerBound + link.range.location
                    segments.copy(segments.cursor..<lower)
                    segments.shown([0xFFFC], from: lower..<(lower + link.range.length))
                }
                segments.copy(segments.cursor..<range.upperBound)
                segments.finish(into: &paragraphs)
                first = nil
            }
        }
        return ProseSource(kind: .plainText, paragraphs: paragraphs)
    }
}

/// The text as UTF-16 and as lines. cmark ends a line at LF, CR LF or a lone CR, and so does this.
struct SourceText {
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

    /// The one-based line a source offset is on.
    func line(of offset: Int) -> Int {
        var low = 0
        var high = ranges.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if ranges[middle].lowerBound <= offset { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }
}

/// The current paragraph and the runs that lead back to its source. Finished paragraphs belong to the reader.
struct ProseSegments {
    let source: SourceText
    /// The source offset after the last piece taken.
    var cursor = 0
    private var text: [UInt16] = []
    private var runs: [ProseParagraph.Run] = []

    init(source: SourceText) { self.source = source }

    /// Takes a stretch of the source as it is written.
    mutating func copy(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        if let last = runs.indices.last, runs[last].isCopy, runs[last].source + runs[last].length == range.lowerBound {
            runs[last].length += range.count
            runs[last].sourceLength += range.count
        } else {
            runs.append(
                .init(
                    text: text.count, source: range.lowerBound, length: range.count, sourceLength: range.count,
                    isCopy: true))
        }
        text.append(contentsOf: source.units[range])
        cursor = max(cursor, range.upperBound)
    }

    /// Takes `units` as what a stretch of the source shows: a placeholder, a decoded reference, a line break.
    mutating func shown(_ units: [UInt16], from range: Range<Int>) {
        guard !units.isEmpty else { return }
        runs.append(
            .init(
                text: text.count, source: range.lowerBound, length: units.count, sourceLength: range.count,
                isCopy: false))
        text.append(contentsOf: units)
        cursor = max(cursor, range.upperBound)
    }

    /// Ends the paragraph being collected. White space at its ends and a paragraph without a letter are dropped.
    mutating func finish(into paragraphs: inout [ProseParagraph]) {
        defer {
            text = []
            runs = []
        }
        func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x3000 }
        var lower = 0
        var upper = text.count
        while lower < upper, isSpace(text[lower]) { lower += 1 }
        while upper > lower, isSpace(text[upper - 1]) { upper -= 1 }
        guard lower < upper else { return }
        var kept: [ProseParagraph.Run] = []
        for run in runs {
            let from = max(run.text, lower)
            let to = min(run.text + run.length, upper)
            guard from < to else { continue }
            if run.isCopy {
                kept.append(
                    .init(
                        text: from - lower, source: run.source + from - run.text, length: to - from,
                        sourceLength: to - from, isCopy: true))
            } else {
                kept.append(
                    .init(
                        text: from - lower, source: run.source, length: to - from, sourceLength: run.sourceLength,
                        isCopy: false))
            }
        }
        let prose = String(decoding: text[lower..<upper], as: UTF16.self)
        guard let first = kept.first, let last = kept.last,
            prose.unicodeScalars.contains(where: \.properties.isAlphabetic)
        else { return }
        let range = first.source..<(last.source + last.sourceLength)
        paragraphs.append(
            ProseParagraph(
                index: paragraphs.count,
                lines: source.line(of: range.lowerBound)...source.line(of: max(range.lowerBound, range.upperBound - 1)),
                sourceRange: range, text: prose, runs: kept))
    }
}

/// Reads the prose of a Markdown text from the tree the converter's parser makes of it.
private struct MarkdownProseReader {
    /// A line as the parser is given it. A line that is source text as written (all of a source line, or its end
    /// after a footnote's label or indent) knows where it stands; a line the converter's passes made does not.
    struct Line {
        var text: String
        var source: Int?
    }

    let source: SourceText
    var paragraphs: [ProseParagraph] = []
    private var footnotes: Set<String> = []
    private var cancelled = false

    init(source: SourceText) {
        self.source = source
    }

    /// False when the task was cancelled.
    mutating func read() -> Bool {
        var mapped = MarkdownSourceLines(source.lines)
        if let end = MarkdownConverter.frontMatterEnd(in: source.lines) {
            mapped = MarkdownSourceLines(
                Array(source.lines.dropFirst(end + 1)), origins: Array(mapped.origins.dropFirst(end + 1)))
        }
        mapped.lines = MarkdownPageBreaks.marking(MarkdownNesting.flattened(mapped.lines).lines, customLine: "")
        if StackSpace.isCancelled { return false }
        let extracted = MarkdownExtensions.extractFootnotes(mapped)
        footnotes = Set(extracted.definitions.keys)
        let notes = MarkdownExtensions.Footnotes(
            definitions: extracted.definitions.mapValues { $0.lines.joined(separator: "\n") })
        read(extracted.body, notes: notes)
        notes.forEachReferenced { _, id in
            if !cancelled, let definition = extracted.definitions[id] { read(definition, notes: notes) }
        }
        return !cancelled
    }

    private mutating func read(_ part: MarkdownSourceLines, notes: MarkdownExtensions.Footnotes) {
        let lines = MarkdownCallouts.preprocess(
            MarkdownExtensions.rewriteInline(
                part, footnotes: notes,
                formulas: MarkdownExtensions.Formulas(), blocksOnly: true))
        var parsed: [Line] = []
        parsed.reserveCapacity(lines.lines.count)
        for (index, text) in lines.lines.enumerated() {
            var offset: Int?
            if lines.origins[index].count == 1, let number = lines.origins[index].first, number >= 1,
                number <= source.lines.count, source.lines[number - 1].hasSuffix(text)
            {
                offset = source.ranges[number - 1].upperBound - text.utf16.count
            }
            parsed.append(Line(text: text, source: offset))
        }
        read(parsed)
    }

    private mutating func read(_ lines: [Line]) {
        let texts = lines.map(\.text)
        let document = MarkdownNesting.document(parsing: texts.joined(separator: "\n"), options: [.disableSmartOpts])
        visit(document, lines: lines, texts: texts)
    }

    private mutating func visit(_ container: any Markup, lines: [Line], texts: [String]) {
        let blocks = Array(container.children)
        func definitionStarts(_ paragraph: Paragraph) -> [Bool] {
            MarkdownExtensions.lines(of: paragraph).map {
                MarkdownExtensions.definitionBody($0, sourceLines: texts) != nil
            }
        }
        var index = 0
        while index < blocks.count {
            if StackSpace.isCancelled { cancelled = true }
            if cancelled { return }
            defer { index += 1 }
            let block = blocks[index]
            if block is UnorderedList || block is OrderedList {
                for item in block.children { visit(item, lines: lines, texts: texts) }
                continue
            }
            guard let paragraph = block as? Paragraph else { continue }
            guard paragraph.range != nil else {
                // The table extension turns the lines before a table's header into a paragraph without positions,
                // and gives the table that paragraph's first line. The lines are read again on their own.
                if index + 1 < blocks.count, let table = blocks[index + 1] as? Table, let range = table.range {
                    let header = range.upperBound.line - 1 - table.body.childCount
                    let first = range.lowerBound.line
                    if first >= 1, header > first, header - 1 <= lines.count {
                        read(Array(lines[(first - 1)..<(header - 1)]))
                    }
                }
                continue
            }
            if MarkdownExtensions.isTableOfContentsMarker(paragraph) { continue }
            let starts = definitionStarts(paragraph)
            // The converter's two forms of a definition list: terms and `: ` lines in one paragraph, or a paragraph
            // of terms followed by paragraphs that start with `: `.
            if starts.count >= 2, !starts[0], starts[1] {
                emit(paragraph, lines: lines, plan: starts.map { .start(marker: $0) })
            } else if !starts.contains(true), index + 1 < blocks.count, let next = blocks[index + 1] as? Paragraph,
                next.range != nil, definitionStarts(next).first == true
            {
                emit(paragraph, lines: lines, plan: starts.map { _ in .start(marker: false) })
                while index + 1 < blocks.count, let body = blocks[index + 1] as? Paragraph, body.range != nil {
                    let bodyStarts = definitionStarts(body)
                    guard bodyStarts.first == true else { break }
                    emit(body, lines: lines, plan: bodyStarts.map { $0 ? .start(marker: true) : .goesOn })
                    index += 1
                }
            } else {
                emit(paragraph, lines: lines, plan: [])
            }
        }
    }

    /// What a line of a paragraph is to the prose: the start of a paragraph of its own (after a `: ` that is not
    /// read), or more of the one before.
    enum LinePlan {
        case start(marker: Bool)
        case goesOn
    }

    private mutating func emit(_ paragraph: Paragraph, lines: [Line], plan: [LinePlan]) {
        guard let range = paragraph.range else { return }
        let first = range.lowerBound.line
        var last = min(range.upperBound.line, lines.count)
        if range.upperBound.column <= 1, last > first { last -= 1 }
        guard first >= 1, first <= last, lines[(first - 1)..<last].allSatisfy({ $0.source != nil }) else { return }
        var walk = InlineWalk(
            lines: lines, first: first, last: last, firstColumn: range.lowerBound.column, footnotes: footnotes,
            segments: ProseSegments(source: source))
        walk.run(paragraph, plan: plan, into: &paragraphs)
        cancelled = walk.cancelled
    }
}

/// Walks the inline tree of one paragraph and collects its text.
///
/// cmark gives every inline node a line and a column, but they are only as good as its bookkeeping: after a line
/// break written with a backslash the line number stays where it was and the column counts on from that line's
/// start, and a paragraph that began with link reference definitions numbers its lines from the first definition.
/// `position(_:)` undoes both, and tests fix it against the source.
private struct InlineWalk {
    let lines: [MarkdownProseReader.Line]
    let last: Int
    let footnotes: Set<String>
    var segments: ProseSegments
    private(set) var cancelled = false

    /// The line cmark's current line number stands for, and that number.
    private var anchorLine: Int
    private var anchorNumber: Int
    /// The line of the last position resolved.
    private var lastLine: Int
    /// Where each line's own content starts, in bytes: after the list marker on the paragraph's first line, after
    /// the indentation on the others.
    private let firstLine: Int
    private let contentStart: [Int]
    /// Byte positions in cmark's paragraph buffer, which omits each line's leading indentation.
    private let lineOffsets: [Int]
    /// The paragraph's left edge, in bytes of its first line.
    private let blockOffset: Int
    private var utf16Offsets: [Int: [Int32]] = [:]

    /// Per UTF-16 unit of the paragraph's lines: 0 for text, -1 for what the converter's syntax hides, and n for
    /// the n-th stretch that is shown as something else.
    private var marks: [Int32] = []
    private let marksBase: Int
    private var stretches: [Range<Int>] = []
    private var stretchShown: [Bool] = []

    /// An element whose contents are not prose is open: its name, where it began, and whether it shows anything.
    private var hidden: (name: String, start: Int, isShown: Bool)?
    private var linkDepth = 0
    private var skipsMarker = false

    private static let mathGroups = ["displayMath", "inlineMath", "displayMath2", "inlineMath2"]
    private static let innerGroups = [
        "criticAdd", "criticDelete", "criticMark", "criticOld", "criticNew", "mark", "sup", "sub", "rubyBase",
    ]
    /// Elements whose text is not the document's prose. A ruby's reading is not shown as a placeholder either.
    private static let codeElements: Set<String> = [
        "code", "kbd", "samp", "pre", "tt", "script", "style", "svg", "math",
    ]
    private static let readingElements: Set<String> = ["rt", "rp"]
    private static let objectElements: Set<String> = ["img", "video", "audio", "iframe", "object", "canvas", "input"]

    init(
        lines: [MarkdownProseReader.Line], first: Int, last: Int, firstColumn: Int, footnotes: Set<String>,
        segments: ProseSegments
    ) {
        self.lines = lines
        self.last = last
        self.footnotes = footnotes
        self.segments = segments
        anchorLine = first
        anchorNumber = first
        lastLine = first
        firstLine = first
        blockOffset = max(0, firstColumn - 1)
        var starts: [Int] = []
        var offsets: [Int] = []
        var total = 0
        for line in first...last {
            let bytes = lines[line - 1].text.utf8
            let start = line == first ? min(blockOffset, bytes.count) : bytes.prefix { $0 == 0x20 || $0 == 0x09 }.count
            starts.append(start)
            offsets.append(total)
            total += bytes.count - start + 1
        }
        contentStart = starts
        lineOffsets = offsets
        marksBase = lines[first - 1].source ?? 0
    }

    // MARK: Positions

    private func text(_ line: Int) -> String { lines[line - 1].text }
    private func start(of line: Int) -> Int { contentStart[line - firstLine] }

    /// The source offset of a byte of a line.
    private mutating func offset(line: Int, byte: Int) -> Int {
        if utf16Offsets[line] == nil {
            var table: [Int32] = [0]
            table.reserveCapacity(text(line).utf8.count + 1)
            var length: Int32 = 0
            for scalar in text(line).unicodeScalars {
                let width = UTF8.width(scalar)
                // A position inside a character is held to its start.
                for _ in 1..<width { table.append(length) }
                length += Int32(UTF16.width(scalar))
                table.append(length)
            }
            utf16Offsets[line] = table
        }
        let table = utf16Offsets[line] ?? [0]
        return (lines[line - 1].source ?? 0) + Int(table[min(max(byte, 0), table.count - 1)])
    }

    private mutating func position(_ location: SourceLocation) -> Int {
        if location.line > anchorNumber {
            // cmark moved on by so many lines since the last position; a line break it did not count was a
            // backslash's, and `lastLine` already stands on the line after it.
            anchorLine = min(last, lastLine + location.line - anchorNumber)
            anchorNumber = location.line
        }
        let target = lineOffsets[anchorLine - firstLine] + max(0, location.column - 1 - blockOffset)
        var low = anchorLine
        var high = last
        while low < high {
            let middle = (low + high + 1) / 2
            if lineOffsets[middle - firstLine] <= target { low = middle } else { high = middle - 1 }
        }
        lastLine = low
        return offset(line: low, byte: start(of: low) + target - lineOffsets[low - firstLine])
    }

    /// cmark keeps the original paragraph position when it removes reference definitions. Ask its definition
    /// parser how much of the de-indented paragraph it consumed, including multiline labels and titles.
    private mutating func skipDefinitions() {
        guard firstLine < last else { return }
        let first = text(firstLine).utf8.dropFirst(start(of: firstLine))
        guard first.first == 0x5B || first.starts(with: [0x5E, 0x5B]) else { return }
        var bytes: [UInt8] = []
        for line in firstLine...last {
            bytes.append(contentsOf: text(line).utf8.dropFirst(start(of: line)))
            bytes.append(0x0A)
        }
        guard let size = Int32(exactly: bytes.count) else { return }
        bytes.append(0)  // cmark's scanners expect a sentinel after the chunk.
        let memory = cmark_get_default_mem_allocator()
        let map = cmark_reference_map_new(memory)
        defer { cmark_map_free(map) }
        let consumed = bytes.withUnsafeMutableBufferPointer { buffer in
            var chunk = cmark_chunk(data: buffer.baseAddress, len: size, alloc: 0)
            while chunk.len > 0 {
                let length: Int32
                if chunk.data[0] == 0x5B {
                    length = cmark_parse_reference_inline(memory, &chunk, map)
                } else if chunk.len >= 2, chunk.data[0] == 0x5E, chunk.data[1] == 0x5B {
                    length = cmark_parse_reference_attributes_inline(memory, &chunk, map)
                } else {
                    break
                }
                guard length > 0 else { break }
                chunk.data += Int(length)
                chunk.len -= length
            }
            return Int(size - chunk.len)
        }
        if consumed > 0, let next = lineOffsets.firstIndex(of: consumed) {
            anchorLine = firstLine + next
            lastLine = anchorLine
        }
    }

    // MARK: Marks

    private mutating func prepareMarks() {
        guard let lastSource = lines[last - 1].source else { return }
        for line in anchorLine...last {
            let text = text(line)
            guard text.contains(where: { "[{=^~$\\".contains($0) }), let base = lines[line - 1].source else { continue }
            if marks.isEmpty {
                marks = [Int32](repeating: 0, count: lastSource + lines[last - 1].text.utf16.count - marksBase)
            }
            mark(text as NSString, base: base, depth: 0)
        }
    }

    private mutating func ensureMarks() {
        guard marks.isEmpty, let lastSource = lines[last - 1].source else { return }
        marks = [Int32](repeating: 0, count: lastSource + lines[last - 1].text.utf16.count - marksBase)
    }

    private mutating func set(_ value: Int32, _ range: NSRange, base: Int) {
        let lower = range.location + base - marksBase
        guard range.length > 0, lower >= 0, lower + range.length <= marks.count else { return }
        for index in lower..<(lower + range.length) { marks[index] = value }
    }

    private mutating func show(_ range: Range<Int>) {
        ensureMarks()
        stretches.append(range)
        stretchShown.append(false)
        set(Int32(stretches.count), NSRange(location: range.lowerBound, length: range.count), base: 0)
    }

    /// Marks what the converter's own inline scanner finds on a line, which it rewrites before cmark sees the text:
    /// formulas, footnote marks, rubies, highlights and edits. Code spans, tags and link targets are cmark's.
    private mutating func mark(_ text: NSString, base: Int, depth: Int) {
        for match in MarkdownExtensions.inlineMatches(text) {
            if Self.mathGroups.contains(where: { match.groups[$0] != nil }) {
                show((match.range.location + base)..<(match.range.location + match.range.length + base))
            } else if match.groups["verbatim"] != nil || match.groups["criticUnclosed"] != nil {
                continue
            } else if let label = match.groups["footnote"] {
                // A mark without a definition is printed as written.
                if footnotes.contains(text.substring(with: label).lowercased()) { set(-1, match.range, base: base) }
            } else {
                set(-1, match.range, base: base)
                for name in Self.innerGroups {
                    guard let inner = match.groups[name] else { continue }
                    set(0, inner, base: base)
                    if depth < 3 {
                        mark(text.substring(with: inner) as NSString, base: inner.location + base, depth: depth + 1)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    /// What the mark of a source offset lets through: true for text. A stretch shown as something else gives its
    /// placeholder the first time it is met.
    private func isText(_ offset: Int) -> Bool {
        let index = offset - marksBase
        return hidden == nil && !(index >= 0 && index < marks.count && marks[index] != 0)
    }

    private mutating func passes(_ offset: Int) -> Bool {
        guard hidden == nil else { return false }
        let index = offset - marksBase
        guard index >= 0, index < marks.count, marks[index] != 0 else { return true }
        let mark = Int(marks[index])
        if mark > 0, !stretchShown[mark - 1] {
            stretchShown[mark - 1] = true
            segments.shown([0xFFFC], from: stretches[mark - 1])
        }
        return false
    }

    private mutating func placeholder(_ range: Range<Int>) {
        if passes(range.lowerBound) { segments.shown([0xFFFC], from: range) }
    }

    /// Read cmark's visible text with its source spelling, so escapes, references and links retain their positions.
    private mutating func take(_ range: Range<Int>, as string: String) {
        let units = segments.source.units
        var range = range
        var literal = Array(string.utf16)
        if skipsMarker {
            // The `: ` of a definition, as `MarkdownExtensions.definitionBody` takes it off.
            skipsMarker = false
            var skipped = 0
            while range.lowerBound + skipped < range.upperBound,
                skipped == 0
                    ? units[range.lowerBound] == 0x3A : [0x20, 0x09].contains(units[range.lowerBound + skipped])
            {
                skipped += 1
            }
            range = (range.lowerBound + skipped)..<range.upperBound
            literal.removeFirst(min(skipped, literal.count))
        }
        // The spaces of a hard break are a text node without text.
        guard !literal.isEmpty, range.lowerBound < range.upperBound, range.upperBound <= units.count else {
            segments.cursor = max(segments.cursor, min(range.upperBound, units.count))
            return
        }
        if linkDepth == 0, hidden == nil {
            markAutolinks(in: string, literal: literal, source: range)
            if cancelled { return }
        }
        let complete = ProseTextDecoding.scan(units, range: range, literal: literal) { source, decoded in
            if let decoded {
                if passes(source.lowerBound) { segments.shown(decoded, from: source) }
            } else if marks.isEmpty && hidden == nil {
                segments.copy(source)
            } else {
                var copied = source.lowerBound
                for offset in source where !isText(offset) {
                    segments.copy(copied..<offset)
                    _ = passes(offset)
                    copied = offset + 1
                }
                segments.copy(copied..<source.upperBound)
            }
        }
        cancelled = !complete
        segments.cursor = max(segments.cursor, range.upperBound)
    }

    /// Links are recognized on cmark's text. Only nodes with both a link and a changed spelling need the
    /// decoder to translate the link boundaries before the normal marks are applied.
    private mutating func markAutolinks(in string: String, literal: [UInt16], source range: Range<Int>) {
        guard string.contains("@") || string.contains("://") || string.localizedCaseInsensitiveContains("www.") else {
            return
        }
        let links = MarkdownConverter.autolinks(in: String(decoding: literal, as: UTF16.self))
        guard !links.isEmpty else { return }
        let units = segments.source.units
        if units[range].elementsEqual(literal) {
            for link in links {
                show((range.lowerBound + link.range.location)..<(range.lowerBound + NSMaxRange(link.range)))
            }
            return
        }

        var visibleStart = 0
        var next = 0
        var sourceStart = range.lowerBound
        let complete = ProseTextDecoding.scan(units, range: range, literal: literal) { source, decoded in
            let visibleEnd = visibleStart + (decoded?.count ?? source.count)
            while next < links.count {
                let link = links[next].range
                if link.location >= visibleEnd { break }
                if link.location >= visibleStart {
                    sourceStart = decoded == nil ? source.lowerBound + link.location - visibleStart : source.lowerBound
                }
                let end = NSMaxRange(link)
                if end > visibleEnd { break }
                let sourceEnd = decoded == nil ? source.lowerBound + end - visibleStart : source.upperBound
                show(sourceStart..<sourceEnd)
                next += 1
            }
            visibleStart = visibleEnd
        }
        cancelled = !complete
    }

    /// The line break after the last piece, wherever in the source it is written.
    private mutating func lineBreak(isTaken: Bool) {
        let units = segments.source.units
        let limit = (lines[last - 1].source ?? 0) + lines[last - 1].text.utf16.count
        var at = segments.cursor
        while at < limit, units[at] != 0x0A, units[at] != 0x0D { at += 1 }
        guard at < limit else { return }
        let end = units[at] == 0x0D && at + 1 < limit && units[at + 1] == 0x0A ? at + 2 : at + 1
        if isTaken, passes(at) { segments.shown([0x0A], from: at..<end) }
        segments.cursor = max(segments.cursor, end)
    }

    private mutating func tag(_ raw: String, _ range: Range<Int>) {
        let isClosing = raw.hasPrefix("</")
        let name = String(raw.dropFirst(isClosing ? 2 : 1).prefix { $0.isLetter || $0.isNumber }).lowercased()
        if let open = hidden {
            guard isClosing, name == open.name else { return }
            hidden = nil
            if open.isShown { placeholder(open.start..<range.upperBound) }
            return
        }
        guard !isClosing, !name.isEmpty else { return }
        if !raw.hasSuffix("/>"), Self.readingElements.contains(name) {
            hidden = (name, range.lowerBound, false)
        } else if !raw.hasSuffix("/>"), Self.codeElements.contains(name) {
            // The placeholder is given when the element closes, for all of it.
            if isText(range.lowerBound) { hidden = (name, range.lowerBound, true) }
        } else if Self.objectElements.contains(name) {
            placeholder(range)
        } else if name == "br", passes(range.lowerBound) {
            segments.shown([0x20], from: range)
        }
    }

    private mutating func closeHidden() {
        guard let open = hidden else { return }
        hidden = nil
        if open.isShown { placeholder(open.start..<max(open.start, segments.cursor)) }
    }

    // MARK: Walking

    mutating func run(_ paragraph: Paragraph, plan: [LinePlan], into paragraphs: inout [ProseParagraph]) {
        skipDefinitions()
        prepareMarks()
        segments.cursor = offset(line: anchorLine, byte: start(of: anchorLine))
        var line = 0
        if case .start(let marker)? = plan.first { skipsMarker = marker }
        for child in paragraph.children {
            if cancelled { return }
            guard child is SoftBreak || child is LineBreak else {
                walk(child)
                continue
            }
            line += 1
            if line < plan.count, case .start(let marker) = plan[line] {
                closeHidden()
                segments.finish(into: &paragraphs)
                lineBreak(isTaken: false)
                skipsMarker = marker
            } else {
                lineBreak(isTaken: true)
            }
        }
        closeHidden()
        segments.finish(into: &paragraphs)
    }

    private mutating func walk(_ node: any Markup) {
        guard !cancelled else { return }
        guard let range = node.range else {
            for child in node.children { walk(child) }
            return
        }
        let lower = position(range.lowerBound)
        func upper(_ walk: inout InlineWalk) -> Int { max(lower, walk.position(range.upperBound)) }
        switch node {
        case let text as Text:
            take(lower..<upper(&self), as: text.string)
        case is SoftBreak, is LineBreak:
            lineBreak(isTaken: true)
        case is InlineCode, is Image:
            let end = upper(&self)
            placeholder(lower..<end)
            segments.cursor = max(segments.cursor, end)
        case let html as InlineHTML:
            let end = upper(&self)
            tag(html.rawHTML, lower..<end)
            segments.cursor = max(segments.cursor, end)
        case let link as Link:
            // Ordinary link labels remain prose even if they spell their destination exactly.
            if segments.source.units.indices.contains(lower), segments.source.units[lower] == 0x3C {
                let end = upper(&self)
                placeholder(lower..<end)
                segments.cursor = max(segments.cursor, end)
            } else {
                linkDepth += 1
                for child in link.children { walk(child) }
                linkDepth -= 1
                segments.cursor = max(segments.cursor, upper(&self))
            }
        default:
            for child in node.children { walk(child) }
            segments.cursor = max(segments.cursor, upper(&self))
        }
    }

    typealias LinePlan = MarkdownProseReader.LinePlan
}

/// Maps cmark's visible text to copied source stretches and decoded character references.
enum ProseTextDecoding {
    static func scan(
        _ units: [UInt16], range: Range<Int>, literal: [UInt16],
        emit: (Range<Int>, [UInt16]?) -> Void
    ) -> Bool {
        var at = range.lowerBound
        var read = 0
        var copied = at
        func flush(to end: Int) {
            if copied < end { emit(copied..<end, nil) }
        }
        var nextCheck = at + 2048
        while at < range.upperBound {
            if at >= nextCheck {
                if StackSpace.isCancelled { return false }
                nextCheck = at + 2048
            }
            let unit = units[at]
            if unit == 0x26, let end = referenceEnd(units, at, range.upperBound),
                let decoded = decodeReference(units[(at + 1)..<end]), literal.dropFirst(read).starts(with: decoded)
            {
                flush(to: at)
                emit(at..<end, decoded)
                read += decoded.count
                at = end
                copied = at
            } else if unit == 0x5C, at + 1 < range.upperBound, read < literal.count, literal[read] == units[at + 1],
                isPunctuation(units[at + 1])
            {
                flush(to: at)
                copied = at + 1
                at += 2
                read += 1
            } else {
                at += 1
                read += 1
            }
        }
        flush(to: range.upperBound)
        return true
    }

    /// Use the same named-entity table and numeric replacement rules as cmark's inline parser.
    private static func decodeReference(_ spelling: ArraySlice<UInt16>) -> [UInt16]? {
        let bytes = spelling.map { UInt8($0) }
        var buffer = cmark_strbuf()
        cmark_strbuf_init(cmark_get_default_mem_allocator(), &buffer, 0)
        defer { cmark_strbuf_free(&buffer) }
        guard houdini_unescape_ent(&buffer, bytes, Int32(bytes.count)) == bytes.count else { return nil }
        let decoded = UnsafeBufferPointer(start: buffer.ptr, count: Int(buffer.size))
        return Array(String(decoding: decoded, as: UTF8.self).utf16)
    }

    private static func isPunctuation(_ unit: UInt16) -> Bool {
        (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit) || (0x5B...0x60).contains(unit)
            || (0x7B...0x7E).contains(unit)
    }

    /// The end of what may be a character reference at `start` (`&name;`, `&#38;`), or nil.
    private static func referenceEnd(_ units: [UInt16], _ start: Int, _ limit: Int) -> Int? {
        var index = start + 1
        while index < limit, index - start <= 33 {
            let unit = units[index]
            if unit == 0x3B { return index > start + 1 ? index + 1 : nil }
            guard
                unit == 0x23 || (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit)
                    || (0x61...0x7A).contains(unit)
            else { return nil }
            index += 1
        }
        return nil
    }
}

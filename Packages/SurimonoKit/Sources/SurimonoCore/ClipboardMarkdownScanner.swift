import Foundation
import cmark_gfm
import cmark_gfm_extensions

extension ClipboardScanners {
    static func markdown(
        _ window: ClipboardWindow, level: ClipboardFormatSettings.Carefulness, work: inout ClipboardWork
    ) -> ClipboardCandidate {
        var result = ClipboardCandidate(kind: .markdown)
        guard !window.bytes.isEmpty else { return result }
        var source = window.bytes
        if excessiveNesting(source, work: &work) {
            result.structures = 1
            result.accepted = false
            result.evidence = [.incomplete]
            return result
        }
        // Inline ticks alone cannot contribute structure. Keep the depth guard before this proof.
        guard markdownPossible(window.bytes, lines: window.lines, work: &work) else { return result }
        var frontMatter = false
        if let first = window.lines.first, ClipboardSlice(source, first).trimmed.equals("---") {
            for line in window.lines.dropFirst() {
                work.visit(line.count)
                if ClipboardSlice(source, line).trimmed.equals("---") {
                    for i in 0..<line.upperBound {
                        if source[i] != 10 { source[i] = 32 }
                        work.visit()
                    }
                    frontMatter = true
                    break
                }
            }
        }
        // The parser owns CommonMark containers and inline code. Byte columns refer to the unchanged source layout.
        // Use the very same cmark grammar, options and extensions as swift-markdown. The detector
        // needs node kinds and byte positions, not a second, recursively converted Swift AST.
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS | CMARK_OPT_SMART | CMARK_OPT_SOURCEPOS) else {
            result.structures = 1
            result.accepted = false
            result.evidence = [.incomplete]
            return result
        }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        source.withUnsafeBytes { buffer in
            cmark_parser_feed(parser, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), buffer.count)
        }
        guard let root = cmark_parser_finish(parser) else {
            result.structures = 1
            result.accepted = false
            result.evidence = [.incomplete]
            return result
        }
        defer { cmark_node_free(root) }
        work.visit(source.count)
        var hidden = [Int](repeating: 0, count: source.count + 1)
        var headings = 0
        var lists = 0
        var codes = 0
        var tables = 0
        var links = 0
        var emphasis = 0
        var quotes = 0
        var inlineCodes = 0
        var orgSyntax = false
        var shellComments = false
        var invalidTable = false
        var ownsStart = frontMatter
        func offset(line: Int, column: Int) -> Int {
            guard line > 0 && line <= window.lines.count else { return source.count }
            return min(source.count, window.lines[line - 1].lowerBound + max(0, column - 1))
        }
        func span(_ node: ClipboardMarkdownNode) -> Range<Int>? {
            let firstLine = Int(cmark_node_get_start_line(node.pointer))
            let firstColumn = Int(cmark_node_get_start_column(node.pointer))
            let lastLine = Int(cmark_node_get_end_line(node.pointer))
            let lastColumn = Int(cmark_node_get_end_column(node.pointer)) + 1
            guard firstLine > 0, firstColumn > 0, lastLine > 0, lastColumn > 0 else { return nil }
            // swift-markdown expands code spans to include their opening and closing backticks.
            let ticks = Int(cmark_node_get_backtick_count(node.pointer))
            guard firstLine < lastLine || firstColumn - ticks <= lastColumn + ticks else { return nil }
            let lower = offset(line: firstLine, column: firstColumn - ticks)
            let upper = offset(line: lastLine, column: lastColumn + ticks)
            return lower..<max(lower, upper)
        }
        func protect(_ range: Range<Int>) {
            hidden[range.lowerBound] += 1
            hidden[range.upperBound] -= 1
        }
        var top: [ClipboardMarkdownNode] = []
        var child = cmark_node_first_child(root)
        while let pointer = child {
            top.append(ClipboardMarkdownNode(pointer))
            child = cmark_node_next(pointer)
        }
        var nodes = Array(top.reversed())
        let firstContent = top.first { node in
            if node.kind == "html_block", let range = span(node) {
                return !ClipboardSlice(source, range).trimmed.hasPrefix("<!--")
            }
            return true
        }
        if let first = firstContent {
            ownsStart = ownsStart || ["heading", "list", "code_block", "block_quote", "table"].contains(first.kind)
            if first.kind == "paragraph", let pointer = cmark_node_first_child(first.pointer) {
                let inline = ClipboardMarkdownNode(pointer)
                ownsStart = ownsStart || inline.kind == "image" || inline.kind == "strong"
                if inline.kind == "link" {
                    var child = cmark_node_first_child(pointer)
                    while let pointer = child {
                        if ClipboardMarkdownNode(pointer).kind == "image" { ownsStart = true }
                        child = cmark_node_next(pointer)
                    }
                }
            }
        }
        while let node = nodes.popLast() {
            work.visit()
            if node.kind == "heading" { headings += 1 }
            if node.kind == "item" || node.kind == "tasklist" {
                lists += 1
                if node.kind == "tasklist" { emphasis += 1 }
            }
            if node.kind == "block_quote" { quotes += 1 }
            if node.kind == "link" || node.kind == "image" {
                links += 1
                if let range = span(node) { protect(range) }
            }
            if ["strong", "emph", "strikethrough"].contains(node.kind) { emphasis += 1 }
            if node.kind == "code_block" {
                if let range = span(node) {
                    func fenceLine(_ bounds: Range<Int>) -> ClipboardSlice {
                        let line = ClipboardSlice(window.bytes, bounds).trimmed
                        var start = line.range.lowerBound
                        while start < line.range.upperBound && (window.bytes[start] == 62 || window.bytes[start] == 32)
                        { start += 1 }
                        return ClipboardSlice(window.bytes, start..<line.range.upperBound)
                    }
                    var end = range.lowerBound
                    while end < range.upperBound && window.bytes[end] != 10 {
                        end += 1
                        work.visit()
                    }
                    let fence = fenceLine(range.lowerBound..<end)
                    if fence.hasPrefix("```") || fence.hasPrefix("~~~") {
                        codes += 1
                        if String(cString: cmark_node_get_literal(node.pointer)).unicodeScalars.allSatisfy({
                            $0.value == 0xFEFF || CharacterSet.whitespacesAndNewlines.contains($0)
                        }) {
                            result.accepted = false
                        }
                        let character = fence.first ?? 96
                        func markEnd(_ line: ClipboardSlice) -> Int {
                            var i = line.range.lowerBound
                            while i < line.range.upperBound && window.bytes[i] == character {
                                i += 1
                                work.visit()
                            }
                            return i
                        }
                        let openingCount = markEnd(fence) - fence.range.lowerBound
                        var lastEnd = range.upperBound
                        while lastEnd > range.lowerBound && window.bytes[lastEnd - 1] == 10 { lastEnd -= 1 }
                        var lastStart = lastEnd
                        while lastStart > range.lowerBound && window.bytes[lastStart - 1] != 10 {
                            lastStart -= 1
                            work.visit()
                        }
                        let closing = fenceLine(lastStart..<lastEnd)
                        let closingEnd = markEnd(closing)
                        if lastStart <= range.lowerBound || closingEnd - closing.range.lowerBound < openingCount
                            || !ClipboardSlice(window.bytes, closingEnd..<closing.range.upperBound).trimmed.isEmpty
                        {
                            result.accepted = false
                        }
                    }
                }
                if let range = span(node) { protect(range) }
                continue
            }
            if node.kind == "code" {
                inlineCodes += 1
                if let range = span(node) { protect(range) }
                continue
            }
            if node.kind == "table", span(node) != nil {
                let first = max(0, Int(cmark_node_get_start_line(node.pointer)) - 1)
                let last = min(window.lines.count, Int(cmark_node_get_end_line(node.pointer)))
                var columns: Int?
                var valid = true
                for index in first..<last {
                    let cells = markdownCells(ClipboardSlice(window.bytes, window.lines[index]), work: &work)
                    if index == first { columns = cells.count }
                    if cells.count != columns { valid = false }
                    if index == first + 1 {
                        for cell in cells {
                            let value = cell.trimmed
                            var lo = value.range.lowerBound
                            var hi = value.range.upperBound
                            while lo < hi && window.bytes[lo] == 58 { lo += 1 }
                            while hi > lo && window.bytes[hi - 1] == 58 { hi -= 1 }
                            work.visit(hi - lo)
                            if lo == hi || !window.bytes[lo..<hi].allSatisfy({ $0 == 45 }) { valid = false }
                        }
                    }
                }
                if valid {
                    tables += 1
                    if let range = span(node) { protect(range) }
                } else {
                    invalidTable = true
                }
                continue
            }
            // HTML is validated separately below; inline attributes must not become running source code.
            if node.kind == "html_inline" {
                if let range = span(node), !safeInlineHTML(ClipboardSlice(window.bytes, range), work: &work) {
                    result.accepted = false
                }
            }
            var child = cmark_node_last_child(node.pointer)
            while let pointer = child {
                nodes.append(ClipboardMarkdownNode(pointer))
                child = cmark_node_previous(pointer)
            }
        }
        var depth = 0
        for i in source.indices {
            work.visit()
            depth += hidden[i]
            if depth > 0 && source[i] != 10 { source[i] = 32 }
        }
        var running = source
        // Display math and HTML comments are additional Surimono constructs, outside CommonMark's grammar.
        running = markdownOpaque(running, work: &work, accepted: &result.accepted)
        running = markdownHTML(running, work: &work, accepted: &result.accepted)
        if unsafeText(running, work: &work) { result.accepted = false }
        for range in window.lines {
            let line = ClipboardSlice(window.bytes, range).trimmed
            work.visit(range.count)
            if line.hasPrefix("#+") || line.contains("[[")
                || ([42, 83, 68].contains(line.first ?? 0)
                    && matches(
                        line, #"^\*{2,}\s|^\*+\s+(TODO|DONE|NEXT|WAITING)\b|^(SCHEDULED|DEADLINE):"#, work: &work))
            {
                orgSyntax = true
            }
        }
        if headings > 0 {
            let lines = window.lines.map { ClipboardSlice(running, $0).trimmed }
            var commentPairs = 0
            for i in lines.indices where i + 1 < lines.count {
                work.visit()
                if lines[i].hasPrefix("# "), !lines[i + 1].isEmpty,
                    !lines[i + 1].hasPrefix("#") && !lines[i + 1].hasPrefix("-")
                {
                    commentPairs += 1
                }
            }
            if commentPairs >= 2 || (commentPairs >= 1 && unsafeText(running, work: &work)) {
                headings = 0
                shellComments = true
            }
        }
        result.structures = headings + lists + codes + tables + quotes
        if frontMatter { result.structures += 1 }
        if !ownsStart && headings == 0 && tables == 0 && codes == 0 && links + emphasis < 2 { result.structures = 0 }
        if links >= 2 && result.structures == 0 { result.structures = 1 }
        if orgSyntax && headings == 0 && tables == 0 && codes == 0 {
            result.structures = 0
            result.accepted = false
        }
        if shellComments {
            result.structures = 0
            result.accepted = false
        }
        result.strength = 60
        result.ownsStart = ownsStart
        result.accepted = result.accepted && ownsStart && !invalidTable
        let mathSupport = running.contains(36) && headings > 0 ? 2 : 0
        let rich = emphasis + links + inlineCodes + mathSupport
        let support = headings + lists + rich
        switch level {
        case .careful:
            result.sufficient = tables > 0 || codes > 0 || (support >= 5 && (rich > 0 || headings >= 2))
        case .standard:
            result.sufficient =
                tables > 0 || codes > 0 || (support >= 3 && (rich > 0 || headings >= 2)) || (headings > 0 && rich >= 2)
                || (frontMatter && headings > 0)
        case .eager:
            result.sufficient = tables > 0 || codes > 0 || support >= 2
        }
        if headings + lists + codes + tables == 0 { result.sufficient = false }
        if top.allSatisfy({ $0.kind == "block_quote" }) { result.sufficient = false }
        if !ownsStart && top.contains(where: { $0.kind == "block_quote" })
            && !top.contains(where: { ["heading", "list", "code_block"].contains($0.kind) })
        {
            result.structures = 0
        }
        if let list = top.first, list.kind == "list", cmark_node_get_list_type(list.pointer) == CMARK_ORDERED_LIST,
            cmark_node_get_list_start(list.pointer) > 1 && rich == 0
        {
            result.structures = 0
        }
        if headings == 0 && tables == 0 && codes == 0 && lists == 0 && ClipboardSlice(window.bytes).contains("\\[") {
            result.structures = 1
        }
        result.evidence = [.headings(headings), .lists(lists), .codeBlocks(codes), .tables(tables), .links(links)]
        if !result.accepted { result.evidence.append(.conflictingSyntax) }
        return result
    }

    private static func markdownPossible(_ bytes: [UInt8], lines: [Range<Int>], work: inout ClipboardWork) -> Bool {
        var angle = false
        var address = false
        for b in bytes {
            work.visit()
            switch b {
            case 35, 42, 95, 91, 93, 124, 92: return true
            case 60: angle = true
            case 58, 64: address = true
            default: break
            }
        }
        // CommonMark autolinks require a scheme colon or an email address inside angle brackets.
        if angle && address { return true }
        for range in lines {
            var i = range.lowerBound
            while i < range.upperBound && (bytes[i] == 32 || bytes[i] == 9) {
                i += 1
                work.visit()
            }
            guard i < range.upperBound else { continue }
            let b = bytes[i]
            if b == 62 || (b == 43 && i + 1 == range.upperBound) { return true }
            if b == 45 || b == 61 || b == 43 {
                if (b == 45 || b == 43) && i + 1 < range.upperBound && (bytes[i + 1] == 32 || bytes[i + 1] == 9) {
                    return true
                }
                if b != 43 {
                    var j = i
                    while j < range.upperBound && (bytes[j] == b || bytes[j] == 32 || bytes[j] == 9) {
                        j += 1
                        work.visit()
                    }
                    if j == range.upperBound { return true }
                }
            }
            if (48...57).contains(b) {
                var j = i
                while j < range.upperBound && (48...57).contains(bytes[j]) {
                    j += 1
                    work.visit()
                }
                if j < range.upperBound && (bytes[j] == 46 || bytes[j] == 41) { return true }
            }
            if (b == 96 || b == 126) && i + 2 < range.upperBound && bytes[i + 1] == b && bytes[i + 2] == b {
                if b == 126 { return true }
                var j = i + 3
                while j < range.upperBound && bytes[j] == 96 {
                    j += 1
                    work.visit()
                }
                // A backtick in the info string disqualifies a backtick fence; inline code alone
                // contributes no document structure. Other lines and marks still participate.
                if !bytes[j..<range.upperBound].contains(96) { return true }
                work.visit(range.upperBound - j)
            }
        }
        return false
    }

    private static func excessiveNesting(_ bytes: [UInt8], work: inout ClipboardWork) -> Bool {
        // swift-markdown converts its C tree recursively. Refuse hostile depth before crossing that boundary.
        var brackets = 0
        var quotes = 0
        var run = 0
        var previous: UInt8 = 0
        var emphasisMarks = 0
        for byte in bytes {
            work.visit()
            if byte == 42 || byte == 95 { emphasisMarks += 1 }
            if byte == 91 || byte == 40 { brackets += 1 }
            if byte == 93 || byte == 41 { brackets = max(0, brackets - 1) }
            if byte == 62 { quotes += 1 }
            if byte == 10 { quotes = 0 }
            run = byte == previous ? run + 1 : 1
            previous = byte
            if emphasisMarks > 128 || brackets > 64 || quotes > 64 || (run > 128 && [42, 95].contains(byte)) {
                return true
            }
        }
        return false
    }

    private static func markdownCells(_ line: ClipboardSlice, work: inout ClipboardWork) -> [ClipboardSlice] {
        let value = line.trimmed
        let bytes = line.bytes
        var cells: [ClipboardSlice] = []
        var start = value.range.lowerBound + (value.first == 124 ? 1 : 0)
        var escaped = false
        for i in start..<value.range.upperBound {
            work.visit()
            if escaped {
                escaped = false
                continue
            }
            if bytes[i] == 92 {
                escaped = true
                continue
            }
            if bytes[i] == 124 {
                cells.append(ClipboardSlice(bytes, start..<i))
                start = i + 1
            }
        }
        if start < value.range.upperBound { cells.append(ClipboardSlice(bytes, start..<value.range.upperBound)) }
        return cells
    }

    private static func markdownOpaque(_ bytes: [UInt8], work: inout ClipboardWork, accepted: inout Bool) -> [UInt8] {
        var output = bytes
        var i = 0
        let comment = Array("<!--".utf8)
        let close = Array("-->".utf8)
        var math = false
        while i < bytes.count {
            work.visit()
            if bytes[i] == 60 && token(bytes, i, comment, work: &work) {
                let start = i
                i += 4
                var closed = false
                while i < bytes.count {
                    work.visit()
                    if bytes[i] == 45 && token(bytes, i, close, work: &work) {
                        i += 3
                        closed = true
                        break
                    }
                    i += 1
                }
                if !closed { accepted = false }
                for j in start..<i {
                    if output[j] != 10 { output[j] = 32 }
                    work.visit()
                }
                continue
            }
            if bytes[i] == 36 && i + 1 < bytes.count && bytes[i + 1] == 36 {
                math.toggle()
                output[i] = 32
                output[i + 1] = 32
                i += 2
                continue
            }
            if math && output[i] != 10 { output[i] = 32 }
            i += 1
        }
        if math { accepted = false }
        return output
    }
}

// The pointer is borrowed only during markdown(); its tree is freed before the call returns.
private struct ClipboardMarkdownNode {
    let pointer: UnsafeMutablePointer<cmark_node>
    let kind: String

    init(_ pointer: UnsafeMutablePointer<cmark_node>) {
        self.pointer = pointer
        kind = String(cString: cmark_node_get_type_string(pointer))
    }
}

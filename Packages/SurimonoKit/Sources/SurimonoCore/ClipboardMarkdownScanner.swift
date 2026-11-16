import Foundation
import Markdown

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
        var frontMatter = false
        if let first = window.lines.first, trimmed(window.string(first)) == "---" {
            for line in window.lines.dropFirst() {
                work.visit(line.count)
                if trimmed(window.string(line)) == "---" {
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
        let document = Document(parsing: String(decoding: source, as: UTF8.self))
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
        var nodes: [any Markup] = Array(document.children.reversed())
        func offset(_ location: SourceLocation) -> Int {
            guard location.line > 0 && location.line <= window.lines.count else { return source.count }
            return min(source.count, window.lines[location.line - 1].lowerBound + max(0, location.column - 1))
        }
        func span(_ node: any Markup) -> Range<Int>? {
            guard let range = node.range else { return nil }
            let lower = offset(range.lowerBound)
            let upper = offset(range.upperBound)
            return lower..<max(lower, upper)
        }
        func protect(_ range: Range<Int>) {
            hidden[range.lowerBound] += 1
            hidden[range.upperBound] -= 1
        }
        let top = Array(document.children)
        let firstContent = top.first { node in
            if let html = node as? HTMLBlock { return !trimmed(html.rawHTML).hasPrefix("<!--") }
            return true
        }
        if let first = firstContent {
            ownsStart =
                ownsStart || first is Heading || first is ListItemContainer || first is CodeBlock
                || first is BlockQuote || first is Table
            if let paragraph = first as? Paragraph, let inline = paragraph.child(at: 0) {
                ownsStart =
                    ownsStart || inline is Image || inline is Strong
                    || (inline is Link && inline.children.contains(where: { $0 is Image }))
            }
        }
        while let node = nodes.popLast() {
            work.visit()
            if node is Heading { headings += 1 }
            if let item = node as? ListItem {
                lists += 1
                if item.checkbox != nil { emphasis += 1 }
            }
            if node is BlockQuote { quotes += 1 }
            if node is Link || node is Image {
                links += 1
                if let range = span(node) { protect(range) }
            }
            if node is Strong || node is Emphasis || node is Strikethrough { emphasis += 1 }
            if let code = node as? CodeBlock {
                if let range = span(node) {
                    let opening =
                        window.string(range).split(separator: "\n", omittingEmptySubsequences: false).first.map(
                            String.init) ?? ""
                    let fence = trimmed(opening).drop { $0 == ">" || $0 == " " }
                    if fence.hasPrefix("```") || fence.hasPrefix("~~~") {
                        codes += 1
                        if trimmed(code.code).isEmpty { result.accepted = false }
                        let character = fence.first ?? "`"
                        let openingCount = fence.prefix { $0 == character }.count
                        let sourceLines = window.string(range).split(separator: "\n", omittingEmptySubsequences: true)
                        let closing = sourceLines.last.map { trimmed(String($0)).drop { $0 == ">" || $0 == " " } } ?? ""
                        let closingCount = closing.prefix { $0 == character }.count
                        work.visit(range.count)
                        if sourceLines.count < 2 || closingCount < openingCount
                            || !trimmed(String(closing.dropFirst(closingCount))).isEmpty
                        {
                            result.accepted = false
                        }
                    }
                }
                if let range = span(node) { protect(range) }
                continue
            }
            if node is InlineCode {
                inlineCodes += 1
                if let range = span(node) { protect(range) }
                continue
            }
            if node is Table, let range = node.range {
                let first = max(0, range.lowerBound.line - 1)
                let last = min(window.lines.count, range.upperBound.line)
                var columns: Int?
                var valid = true
                for index in first..<last {
                    let cells = markdownCells(window.string(window.lines[index]), work: &work)
                    if index == first { columns = cells.count }
                    if cells.count != columns { valid = false }
                    if index == first + 1 {
                        for cell in cells {
                            let value = trimmed(cell).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                            work.visit(value.utf8.count)
                            if value.isEmpty || !value.allSatisfy({ $0 == "-" }) { valid = false }
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
            if let html = node as? InlineHTML {
                if !safeInlineHTML(html.rawHTML, work: &work) { result.accepted = false }
            }
            nodes.append(contentsOf: node.children.reversed())
        }
        var depth = 0
        for i in source.indices {
            work.visit()
            depth += hidden[i]
            if depth > 0 && source[i] != 10 { source[i] = 32 }
        }
        var running = String(decoding: source, as: UTF8.self)
        // Display math and HTML comments are additional Surimono constructs, outside CommonMark's grammar.
        running = markdownOpaque(running, work: &work, accepted: &result.accepted)
        running = markdownHTML(running, work: &work, accepted: &result.accepted)
        if unsafeText(running, work: &work) { result.accepted = false }
        for range in window.lines {
            let line = trimmed(window.string(range))
            work.visit(range.count)
            if line.hasPrefix("#+") || line.contains("[[")
                || matches(line, #"^\*{2,}\s|^\*+\s+(TODO|DONE|NEXT|WAITING)\b|^(SCHEDULED|DEADLINE):"#, work: &work)
            {
                orgSyntax = true
            }
        }
        if headings > 0 {
            let lines = running.components(separatedBy: "\n")
            var commentPairs = 0
            for i in lines.indices where i + 1 < lines.count {
                work.visit()
                if trimmed(lines[i]).hasPrefix("# "), !trimmed(lines[i + 1]).isEmpty,
                    !trimmed(lines[i + 1]).hasPrefix("#") && !trimmed(lines[i + 1]).hasPrefix("-")
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
        let mathSupport = running.contains("$") && headings > 0 ? 2 : 0
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
        if top.allSatisfy({ $0 is BlockQuote }) { result.sufficient = false }
        if !ownsStart && top.contains(where: { $0 is BlockQuote })
            && !top.contains(where: { $0 is Heading || $0 is ListItemContainer || $0 is CodeBlock })
        {
            result.structures = 0
        }
        if let list = top.first as? OrderedList, list.startIndex > 1 && rich == 0 { result.structures = 0 }
        if headings == 0 && tables == 0 && codes == 0 && lists == 0 && window.text.contains("\\[") {
            result.structures = 1
        }
        result.evidence = [.headings(headings), .lists(lists), .codeBlocks(codes), .tables(tables), .links(links)]
        if !result.accepted { result.evidence.append(.conflictingSyntax) }
        return result
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

    private static func markdownCells(_ line: String, work: inout ClipboardWork) -> [String] {
        let bytes = Array(trimmed(line).utf8)
        var cells: [String] = []
        var start = bytes.first == 124 ? 1 : 0
        var escaped = false
        for i in start..<bytes.count {
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
                cells.append(String(decoding: bytes[start..<i], as: UTF8.self))
                start = i + 1
            }
        }
        if start < bytes.count { cells.append(String(decoding: bytes[start...], as: UTF8.self)) }
        return cells
    }

    private static func markdownOpaque(_ text: String, work: inout ClipboardWork, accepted: inout Bool) -> String {
        let bytes = Array(text.utf8)
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
        return String(decoding: output, as: UTF8.self)
    }
}

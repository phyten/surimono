import Foundation
import Markdown

// Both syntaxes share this mapping so print themes have only one set of classes to style.
enum MarkdownCallouts {
    struct Kind: Sendable {
        let name: String
        var style: String {
            switch name {
            case "note", "info", "todo", "abstract", "summary", "tldr", "message": "note"
            case "tip", "hint", "success", "check", "done": "tip"
            case "important", "example": "important"
            case "warning", "attention", "question", "help", "faq": "warning"
            case "caution", "danger", "error", "failure", "fail", "missing", "bug", "alert": "danger"
            case "quote", "cite": "quote"
            default: "neutral"
            }
        }
        var defaultTitle: String { name.prefix(1).uppercased() + name.dropFirst() }
        var opening: String { "<div class=\"callout callout-\(style)\" data-callout=\"\(HTML.escape(name))\">" }
        func title(_ html: String) -> String { html.isEmpty ? "" : "<p class=\"callout-title\">\(html)</p>" }
    }

    struct Marker: Sendable {
        let kind: Kind
        let consumed: Int
    }

    static func quoteMarker(_ text: String) -> Marker? {
        guard text.hasPrefix("[!"), let end = text.firstIndex(of: "]") else { return nil }
        let name = text[text.index(text.startIndex, offsetBy: 2)..<end]
        guard validName(name) else { return nil }
        var cursor = text.index(after: end)
        if cursor < text.endIndex, text[cursor] == "+" || text[cursor] == "-" { cursor = text.index(after: cursor) }
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" { cursor = text.index(after: cursor) }
        return Marker(kind: Kind(name: name.lowercased()), consumed: text.distance(from: text.startIndex, to: cursor))
    }

    static func preprocess(_ lines: [String]) -> String {
        preprocess(MarkdownSourceLines.unmapped(lines)).lines.joined(separator: "\n")
    }

    static func preprocess(_ mapped: MarkdownSourceLines) -> MarkdownSourceLines {
        let lines = mapped.lines
        var output = MarkdownSourceLines()
        var stack: [(length: Int, input: Int, output: Int)] = []
        let source = SourceContext(lines: lines)
        for (index, line) in lines.enumerated() {
            guard let content = source.lines[index].fenceContent(line) else {
                output.append(line, from: mapped.origins[index])
                continue
            }
            let length = content.prefix { $0 == ":" }.count
            let rest = content.dropFirst(length).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                if let open = stack.last, length >= open.length {
                    stack.removeLast()
                    if !mapped.origins[open.input].isEmpty {
                        output.origins[open.output] = mapped.origins[open.input...index].reduce(into: Set<Int>()) {
                            $0.formUnion($1)
                        }
                    }
                    output.append("\n</div>\n", from: [])
                } else {
                    output.append(line, from: mapped.origins[index])
                }
                continue
            }
            let name = rest.prefix { $0 != " " && $0 != "\t" }
            guard validName(name) else {
                output.append(line, from: mapped.origins[index])
                continue
            }
            var type = name.lowercased()
            var title = rest.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            let isMessage = type == "message"
            if isMessage, title.split(whereSeparator: \.isWhitespace).first?.lowercased() == "alert" {
                type = "alert"
                title = String(title.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            let kind = Kind(name: type)
            if !isMessage, title.isEmpty { title = kind.defaultTitle }
            let opening = output.lines.count + 1
            output.append("\n\(kind.opening)\n", from: mapped.origins[index])
            if !isMessage { output.append("\(kind.title(HTML.escape(title)))\n", from: mapped.origins[index]) }
            stack.append((length, index, opening))
        }
        // Close an unfinished code fence first so generated closing divs cannot become code text.
        if !stack.isEmpty, let closingFence = source.closingFence { output.append(closingFence, from: []) }
        for open in stack {
            if !mapped.origins[open.input].isEmpty {
                output.origins[open.output] = mapped.origins[open.input...].reduce(into: Set<Int>()) {
                    $0.formUnion($1)
                }
            }
            output.append("\n</div>\n", from: [])
        }
        return output
    }

    private struct LineContext: Sendable {
        var isBlock = false
        var isProtected = false
        var isQuoted = false
        var listBodyColumn: Int?

        func fenceContent(_ line: String) -> Substring? {
            let indentation = line.prefix { $0 == " " }.count
            let content = line.dropFirst(indentation)
            // Lazy continuations may be interrupted, but indented list bodies and explicit quotes may not.
            guard isBlock, !isProtected, indentation <= 3,
                listBodyColumn.map({ indentation + 1 < $0 }) ?? true,
                !(isQuoted && content.hasPrefix(">")), content.hasPrefix(":::")
            else { return nil }
            return content
        }
    }

    private struct SourceContext: Sendable {
        var lines: [LineContext]
        var closingFence: String?
        let lastContentLine: Int?

        init(lines sourceLines: [String]) {
            lines = Array(repeating: LineContext(), count: sourceLines.count)
            lastContentLine = sourceLines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let document = Document(parsing: sourceLines.joined(separator: "\n"), options: [.disableSmartOpts])
            var cursor = 0
            for block in document.children {
                cursor = visit(block, sourceLines: sourceLines, bounds: cursor..<lines.count)
            }
        }

        private mutating func visit(
            _ block: any Markup, sourceLines: [String], bounds: Range<Int>, context: LineContext = LineContext()
        ) -> Int {
            guard block is any BlockMarkup, let range = block.range else { return bounds.lowerBound }
            // cmark can report an unterminated code block past its containing list's end.
            let start = max(bounds.lowerBound, range.lowerBound.line - 1)
            let end = min(bounds.upperBound, range.upperBound.line - (range.upperBound.column == 1 ? 1 : 0))
            guard start < end else { return bounds.lowerBound }
            for index in bounds.lowerBound..<start { lines[index] = context }
            var context = context
            context.isBlock = true
            if block is CodeBlock || block is HTMLBlock { context.isProtected = true }
            if block is BlockQuote { context.isQuoted = true }
            if block is ListItem {
                context.listBodyColumn = columnAfterMarker(sourceLines[start], column: range.lowerBound.column)
            }
            if block is CodeBlock, let lastContentLine, end > lastContentLine {
                closingFence = terminalFence(range, sourceLines: sourceLines)
            }
            // Fill disjoint ranges so nesting does not repeatedly scan the same lines.
            var cursor = start
            for child in block.children {
                cursor = visit(child, sourceLines: sourceLines, bounds: cursor..<end, context: context)
            }
            for index in cursor..<end { lines[index] = context }
            return end
        }

        private func columnAfterMarker(_ line: String, column: Int) -> Int {
            let bytes = Array(line.utf8)
            let markerWidth = bytes.dropFirst(column - 1).prefix { $0 != 32 && $0 != 9 }.count
            let markerEnd = column - 1 + markerWidth
            func advance(_ position: Int, byte: UInt8) -> Int {
                position + (byte == 9 ? 4 - position % 4 : 1)
            }
            let markerColumn = bytes[..<markerEnd].reduce(0) { advance($0, byte: $1) }
            var position = markerColumn
            var index = markerEnd
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 {
                position = advance(position, byte: bytes[index])
                index += 1
            }
            let spaces = position - markerColumn
            // CommonMark rules 2 and 3 reserve one column for code-first or initially empty items.
            let padding = index == bytes.count || spaces >= 5 ? 1 : spaces
            return markerColumn + padding + 1
        }

        private func terminalFence(_ range: SourceRange, sourceLines: [String]) -> String? {
            guard let last = lastContentLine else { return nil }
            let start = range.lowerBound.line - 1
            let prefix = sourceLines[start].utf8.prefix(range.lowerBound.column - 1)
            // Unprefixed closing HTML already exits a list or quote; only a standalone fence can swallow it.
            guard prefix.count <= 3, prefix.allSatisfy({ $0 == 32 }) else { return nil }
            let opening = String(decoding: sourceLines[start].utf8.dropFirst(prefix.count), as: UTF8.self)
            guard let character = opening.first, character == "`" || character == "~" else { return nil }
            let count = opening.prefix { $0 == character }.count
            guard count >= 3 else { return nil }
            let lastIndent = sourceLines[last].prefix { $0 == " " }.count
            let ending = sourceLines[last].dropFirst(lastIndent)
            let endingCount = ending.prefix { $0 == character }.count
            if last > start, lastIndent <= 3, endingCount >= count,
                ending.dropFirst(endingCount).allSatisfy({ $0 == " " || $0 == "\t" })
            {
                return nil
            }
            return String(repeating: " ", count: prefix.count) + String(repeating: String(character), count: count)
        }
    }

    private static func validName(_ name: Substring) -> Bool {
        guard let first = name.unicodeScalars.first, (65...90).contains(first.value) || (97...122).contains(first.value)
        else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
    }
}

import Foundation
import Markdown

// Both syntaxes share this mapping so print themes have only one set of classes to style.
enum MarkdownCallouts {
    struct Kind: Sendable {
        let name: String

        /// The name this one is another spelling of; nil for a name Surimono does not know.
        var canonicalName: String? {
            switch name {
            case "note", "abstract", "summary", "tldr", "message": "note"
            case "info": "info"
            case "todo": "todo"
            case "example": "example"
            case "tip", "hint": "tip"
            case "success", "check", "done": "success"
            case "important": "important"
            case "warning", "attention": "warning"
            case "question", "help", "faq": "question"
            case "danger", "caution", "error", "failure", "fail", "missing", "alert": "danger"
            case "bug": "bug"
            case "quote", "cite": "quote"
            case "neutral", "details": "neutral"
            default: nil
            }
        }

        /// The class of the kind's meaning: information, success, care and danger each share a colour and a line, so a
        /// print theme styles six classes however many names there are. The class names predate the groups; a user's
        /// CSS keeps working on them.
        var style: String {
            switch canonicalName {
            case "note", "info", "todo", "example": "note"
            case "tip", "success": "tip"
            case "important", "warning", "question": "warning"
            case "danger", "bug": "danger"
            case "quote": "quote"
            default: "neutral"
            }
        }

        var defaultTitle: String { name.prefix(1).uppercased() + name.dropFirst() }

        var opening: String {
            let unknown = canonicalName == nil ? " callout-unknown" : ""
            return "<div class=\"callout\(unknown) callout-\(style)\" data-callout=\"\(HTML.escape(name))\">"
        }

        func title(_ html: String) -> String {
            "<p class=\"callout-title\">\(icon)\(html)\(nameTag(title: html))</p>"
        }

        /// Inline rather than a CSS image, so the mark takes the colour of the tag it sits on: `currentColor` does not
        /// reach into an image, and each theme chooses its own tag colours.
        private var icon: String {
            guard let canonicalName, let path = Self.iconPaths[canonicalName] else { return "" }
            return "<svg class=\"callout-icon\" viewBox=\"0 0 16 16\" aria-hidden=\"true\"><path d=\"\(path)\"/></svg>"
        }

        /// An unknown name has no colour or icon of its own, so its name is what tells it from a plain callout.
        private func nameTag(title: String) -> String {
            guard canonicalName == nil, title.lowercased() != name else { return "" }
            return "<span class=\"callout-name\">\(HTML.escape(name))</span>"
        }

        private static let iconPaths: [String: String] = [
            "note": "M3 13l.6-2.6 6.8-6.8a1.1 1.1 0 0 1 1.6 0l.4.4a1.1 1.1 0 0 1 0 1.6l-6.8 6.8z M9.4 4.6l2 2",
            "info": "M8 14.2A6.2 6.2 0 1 0 8 1.8a6.2 6.2 0 0 0 0 12.4z M8 7.4v4 M8 4.8v.4",
            "tip": "M8 1.8a4.4 4.4 0 0 0-2.6 8c.5.4.8 1 .8 1.6h3.6c0-.6.3-1.2.8-1.6A4.4 4.4 0 0 0 8 1.8z M6.4 13.8h3.2",
            "success": "M8 14.2A6.2 6.2 0 1 0 8 1.8a6.2 6.2 0 0 0 0 12.4z M5.2 8.2l2 2 3.6-4.2",
            "important": "M4 14.4V2 M4 2.6h7.8l-1.8 2.8 1.8 2.8H4",
            "example": "M3.6 1.8h6l2.8 2.8v9.6H3.6z M9.6 1.8v2.8h2.8 M5.8 8h4.4 M5.8 10.6h4.4",
            "warning": "M8 2.2l6.4 11.4H1.6z M8 6.4v3.6 M8 11.6v.3",
            "question":
                "M8 14.2A6.2 6.2 0 1 0 8 1.8a6.2 6.2 0 0 0 0 12.4z M6 6.2a2 2 0 1 1 3 1.8c-.7.4-1 .9-1 1.6 M8 11.6v.3",
            "danger": "M5.4 1.8h5.2l3.6 3.6v5.2l-3.6 3.6H5.4l-3.6-3.6V5.4z M5.8 5.8l4.4 4.4 M10.2 5.8l-4.4 4.4",
            "bug":
                "M5.2 6.2a2.8 2.8 0 0 1 5.6 0v4a2.8 2.8 0 0 1-5.6 0z M5.2 8H2.4 M13.6 8h-2.8 M5.6 5L3.4 3.4 "
                + "M10.4 5l2.2-1.6 M5.6 11l-2.2 1.6 M10.4 11l2.2 1.6 M8 6v7",
            "quote": "M3 8.6c0-2.6 1.2-4 3.2-4.6 M3 8.6h2.8v3H3z M9 8.6c0-2.6 1.2-4 3.2-4.6 M9 8.6h2.8v3H9z",
            "todo": "M2.6 2.6h10.8v10.8H2.6z M5.2 8.2l2 2 3.6-4.2",
            "neutral": "M2.4 2.4h5.4l5.8 5.8-5.4 5.4-5.8-5.8z M5.2 5.2v.1",
        ]
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
            if type == "message", title.split(whereSeparator: \.isWhitespace).first?.lowercased() == "alert" {
                type = "alert"
                title = String(title.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            let kind = Kind(name: type)
            if title.isEmpty { title = kind.defaultTitle }
            let opening = output.lines.count + 1
            output.append("\n\(kind.opening)\n", from: mapped.origins[index])
            output.append("\(kind.title(HTML.escape(title)))\n", from: mapped.origins[index])
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

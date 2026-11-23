import Foundation

/// Compares the blocks the converters actually put on paper. Indices refer to the new fragment.
public enum FragmentChanges {
    private static let byteLimit = 8_000_000
    private static let blockLimit = 10_000
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]
    private static let hidden: Set<String> = ["style", "script", "link", "meta", "title", "colgroup", "col"]

    private static let containers: Set<String> = [
        "section", "div", "blockquote", "figure", "details", "header", "article", "main",
        "ul", "ol", "table", "thead", "tbody", "tfoot", "dl",
    ]
    private static let inline: Set<String> = [
        "a", "b", "br", "code", "em", "i", "mark", "small", "span", "strong", "sub", "sup", "u", "ruby",
    ]
    private static let plainOpen = "<pre class=\"surimono-plain\">"

    private struct Part {
        var range: Range<Int>
        var wrapsText = false
    }
    private typealias Block = [Part]

    /// Both diffing and placing the IDs use the same scanner so comments, quoted attributes and nested tables
    /// cannot shift a request onto a later paragraph.
    private static func blocks(in tokens: [HTMLScanner.Token]) -> [Block]? {
        var ends: [Int: Int] = [:]
        var stack: [Int] = []
        for (index, token) in tokens.enumerated() {
            guard case .tag(let tag) = token else { continue }
            if tag.isClosing {
                guard let start = stack.popLast(), case .tag(let opening) = tokens[start], opening.name == tag.name
                else { return nil }
                ends[start] = index + 1
            } else if !tag.isSelfClosing, !voidElements.contains(tag.name) {
                guard stack.count < 128 else { return nil }
                stack.append(index)
            }
        }

        guard stack.isEmpty else { return nil }
        var result: [Block] = []
        func visit(_ range: Range<Int>) {
            var index = range.lowerBound
            var inlineStart = index
            var definition: Int?
            func flushInline() {
                guard inlineStart < index else { return }
                let part = inlineStart..<index
                if tokens[part].contains(where: {
                    if case .text(let text) = $0 { return text.contains { !$0.isWhitespace } }
                    if case .tag(let tag) = $0 { return ["img", "svg", "br"].contains(tag.name) }
                    return false
                }) {
                    result.append([Part(range: part, wrapsText: true)])
                }
            }
            while index < range.upperBound, result.count <= blockLimit {
                let start = index
                let end = min(ends[start] ?? (start + 1), range.upperBound)
                guard case .tag(let tag) = tokens[start], !tag.isClosing, !inline.contains(tag.name) else {
                    index = end
                    continue
                }
                flushInline()
                index = end
                inlineStart = end
                if tag.name != "dd" { definition = nil }
                guard !hidden.contains(tag.name) else { continue }
                let part = Part(range: start..<end)
                let content = (start + 1)..<max(start + 1, end - 1)
                let math = tag.attribute("class")?.split(separator: " ").contains("math-block") == true
                if tag.name == "dd", let definition {
                    result[definition].append(part)
                } else if tag.name == "li" {
                    // The parent's own text and its nested list have independent changes.
                    let nested = tokens[content].contains {
                        if case .tag(let child) = $0 {
                            return !child.isClosing && (child.name == "ul" || child.name == "ol")
                        }
                        return false
                    }
                    if nested { visit(content) } else { result.append([part]) }
                } else if containers.contains(tag.name), !math {
                    visit(content)
                } else {
                    if tag.name == "dt" { definition = result.count }
                    result.append([part])
                }
            }
            flushInline()
        }
        visit(tokens.indices)
        return result.count <= blockLimit ? result : nil
    }

    private static func source(_ token: HTMLScanner.Token) -> String {
        switch token {
        case .tag(let tag): tag.source
        case .opaque(let text), .text(let text): text
        }
    }

    /// The lines of plain text as they stand in the HTML, and the text of each to compare.
    private struct PlainLines {
        var html: [String] = []
        var text: [String] = []
    }

    private enum PlainText {
        /// Not the one block of plain text; the blocks of the HTML are compared.
        case other
        /// More lines than are compared. Nothing is marked: the whole text is never one change.
        case tooLong
        case lines(PlainLines)
    }

    /// One reading for text with and without colors: a line break ends a line wherever it stands, also inside a
    /// span, so the last line is empty when the text ends with a line break and joining the lines gives the text
    /// back. A span that runs over several lines is closed and opened again on each, so a line inside a long comment
    /// can be marked alone. The text is compared without the spans, because an edit elsewhere (opening a comment)
    /// recolors lines it did not change.
    ///
    /// The text is read by Unicode scalar: a combining mark that follows a tag would join its `>` into one
    /// character and hide the end of the tag. `visited` counts the scalars read, for the test that the reading
    /// stops at the limit.
    private static func plainText(_ html: String, visited: inout Int) -> PlainText {
        guard html.hasPrefix(plainOpen), html.hasSuffix("</pre>") else { return .other }
        let body = html.unicodeScalars.dropFirst(plainOpen.unicodeScalars.count).dropLast(6)
        var lines = PlainLines()
        var current: [Unicode.Scalar] = []
        var text = String.UnicodeScalarView()
        var open: [String.UnicodeScalarView] = []
        let close = "</span>".unicodeScalars
        let colored = Array("<span class=\"hl-".unicodeScalars)
        var index = body.startIndex
        while index < body.endIndex {
            let scalar = body[index]
            visited += 1
            if scalar == "<" {
                guard let end = body[index...].firstIndex(of: ">") else { return .other }
                let tag = String.UnicodeScalarView(body[index...end])
                visited += tag.count - 1
                if tag.elementsEqual(close) {
                    guard let last = open.popLast() else { return .other }
                    // A span that ended where the line began holds nothing on this line.
                    if current.count >= last.count, current.suffix(last.count).elementsEqual(last) {
                        current.removeLast(last.count)
                    } else {
                        current.append(contentsOf: tag)
                    }
                } else if tag.starts(with: colored) {
                    open.append(tag)
                    current.append(contentsOf: tag)
                } else {
                    return .other
                }
                index = body.index(after: end)
                continue
            }
            let next = body.index(after: index)
            if scalar == "\n" || scalar == "\r" {
                // This line and the one that follows the break, even an empty one, are one more than the lines
                // read so far. Past the limit nothing is compared, so nothing after this break is read.
                guard lines.text.count + 2 <= blockLimit else { return .tooLong }
                for _ in open { current.append(contentsOf: close) }
                lines.html.append(text.isEmpty ? "" : String(String.UnicodeScalarView(current)))
                lines.text.append(String(text))
                current.removeAll(keepingCapacity: true)
                for tag in open { current.append(contentsOf: tag) }
                text = String.UnicodeScalarView()
                // A carriage return and the line feed after it are one break.
                index = scalar == "\r" && next < body.endIndex && body[next] == "\n" ? body.index(after: next) : next
                if index != next { visited += 1 }
                continue
            }
            current.append(scalar)
            text.append(scalar)
            index = next
        }
        guard open.isEmpty else { return .other }
        lines.html.append(text.isEmpty ? "" : String(String.UnicodeScalarView(current)))
        lines.text.append(String(text))
        return .lines(lines)
    }

    private static func keys(_ html: String) -> [String]? {
        let tokens = HTMLScanner.tokens(html)
        return blocks(in: tokens)?.map { block in
            var result = ""
            var preformatted = false
            for part in block {
                for token in tokens[part.range] {
                    switch token {
                    case .tag(let tag) where tag.name == "pre":
                        preformatted = !tag.isClosing
                        result += tag.source
                    case .text(let text) where !preformatted:
                        var space = false
                        for char in text {
                            if !char.isWhitespace || !space { result.append(char.isWhitespace ? " " : char) }
                            space = char.isWhitespace
                        }
                    default: result += source(token)
                    }
                }
            }
            return result
        }
    }

    public static func marks(from old: String, to new: String) -> [MarkdownMarkRequest] {
        var visited = 0
        return marks(from: old, to: new, visited: &visited)
    }

    /// `visited` is how much of the two texts was read as lines of plain text, in Unicode scalars.
    package static func marks(from old: String, to new: String, visited: inout Int) -> [MarkdownMarkRequest] {
        guard old.utf8.count <= byteLimit, new.utf8.count <= byteLimit, old != new else { return [] }
        // The new text first: when it has too many lines there are no marks, and the old one is not split at all.
        let after = plainText(new, visited: &visited)
        if case .tooLong = after { return [] }
        let before = plainText(old, visited: &visited)
        switch (before, after) {
        case (.lines(let before), .lines(let after)):
            if after.text.count == 1, after.text[0].isEmpty { return [] }
            return changes(before.text, after.text, groupsLines: true)
        case (.tooLong, _): return []
        default: break
        }
        guard let before = keys(old), let after = keys(new) else { return [] }
        return changes(before, after, groupsLines: false)
    }

    private static func changes(_ before: [String], _ after: [String], groupsLines: Bool) -> [MarkdownMarkRequest] {
        guard !after.isEmpty, max(before.count, after.count) <= blockLimit else { return [] }
        var prefix = 0
        var endOld = before.count
        var endNew = after.count
        while prefix < min(endOld, endNew), before[prefix] == after[prefix] { prefix += 1 }
        while endOld > prefix, endNew > prefix, before[endOld - 1] == after[endNew - 1] {
            endOld -= 1
            endNew -= 1
        }
        func request(_ first: Int, through last: Int, short: Bool = false, atEnd: Bool = false) -> MarkdownMarkRequest {
            MarkdownMarkRequest(
                blockID: groupsLines ? "lines-\(first)-\(last)" : "fragment-\(first)", isShort: short, afterBlock: atEnd
            )
        }
        if prefix == endOld {
            if groupsLines, prefix < endNew { return [request(prefix, through: endNew - 1)] }
            return (prefix..<endNew).map { request($0, through: $0) }
        }
        if prefix == endNew {
            let neighbor = min(prefix, after.count - 1)
            return [request(neighbor, through: neighbor, short: true, atEnd: prefix == after.count)]
        }

        // Only the unmatched middle costs LCS cells. Intern whole blocks so each cell compares constant-size keys.
        guard endOld - prefix + 1 <= 1_000_000 / (endNew - prefix + 1) else { return [] }
        var symbols: [String: Int] = [:]
        func lines(_ blocks: ArraySlice<String>) -> String {
            blocks.map { block in
                if let id = symbols[block] { return String(id) }
                let id = symbols.count
                symbols[block] = id
                return String(id)
            }.joined(separator: "\n")
        }
        guard let diff = MarkdownChanges.lines(from: lines(before[prefix..<endOld]), to: lines(after[prefix..<endNew]))
        else { return [] }
        var selected: [Int: Bool] = [:]
        for line in diff.deletions where !diff.inserted.contains(line) && !diff.inserted.contains(line - 1) {
            selected[min(prefix + line - 1, after.count - 1)] = true
        }
        for line in diff.inserted { selected[prefix + line - 1] = false }
        let indices = selected.keys.sorted()
        var requests: [MarkdownMarkRequest] = []
        var i = 0
        while i < indices.count {
            let first = indices[i]
            var last = first
            let short = selected[first] == true
            if groupsLines && !short {
                while i + 1 < indices.count, indices[i + 1] == last + 1, selected[last + 1] == false {
                    i += 1
                    last += 1
                }
            }
            let atEnd = short && first == after.count - 1 && diff.deletions.contains(after.count - prefix + 1)
            requests.append(request(first, through: last, short: short, atEnd: atEnd))
            i += 1
        }
        return requests
    }

    /// Only the disposable layout needs IDs; leave the normal HTML byte-for-byte as the converter produced it.
    public static func identifyingBlocks(in html: String, for requests: [MarkdownMarkRequest]) -> String {
        guard !requests.isEmpty, html.utf8.count <= byteLimit else { return html }
        var visited = 0
        let plain = plainText(html, visited: &visited)
        if case .tooLong = plain { return html }
        if case .lines(let plain) = plain {
            var lines = plain.html
            // Each line keeps its original newline. Measuring an inline span follows even a wrapped line onto paper.
            for request in requests {
                let parts = request.blockID.split(separator: "-")
                guard parts.count == 3, parts[0] == "lines", let first = Int(parts[1]), let last = Int(parts[2]),
                    first >= 0, first <= last, last < lines.count
                else { continue }
                for index in first...last {
                    // HTML discards the first newline of a pre. A span in front of it would add a printed line.
                    if index == 0 && lines[index].isEmpty { continue }
                    lines[index] = "<span data-surimono-block=\"lines-\(first)-\(last)\">" + lines[index] + "</span>"
                }
            }
            return plainOpen + lines.joined(separator: "\n") + "</pre>"
        }
        let wanted = Set(requests.map(\.blockID))
        let tokens = HTMLScanner.tokens(html)
        guard let blocks = blocks(in: tokens) else { return html }
        var pieces = tokens.map(source)
        for (index, block) in blocks.enumerated() {
            let id = "fragment-\(index)"
            guard wanted.contains(id) else { continue }
            for part in block {
                let first = part.range.lowerBound
                let attribute = " data-surimono-block=\"\(id)\""
                if part.wrapsText {
                    pieces[first] = "<span\(attribute)>" + pieces[first]
                    pieces[part.range.upperBound - 1] += "</span>"
                } else if case .tag(let tag) = tokens[first] {
                    let end = tag.source.index(tag.source.endIndex, offsetBy: tag.isSelfClosing ? -2 : -1)
                    pieces[first].insert(contentsOf: attribute, at: end)
                }
            }
        }
        return pieces.joined()
    }
}

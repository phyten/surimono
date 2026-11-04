import Foundation

public struct DocumentHeading: Equatable, Sendable {
    public var level: Int
    public var text: String
    /// The heading's anchor, when the converter gave it one.
    public var id: String?

    public init(level: Int, text: String, id: String? = nil) {
        self.level = level
        self.text = text
        self.id = id
    }
}

/// Reads the structure of a document's HTML: the headings for tables of contents and the amount of text.
public enum DocumentOutline {
    private static let hiddenElements: Set<String> = ["rt", "rp", "svg", "math"]

    public static func headings(inHTML html: String) -> [DocumentHeading] {
        var headings: [DocumentHeading] = []
        var open: (tag: HTMLScanner.Tag, level: Int, text: String)?
        var hidden: (name: String, depth: Int)?
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .text(let text):
                if hidden == nil { open?.text += text }
            case .opaque: break
            case .tag(let tag):
                if updateHidden(&hidden, with: tag) { continue }
                if let current = open {
                    guard tag.isClosing, tag.name == current.tag.name else { continue }
                    let text = HTMLScanner.decodingEntities(current.text).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        headings.append(
                            DocumentHeading(level: current.level, text: text, id: current.tag.attribute("id")))
                    }
                    open = nil
                } else if !tag.isClosing, let level = headingLevel(tag.name) {
                    open = (tag, level, "")
                }
            }
        }
        return headings
    }

    /// The zero-based page each heading stands on, in order. A heading stands on lines of its own, wrapped or with a
    /// number in front of it, so the same words in a sentence do not count. The search only moves forward, past each
    /// heading it found, and the lines are indexed so that headings it cannot find do not rescan the document.
    public static func pages(of headings: [DocumentHeading], inPageTexts pages: [String]) -> [Int?] {
        var lines: [(page: Int, text: String)] = []
        for (page, text) in pages.enumerated() {
            for line in text.components(separatedBy: .newlines) {
                let normalized = withoutNumbering(normalized(line))
                if !normalized.isEmpty { lines.append((page, normalized)) }
            }
        }
        var starts: [Character: [Int]] = [:]
        for (index, line) in lines.enumerated() {
            if let first = line.text.first { starts[first, default: []].append(index) }
        }
        var cursor = 0
        return headings.map { heading in
            let target = withoutNumbering(normalized(heading.text))
            guard let first = target.first, let candidates = starts[first] else { return nil }
            for index in candidates[firstIndex(in: candidates, atLeast: cursor)...] {
                guard let end = endOfHeading(target, in: lines, from: index) else { continue }
                cursor = end
                return lines[index].page
            }
            return nil
        }
    }

    private static func headingLevel(_ name: String) -> Int? {
        guard name.count == 2, name.first == "h", let level = name.last?.wholeNumberValue, (1...6).contains(level)
        else { return nil }
        return level
    }

    /// Whether the tag belongs to an element whose text is not read, keeping track of the one being skipped.
    private static func updateHidden(_ hidden: inout (name: String, depth: Int)?, with tag: HTMLScanner.Tag) -> Bool {
        if let current = hidden {
            if tag.name == current.name, !tag.isSelfClosing {
                let depth = current.depth + (tag.isClosing ? -1 : 1)
                hidden = depth == 0 ? nil : (current.name, depth)
            }
            return true
        }
        guard hiddenElements.contains(tag.name), !tag.isClosing, !tag.isSelfClosing else { return false }
        hidden = (tag.name, 1)
        return true
    }

    private static func firstIndex(in sorted: [Int], atLeast value: Int) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The index after the last line of the heading, when one starts at `start`. It stays on one page.
    private static func endOfHeading(
        _ target: String, in lines: [(page: Int, text: String)], from start: Int
    ) -> Int? {
        var joined = ""
        var index = start
        while index < lines.count, lines[index].page == lines[start].page {
            joined += lines[index].text
            index += 1
            if joined == target { return index }
            guard target.hasPrefix(joined) else { return nil }
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// A theme can number a heading with a counter, which puts text in front of it on the page only.
    private static func withoutNumbering(_ text: String) -> String {
        let stripped = text.drop { $0.isNumber || ".．、:：-–—)）(（".contains($0) }
        return stripped.isEmpty ? text : String(stripped)
    }

    static func plainText(ofHTML html: String) -> String {
        var text = ""
        var hidden: (name: String, depth: Int)?
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .text(let value):
                if hidden == nil { text += value }
            case .opaque: break
            case .tag(let tag): _ = updateHidden(&hidden, with: tag)
            }
        }
        return HTMLScanner.decodingEntities(text)
    }
}

/// What the reader may want to know before printing: an amount of text that also makes sense for Japanese.
public struct DocumentStatistics: Equatable, Sendable {
    /// Characters of text, without white space.
    public var characters: Int

    /// Silent reading of Japanese is commonly put at around 500 characters a minute.
    public var readingMinutes: Int { characters == 0 ? 0 : max(1, Int((Double(characters) / 500).rounded())) }

    public init(characters: Int) { self.characters = characters }

    public init(html: String) {
        characters = DocumentOutline.plainText(ofHTML: html).unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
        }
    }
}

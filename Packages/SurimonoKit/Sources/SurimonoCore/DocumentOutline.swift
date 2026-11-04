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
    /// heading it found. The lines are indexed by their text, so a heading that cannot be found costs one lookup.
    public static func pages(of headings: [DocumentHeading], inPageTexts pages: [String]) -> [Int?] {
        let index = LineIndex(pages: pages)
        var cursor = 0
        return headings.map { heading in
            let target = normalized(heading.text)
            guard !target.isEmpty, let match = index.firstMatch(of: target, from: cursor) else { return nil }
            cursor = match.end
            return match.page
        }
    }

    private struct LineIndex {
        /// A heading wraps only when it is long, so a wrapped one shares at least this much with its first line.
        private static let wrappedPrefixLength = 6

        private var lines: [(page: Int, forms: [String])] = []
        private var whole: [String: [Int]] = [:]
        private var wrapped: [String: [Int]] = [:]

        init(pages: [String]) {
            for (page, text) in pages.enumerated() {
                for line in text.components(separatedBy: .newlines) {
                    let forms = Self.forms(of: line)
                    guard let first = forms.first, !first.isEmpty else { continue }
                    for form in forms {
                        whole[form, default: []].append(lines.count)
                        if form.count >= Self.wrappedPrefixLength {
                            wrapped[String(form.prefix(Self.wrappedPrefixLength)), default: []].append(lines.count)
                        }
                    }
                    lines.append((page, forms))
                }
            }
        }

        func firstMatch(of target: String, from cursor: Int) -> (page: Int, end: Int)? {
            var best: (page: Int, end: Int, start: Int)?
            if let start = Self.first(in: whole[target] ?? [], atLeast: cursor) {
                best = (lines[start].page, start + 1, start)
            }
            guard target.count > Self.wrappedPrefixLength else { return best.map { ($0.page, $0.end) } }
            let candidates = wrapped[String(target.prefix(Self.wrappedPrefixLength))] ?? []
            var position = Self.firstPosition(in: candidates, atLeast: cursor)
            while position < candidates.count, candidates[position] < best?.start ?? .max {
                let start = candidates[position]
                if let end = endOfWrappedHeading(target, from: start) {
                    best = (lines[start].page, end, start)
                    break
                }
                position += 1
            }
            return best.map { ($0.page, $0.end) }
        }

        /// The index after the last line of a heading that wraps from `start`. It stays on one page.
        private func endOfWrappedHeading(_ target: String, from start: Int) -> Int? {
            for form in lines[start].forms where target.hasPrefix(form) {
                var joined = form
                var index = start + 1
                while index < lines.count, lines[index].page == lines[start].page {
                    joined += lines[index].forms[0]
                    index += 1
                    if joined == target { return index }
                    guard target.hasPrefix(joined) else { break }
                }
            }
            return nil
        }

        /// The line as it stands, and without a number when it has one: a theme can number a heading with a counter,
        /// which puts text in front of it on the page only.
        private static func forms(of line: String) -> [String] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let number = trimmed.prefix { $0.isNumber || ".．、:：-)）(（".contains($0) }
            let rest = trimmed.dropFirst(number.count)
            let endsNumber = rest.first?.isWhitespace == true || number.last.map { !$0.isNumber } == true
            guard !number.isEmpty, !rest.isEmpty, endsNumber else { return [normalized(line)] }
            return [normalized(line), normalized(String(rest))]
        }

        private static func first(in sorted: [Int], atLeast value: Int) -> Int? {
            let position = firstPosition(in: sorted, atLeast: value)
            return position < sorted.count ? sorted[position] : nil
        }

        private static func firstPosition(in sorted: [Int], atLeast value: Int) -> Int {
            var low = 0
            var high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if sorted[middle] < value { low = middle + 1 } else { high = middle }
            }
            return low
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

    private static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
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

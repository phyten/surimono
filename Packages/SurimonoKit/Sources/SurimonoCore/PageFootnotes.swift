import Foundation

public enum FootnotePlacement: String, Codable, CaseIterable, Sendable {
    case end, pageBottom
}

/// A disposable print fragment. All offsets address tokens of the original fragment, never the source file.
public enum PageFootnotes {
    public struct Reference: Sendable {
        public let index: Int
        public let note: Int
        public let eligible: Bool
        fileprivate let end: Int
    }

    public struct Group: Sendable {
        public let firstReference: Int
        public let notes: [Int]
        public let heightPixels: Int

        public init(firstReference: Int, notes: [Int], heightPixels: Int) {
            self.firstReference = firstReference
            self.notes = notes
            self.heightPixels = heightPixels
        }
    }

    fileprivate struct Note: Sendable {
        let number: Int
        let inner: String
        /// The change-mark id of the definition, so a moved or rebuilt note keeps its mark.
        let blockID: String?

        var blockAttribute: String {
            blockID.map { " data-surimono-block=\"\(HTML.escape($0))\"" } ?? ""
        }
    }

    /// Numeric IDs can be measured and moved. Other notes keep their original list item, in document order.
    fileprivate enum Endnote: Sendable {
        case numbered(index: Int)
        case original(Range<Int>)
    }

    public struct Plan: Sendable {
        public let references: [Reference]
        public var eligibleNotes: Set<Int> { Set(references.filter(\.eligible).map(\.note)) }
        /// The order in which stock rectangles must be found, even when some notes stay at the end.
        public func stockNumbers(placing: Set<Int>) -> [Int] {
            notes.filter { placing.contains($0.number) }.map(\.number)
        }

        fileprivate let tokens: [String]
        fileprivate let section: Range<Int>
        fileprivate let notes: [Note]
        fileprivate let endnoteOrder: [Endnote]

        public func measuringHTML(placing: Set<Int>) -> String { html(placing: placing, groups: []) }

        public func reservingHTML(groups: [Group]) -> String {
            html(placing: Set(groups.flatMap(\.notes)), groups: groups)
        }

        private func html(placing: Set<Int>, groups: [Group]) -> String {
            let placing = placing.intersection(eligibleNotes)
            let remaining = endnoteOrder.compactMap { entry -> String? in
                switch entry {
                case .original(let range):
                    return tokens[range].joined()
                case .numbered(let index):
                    let note = notes[index]
                    guard !placing.contains(note.number) else { return nil }
                    return "<li id=\"fn-\(note.number)\" value=\"\(note.number)\"\(note.blockAttribute)>"
                        + "\(note.inner)</li>"
                }
            }.joined()
            let endnotes = remaining.isEmpty ? "" : "<section class=\"footnotes\"><ol>\(remaining)</ol></section>"
            var insertions: [Int: String] = [:]
            for group in groups {
                guard let reference = references.first(where: { $0.index == group.firstReference && $0.eligible }),
                    let note = group.notes.first, group.heightPixels > 0
                else { continue }
                insertions[reference.end, default: ""] +=
                    "<span class=\"paper-footnote-room\" style=\"height:\(group.heightPixels)px\">"
                    + "<a class=\"paper-footnote-mark\" href=\"#fn-\(note)\"></a></span>"
            }
            var body = ""
            for index in tokens.indices {
                if index == section.lowerBound { body += endnotes }
                if !section.contains(index) { body += tokens[index] }
                body += insertions[index] ?? ""
            }
            let stock = notes.filter { placing.contains($0.number) }.map { note in
                "<div class=\"paper-footnote\" id=\"fn-\(note.number)\"\(note.blockAttribute)>"
                    + "<a class=\"paper-footnote-stock-mark paper-footnote-top\" href=\"#fn-\(note.number)\"></a>"
                    + "<span class=\"paper-footnote-number\">\(note.number)</span>\(note.inner)"
                    + "<a class=\"paper-footnote-stock-mark paper-footnote-bottom\" href=\"#fn-\(note.number)\"></a></div>"
            }.joined()
            return body + (stock.isEmpty ? "" : "\n<section class=\"paper-footnote-stock\">\(stock)</section>")
        }
    }

    public static func plan(for html: String) -> Plan? {
        let tokens = HTMLScanner.tokens(html)
        let sources = tokens.map { token in
            switch token {
            case .text(let text), .opaque(let text): return text
            case .tag(let tag): return tag.source
            }
        }
        let blocked: Set<String> = ["table", "pre", "code", "svg", "math", "figure"]
        let voids: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track",
            "wbr",
        ]
        var stack: [(name: String, start: Int, blocked: Bool, footnotes: Bool)] = []
        var section: Range<Int>?
        var notes: [Note] = []
        var endnoteOrder: [Endnote] = []
        var references: [Reference] = []
        var pending: (start: Int, note: Int, eligible: Bool)?
        for (index, token) in tokens.enumerated() {
            guard case .tag(let tag) = token else { continue }
            if tag.isClosing {
                guard let opening = stack.lastIndex(where: { $0.name == tag.name }) else { continue }
                let element = stack[opening]
                if tag.name == "sup", let current = pending, current.start == element.start {
                    references.append(
                        Reference(index: references.count, note: current.note, eligible: current.eligible, end: index))
                    pending = nil
                }
                if tag.name == "li", element.footnotes,
                    !stack[..<opening].contains(where: { $0.name == "li" }),
                    case .tag(let start) = tokens[element.start]
                {
                    if let id = start.attribute("id"), id.hasPrefix("fn-"), let number = Int(id.dropFirst(3)),
                        number > 0
                    {
                        endnoteOrder.append(.numbered(index: notes.count))
                        notes.append(
                            Note(
                                number: number, inner: sources[(element.start + 1)..<index].joined(),
                                blockID: start.attribute("data-surimono-block")))
                    } else {
                        // A symbolic title note or a restarted chapter series cannot use the numeric stock
                        // markers. Keep its full markup, including its anchor and the author's printed label.
                        endnoteOrder.append(.original(element.start..<(index + 1)))
                    }
                }
                if tag.name == "section", case .tag(let start) = tokens[element.start], hasClass("footnotes", start) {
                    // Multiple footnote sections or duplicate ids are ambiguous; keep the original pagination.
                    guard section == nil else { return nil }
                    section = element.start..<(index + 1)
                }
                stack.removeSubrange(opening...)
            } else {
                let inNotes = stack.last?.footnotes == true || (tag.name == "section" && hasClass("footnotes", tag))
                let excluded = stack.last?.blocked == true || blocked.contains(tag.name) || inNotes
                if tag.name == "a", !inNotes,
                    let sup = stack.last, sup.name == "sup", case .tag(let start) = tokens[sup.start],
                    hasClass("footnote-ref", start), let href = tag.attribute("href"), href.hasPrefix("#fn-"),
                    let number = Int(href.dropFirst(4))
                {
                    pending = (sup.start, number, !excluded)
                }
                if !tag.isSelfClosing, !voids.contains(tag.name) {
                    stack.append((tag.name, index, excluded, inNotes))
                }
            }
        }
        let numbers = Set(notes.map(\.number))
        guard let section, numbers.count == notes.count else { return nil }
        // The page of a note is the page of its first reference. When that one cannot take the note (it sits in a
        // table, say), the note stays at the end rather than moving to a later page that merely mentions it again.
        var firstEligible: [Int: Bool] = [:]
        for reference in references where firstEligible[reference.note] == nil {
            firstEligible[reference.note] = reference.eligible
        }
        references = references.map {
            Reference(
                index: $0.index, note: $0.note,
                eligible: $0.eligible && numbers.contains($0.note) && firstEligible[$0.note] == true, end: $0.end)
        }
        guard references.contains(where: \.eligible) else { return nil }
        return Plan(references: references, tokens: sources, section: section, notes: notes, endnoteOrder: endnoteOrder)
    }

    private static func hasClass(_ name: String, _ tag: HTMLScanner.Tag) -> Bool {
        (tag.attribute("class") ?? "").split(whereSeparator: \.isWhitespace).contains(Substring(name))
    }
}

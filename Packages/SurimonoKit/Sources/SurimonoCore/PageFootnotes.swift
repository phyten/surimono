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
        let id: String
        let inner: String
        /// The change-mark id of the definition, so a moved or rebuilt note keeps its mark.
        let blockID: String?

        var blockAttribute: String {
            blockID.map { " data-surimono-block=\"\(HTML.escape($0))\"" } ?? ""
        }
    }

    /// Notes with a known display number can move. Other series retain their markup and document order.
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
        fileprivate let anchors: [Int: String]
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
                    let series = note.id == "fn-\(note.number)" ? "" : " class=\"numbered-footnote\""
                    return "<li id=\"\(HTML.escape(note.id))\" value=\"\(note.number)\"\(series)\(note.blockAttribute)>"
                        + "\(note.inner)</li>"
                }
            }.joined()
            let endnotes = remaining.isEmpty ? "" : "<section class=\"footnotes\"><ol>\(remaining)</ol></section>"
            var insertions: [Int: String] = [:]
            for group in groups {
                guard references.indices.contains(group.firstReference), references[group.firstReference].eligible,
                    let number = group.notes.first, let anchor = anchors[number], group.heightPixels > 0
                else { continue }
                insertions[references[group.firstReference].end, default: ""] +=
                    "<span class=\"paper-footnote-room\" style=\"height:\(group.heightPixels)px\">"
                    + "<a class=\"paper-footnote-mark\" href=\"#\(HTML.escape(anchor))\"></a></span>"
            }
            var body = ""
            for index in tokens.indices {
                if index == section.lowerBound { body += endnotes }
                if !section.contains(index) { body += tokens[index] }
                body += insertions[index] ?? ""
            }
            let stock = notes.filter { placing.contains($0.number) }.map { note in
                "<div class=\"paper-footnote\" id=\"\(HTML.escape(note.id))\"\(note.blockAttribute)>"
                    + "<a class=\"paper-footnote-stock-mark paper-footnote-top\" href=\"#\(HTML.escape(note.id))\"></a>"
                    + "<span class=\"paper-footnote-number\">\(note.number)</span>\(note.inner)"
                    + "<a class=\"paper-footnote-stock-mark paper-footnote-bottom\" href=\"#\(HTML.escape(note.id))\"></a></div>"
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
        var links: [(id: String, eligible: Bool, end: Int)] = []
        var pending: (start: Int, id: String, eligible: Bool)?
        for (index, token) in tokens.enumerated() {
            guard case .tag(let tag) = token else { continue }
            if tag.isClosing {
                guard let opening = stack.lastIndex(where: { $0.name == tag.name }) else { continue }
                let element = stack[opening]
                if tag.name == "sup", let current = pending, current.start == element.start {
                    links.append((current.id, current.eligible, index))
                    pending = nil
                }
                if tag.name == "li", element.footnotes,
                    !stack[..<opening].contains(where: { $0.name == "li" }),
                    case .tag(let start) = tokens[element.start]
                {
                    if let id = start.attribute("id"), id.hasPrefix("fn-"),
                        let number = hasClass("numbered-footnote", start)
                            ? start.attribute("value").flatMap({ Int($0) }) : Int(id.dropFirst(3)),
                        number > 0
                    {
                        endnoteOrder.append(.numbered(index: notes.count))
                        notes.append(
                            Note(
                                number: number, id: id, inner: sources[(element.start + 1)..<index].joined(),
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
                    hasClass("footnote-ref", start), let href = tag.attribute("href"), href.hasPrefix("#fn-")
                {
                    pending = (sup.start, String(href.dropFirst()), !excluded)
                }
                if !tag.isSelfClosing, !voids.contains(tag.name) {
                    stack.append((tag.name, index, excluded, inNotes))
                }
            }
        }
        guard let section, Set(notes.map(\.number)).count == notes.count, Set(notes.map(\.id)).count == notes.count
        else { return nil }
        let numbers = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.number) })
        let anchors = Dictionary(uniqueKeysWithValues: notes.map { ($0.number, $0.id) })
        // Only the first reference determines whether the definition may leave the end of the document.
        var firstEligible: [Int: Bool] = [:]
        var references: [Reference] = []
        for link in links {
            guard let number = numbers[link.id] else { continue }
            if firstEligible[number] == nil { firstEligible[number] = link.eligible }
            references.append(
                Reference(
                    index: references.count, note: number,
                    eligible: link.eligible && firstEligible[number] == true, end: link.end))
        }
        guard references.contains(where: \.eligible) else { return nil }
        return Plan(
            references: references, tokens: sources, section: section, notes: notes, anchors: anchors,
            endnoteOrder: endnoteOrder)
    }

    private static func hasClass(_ name: String, _ tag: HTMLScanner.Tag) -> Bool {
        (tag.attribute("class") ?? "").split(whereSeparator: \.isWhitespace).contains(Substring(name))
    }
}

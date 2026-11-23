import Foundation

/// A selection on a logical page. Keep the spelling as well as the UTF-16 range: the display copy
/// can contain furniture that the logical PDF used for pairing did not have.
public struct ProsePaperSpan: Equatable, Sendable {
    public let page: Int
    public let range: NSRange
    public let text: String
}

public struct ProsePanelReport: Sendable {
    public enum Group: CaseIterable, Sendable {
        case duplicate, repetition, longSentence

        init(_ kind: ProseFinding.Kind) {
            switch kind {
            case .adjacentDuplicate: self = .duplicate
            case .repetition: self = .repetition
            case .longSentence: self = .longSentence
            }
        }
    }

    public struct Row: Identifiable, Sendable {
        public let id: Int
        public let kind: ProseFinding.Kind
        public let excerpt: String
        public let spans: [ProsePaperSpan]
    }

    public let facts: ProseFacts
    public let groups: [Group: [Row]]
    public let initiallyExpanded: Bool

    public init(report: ProseReport, pages: [String]) throws {
        facts = report.facts
        initiallyExpanded = report.findings.count <= 30
        var groups: [Group: [Row]] = [:]
        if !report.findings.isEmpty {
            let paragraphs = report.paragraphs.map(\.text)
            var index = try ProsePaperIndex(paragraphs: paragraphs, pages: pages)
            for (id, finding) in report.findings.enumerated() {
                try Task.checkCancellation()
                guard let first = finding.occurrences.first else { continue }
                let excerpt = Self.excerpt(in: paragraphs[first.paragraph], at: first.textRange)
                let row = Row(
                    id: id, kind: finding.kind, excerpt: excerpt,
                    spans: try index.spans(for: finding.occurrences))
                groups[Group(finding.kind), default: []].append(row)
            }
        }
        self.groups = groups
    }

    /// Start at the slip, with enough following text to tell similar entries apart. Slice on
    /// Character boundaries before handing off final tail truncation to the width of the row.
    static func excerpt(in paragraph: String, at range: Range<Int>) -> String {
        let text = paragraph as NSString
        let start = text.rangeOfComposedCharacterSequence(at: range.lowerBound).location
        let end = min(text.length, start + 120)
        let sample = text.substring(with: text.rangeOfComposedCharacterSequences(for: NSRange(start..<end)))
        return sample.replacingOccurrences(of: "\u{FFFC}", with: "…")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ") + (end < text.length ? "…" : "")
    }
}

/// A mark belongs to one opening of the panel, one layout and one reading position.
/// Explicit dismissal also covers a paper click or the start of a search at the same position.
public struct ProsePaperMark: Sendable {
    public private(set) var spans: [ProsePaperSpan] = []
    private var generation: Int?
    private var readingPage: Int?

    public init() {}

    public mutating func select(_ spans: [ProsePaperSpan], generation: Int, readingPage: Int) {
        self.spans = spans
        self.generation = generation
        self.readingPage = readingPage
    }

    public func matches(generation: Int?, readingPage: Int) -> Bool {
        self.generation == generation && self.readingPage == readingPage
    }

    public mutating func update(presented: Bool, generation: Int?, readingPage: Int) {
        if !presented || !matches(generation: generation, readingPage: readingPage) { dismiss() }
    }

    public mutating func dismiss() { self = Self() }
}

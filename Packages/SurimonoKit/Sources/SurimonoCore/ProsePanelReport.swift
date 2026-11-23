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

    public enum Location: Sendable { case checking, missing, found }

    public struct Row: Identifiable, Sendable {
        public let id: Int
        public let kind: ProseFinding.Kind
        public let excerpt: ProseExcerpt
        fileprivate var locatedSpans: [ProsePaperSpan]?
        public var spans: [ProsePaperSpan] { locatedSpans ?? [] }
        public var location: Location {
            guard let locatedSpans else { return .checking }
            return locatedSpans.isEmpty ? .missing : .found
        }
    }

    public let facts: ProseFacts
    public private(set) var groups: [Group: [Row]] = [:]
    public let initiallyExpanded: Bool
    private var pending: ProseReport?

    public init(report: ProseReport) throws {
        facts = report.facts
        initiallyExpanded = report.findings.count <= 30
        pending = report.findings.isEmpty ? nil : report
        for (id, finding) in report.findings.enumerated() {
            try Task.checkCancellation()
            guard let first = finding.occurrences.first else { continue }
            let excerpt = ProseExcerpt(paragraph: report.paragraphs[first.paragraph].text, occurrence: first)
            groups[Group(finding.kind), default: []].append(Row(id: id, kind: finding.kind, excerpt: excerpt))
        }
    }

    public func located(on pages: [String]) throws -> Self {
        try Task.checkCancellation()
        guard let pending else { return self }
        let index = try ProsePaperIndex(
            paragraphs: pending.paragraphs.map(\.text), pages: pages,
            occurrences: pending.findings.flatMap(\.occurrences))
        var result = self
        for (group, rows) in groups {
            result.groups[group] = try rows.map { row in
                var row = row
                row.locatedSpans = try index.spans(
                    for: pending.findings[row.id].occurrences, longSentence: group == .longSentence)
                return row
            }
        }
        result.pending = nil
        return result
    }

    public init(report: ProseReport, pages: [String]) throws {
        self = try Self(report: report).located(on: pages)
    }
}

/// A single sentence window. Keep the three pieces separate so the list and VoiceOver use the same wording.
public struct ProseExcerpt: Sendable {
    public let before: String
    public let place: String
    public let after: String
    public var text: String { before + place + after }

    init(paragraph: String, occurrence: ProseOccurrence) {
        let text = paragraph as NSString
        let sentence = occurrence.sentenceRange
        let hit = text.rangeOfComposedCharacterSequences(for: NSRange(occurrence.textRange))
        var start = hit.location
        if occurrence.isEnglish {
            // A very long preceding word would push the finding itself out of a narrow drawer.
            var cursor = start
            for _ in 0..<2 {
                while cursor > sentence.lowerBound, ProseScript.isWhitespace(text.character(at: cursor - 1)) {
                    cursor -= 1
                }
                while cursor > sentence.lowerBound, !ProseScript.isWhitespace(text.character(at: cursor - 1)),
                    hit.location - cursor <= 24
                {
                    cursor -= 1
                }
                guard hit.location - cursor <= 24 else { break }
                start = cursor
            }
        } else {
            for _ in 0..<4 where start > sentence.lowerBound {
                start = text.rangeOfComposedCharacterSequence(at: start - 1).location
            }
        }
        let window = NSRange(start..<min(start + 120, sentence.upperBound))
        let end = NSMaxRange(text.rangeOfComposedCharacterSequences(for: window))
        let hitEnd = min(end, NSMaxRange(hit))
        func snippet(_ range: Range<Int>) -> String {
            text.substring(with: NSRange(range))
                .replacingOccurrences(of: "\u{FFFC}", with: "…")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
        before = (start > sentence.lowerBound ? "…" : "") + snippet(start..<hit.location)
        place = snippet(hit.location..<hitEnd)
        after = snippet(hitEnd..<end) + (end < sentence.upperBound ? "…" : "")
    }
}

/// A mark belongs to one opening of the panel, one layout and one reading position.
/// Explicit dismissal also covers a paper click or the start of a search at the same position.
public struct ProsePaperMark: Sendable {
    public private(set) var spans: [ProsePaperSpan] = []
    public private(set) var findingID: Int?
    private var generation: Int?
    private var readingPage: Int?

    public init() {}

    public mutating func select(_ spans: [ProsePaperSpan], findingID: Int, generation: Int, readingPage: Int) {
        guard !spans.isEmpty else { return }
        self.spans = spans
        self.findingID = findingID
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

/// The pages of a document that go to the printer: all of them, or the page numbers the reader named, in reading
/// order. The numbers are those of the logical pages, before they are imposed on sheets.
public struct PageRange: Equatable, Sendable {
    public enum ParseError: Error, Equatable {
        case unreadable
    }

    /// The pages of one document that a range selects.
    public struct Selection: Equatable, Sendable {
        /// Zero-based indices in ascending order; nil when every page prints.
        public let pages: [Int]?
        /// The range names no page of the document, so every page prints instead.
        public let isOutOfDocument: Bool

        public static let everything = Selection(pages: nil, isOutOfDocument: false)

        public init(pages: [Int]?, isOutOfDocument: Bool) {
            self.pages = pages
            self.isOutOfDocument = isOutOfDocument
        }

        public func contains(_ index: Int) -> Bool { pages?.contains(index) ?? true }
    }

    /// Stands for the last page of whatever document the range is applied to.
    public static let lastPage = Int.max

    /// One-based and inclusive, ascending, and neither overlapping nor touching. Empty means every page.
    public let spans: [ClosedRange<Int>]

    public static let all = PageRange([])

    public var isAll: Bool { spans.isEmpty }

    public init(_ spans: [ClosedRange<Int>]) {
        var merged: [ClosedRange<Int>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) where span.upperBound >= 1 {
            let span = max(span.lowerBound, 1)...span.upperBound
            if let last = merged.last, last.upperBound == Self.lastPage || span.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        self.spans = merged
    }

    /// Reads what the reader typed: `5-12`, `1,3,7-9`, `5-` (to the end) or `-5` (from the start). Full-width digits
    /// and the dashes and commas of a Japanese keyboard read the same. Nothing, or one of `allWords`, is every page.
    public init(parsing text: String, allWords: [String] = ["All", "すべて"]) throws {
        let trimmed = text.filter { !$0.isWhitespace }
        if trimmed.isEmpty || allWords.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            self.init([])
            return
        }
        var spans: [ClosedRange<Int>] = []
        var tokens = Self.tokens(of: text)[...]
        while let token = tokens.popFirst() {
            switch token {
            case .comma:
                continue
            case .number(let first):
                guard first >= 1 else { throw ParseError.unreadable }
                guard tokens.first == .dash else {
                    spans.append(first...first)
                    continue
                }
                tokens.removeFirst()
                if case .number(let last)? = tokens.first {
                    tokens.removeFirst()
                    // A reversed range is more likely a slip than a wish to print backwards.
                    guard last >= first else { throw ParseError.unreadable }
                    spans.append(first...last)
                } else {
                    spans.append(first...Self.lastPage)
                }
            case .dash:
                guard case .number(let last)? = tokens.popFirst(), last >= 1 else { throw ParseError.unreadable }
                spans.append(1...last)
            case .other:
                throw ParseError.unreadable
            }
        }
        guard !spans.isEmpty else { throw ParseError.unreadable }
        self.init(spans)
    }

    /// The range as the field shows it and as a record keeps it: `1-5, 8`. Every page is the empty string.
    public var text: String {
        spans.map { span in
            if span.upperBound == Self.lastPage { return "\(span.lowerBound)-" }
            return span.lowerBound == span.upperBound ? "\(span.lowerBound)" : "\(span.lowerBound)-\(span.upperBound)"
        }
        .joined(separator: ", ")
    }

    /// The pages of a document of `pageCount` pages. Numbers past its end are left out; a range that leaves nothing
    /// prints everything, and says so.
    public func selection(pageCount: Int) -> Selection {
        guard !isAll, pageCount > 0 else { return .everything }
        let pages = spans.flatMap { span -> [Int] in
            let last = min(span.upperBound, pageCount)
            return span.lowerBound <= last ? Array((span.lowerBound - 1)...(last - 1)) : []
        }
        if pages.isEmpty { return Selection(pages: nil, isOutOfDocument: true) }
        return pages.count == pageCount ? .everything : Selection(pages: pages, isOutOfDocument: false)
    }

    private enum Token: Equatable {
        case number(Int)
        case dash
        case comma
        case other
    }

    private static let dashes: Set<Character> = ["-", "–", "—", "−", "－", "ー", "〜", "~", "～"]
    private static let commas: Set<Character> = [",", "、", "，", ";", "；"]

    /// White space only ends a number: `1 3` is two pages and `5 - 12` one range.
    private static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var digits: [Int] = []
        func endNumber() {
            guard !digits.isEmpty else { return }
            // No document has this many pages; the cap only keeps a long row of digits from overflowing.
            tokens.append(.number(digits.count > 9 ? 999_999_999 : digits.reduce(0) { $0 * 10 + $1 }))
            digits = []
        }
        for character in text {
            if let digit = digit(character) {
                digits.append(digit)
                continue
            }
            endNumber()
            if character.isWhitespace { continue }
            tokens.append(dashes.contains(character) ? .dash : commas.contains(character) ? .comma : .other)
        }
        endNumber()
        return tokens
    }

    private static func digit(_ character: Character) -> Int? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x30...0x39: return Int(scalar.value - 0x30)
        case 0xFF10...0xFF19: return Int(scalar.value - 0xFF10)
        default: return nil
        }
    }
}

extension PageRange: Codable {
    /// A record keeps the text, which a person can read and which another version reads the same way.
    public init(from decoder: any Decoder) throws {
        try self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

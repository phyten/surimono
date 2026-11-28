import Foundation

/// The parts of one line of Quarto or R Markdown that print as written, where text that looks like a cross-reference
/// is not one: code spans, formulas, link destinations, bare URLs and autolinks. They come from the same inline
/// matching the Markdown reader uses, so both readers agree on what is literal. What runs over several lines (code
/// spans, HTML code elements) comes from `MarkdownExtensions.protection` as spans.
struct ComputationalLiterals {
    private let ranges: [Range<Int>]
    /// The UTF-16 offset where each character of the line starts, and the line's length at the end.
    private let starts: [Int]

    /// `spans` are UTF-8 offsets within the line that `MarkdownExtensions.protection` found inside code spans running
    /// over several lines and inside HTML code elements.
    init(_ characters: [Character], spans: [Range<Int>] = []) {
        var starts: [Int] = []
        starts.reserveCapacity(characters.count + 1)
        var utf16 = 0
        var utf8Starts: [Int] = []
        var utf8 = 0
        for character in characters {
            starts.append(utf16)
            utf8Starts.append(utf8)
            utf16 += character.utf16.count
            utf8 += character.utf8.count
        }
        starts.append(utf16)
        utf8Starts.append(utf8)
        self.starts = starts
        let text = String(characters) as NSString
        var ranges: [Range<Int>] = []
        let math = ["displayMath", "displayMath2", "inlineMath2", "inlineMath"]
        for match in MarkdownExtensions.inlineMatches(text) {
            let isMath = math.contains { match.groups[$0] != nil }
            guard isMath || match.groups["verbatim"] != nil else { continue }
            // A backslash escape is verbatim to Markdown, but `\@` is how bookdown writes its references.
            if !isMath, match.range.length == 2, text.character(at: match.range.location) == 92 { continue }
            ranges.append(match.range.location..<(match.range.location + match.range.length))
        }
        // Map each UTF-8 span to the UTF-16 offsets of the characters it covers.
        for span in spans {
            let lower = utf8Starts.firstIndex { $0 >= span.lowerBound } ?? characters.count
            let upper = utf8Starts.firstIndex { $0 >= span.upperBound } ?? characters.count
            if lower < upper { ranges.append(starts[lower]..<starts[upper]) }
        }
        self.ranges = ranges
    }

    /// Whether any of the characters in `range` print as written.
    func contains(_ range: Range<Int>) -> Bool {
        let lower = starts[min(range.lowerBound, starts.count - 1)]
        let upper = starts[min(range.upperBound, starts.count - 1)]
        return ranges.contains { $0.overlaps(lower..<upper) }
    }
}

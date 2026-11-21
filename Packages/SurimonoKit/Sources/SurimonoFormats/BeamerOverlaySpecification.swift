import Foundation

/// Resolved for one execution of a frame. Relative numbers refer to the same pause counter
/// throughout a specification, even if several ranges contain a plus sign.
struct BeamerOverlaySpecification {
    struct Interval {
        var first: Int
        var last: Int?
    }
    let intervals: [Interval]
    var lastStep: Int { intervals.reduce(1) { max($0, $1.last ?? $1.first) } }
    var bounded: Bool { intervals.contains { ($0.last ?? 0) > 0 } }

    func contains(_ step: Int) -> Bool {
        intervals.contains { $0.first <= step && ($0.last.map { step <= $0 } ?? true) }
    }

    static func decode(_ source: String, handout: Bool, pause: inout Int) -> Self? {
        let all = [Interval(first: 1, last: nil)]
        var selected: [Interval]?
        var modeOnly = false
        var increment = false
        let value = source.filter { !$0.isWhitespace }
        for part in value.split(separator: "|", omittingEmptySubsequences: false) {
            let fields = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let mode: BeamerMode
            let ranges: [Interval]
            if fields.count == 1, let named = BeamerMode(rawValue: String(part)) {
                mode = named
                modeOnly = true
                ranges = all
            } else {
                guard let selectedMode = fields.count == 2 ? BeamerMode(rawValue: String(fields[0])) : .beamer,
                    let numbers = fields.last, !numbers.isEmpty
                else { return nil }
                mode = selectedMode
                if numbers == "*" {
                    ranges = all
                } else {
                    var parsed: [Interval] = []
                    for range in numbers.split(separator: ",", omittingEmptySubsequences: false) {
                        guard let entry = interval(range, pause: pause, increment: &increment) else { return nil }
                        parsed.append(entry)
                    }
                    ranges = parsed
                }
            }
            if mode.active(handout: handout) {
                selected = ranges
            }
        }
        if increment { pause += 1 }
        return Self(intervals: selected ?? (modeOnly ? [] : all))
    }

    private static func interval(_ range: Substring, pause: Int, increment: inout Bool) -> Interval? {
        var rest = range[...]
        // Bound arithmetic independently of the PDF page budget, including offsets in inactive modes.
        func number() -> Int? {
            if let symbol = rest.first, symbol == "+" || symbol == "." {
                rest.removeFirst()
                var offset = 0
                if rest.first == "(" {
                    guard let end = rest.firstIndex(of: ")"),
                        let n = Int(rest[rest.index(after: rest.startIndex)..<end]),
                        (-1_000_000...1_000_000).contains(n)
                    else { return nil }
                    rest = rest[rest.index(after: end)...]
                    offset = n
                }
                if symbol == "+" { increment = true }
                return max(0, pause + offset - (symbol == "." ? 1 : 0))
            }
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard let n = Int(digits), n <= 1_000_000 else { return nil }
            rest = rest.dropFirst(digits.count)
            return n
        }
        let fromStart = rest.first == "-"
        guard let first = fromStart ? 1 : number() else { return nil }
        if rest.isEmpty { return Interval(first: first, last: first) }
        guard rest.first == "-" else { return nil }
        rest.removeFirst()
        if rest.isEmpty { return fromStart ? nil : Interval(first: first, last: nil) }
        guard let last = number(), last >= first, rest.isEmpty else { return nil }
        return Interval(first: first, last: last)
    }
}

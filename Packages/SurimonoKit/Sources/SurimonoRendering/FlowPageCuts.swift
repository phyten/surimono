import Foundation

/// Coordinates increase in reading order. Overlapping fragments (ruby, emphasis or different fonts on a line)
/// form one band. The caller supplies the axis and places each returned band on paper.
enum FlowPageCuts {
    struct Ink: Decodable, Equatable {
        var start: CGFloat
        var end: CGFloat
        var top: CGFloat
        var bottom: CGFloat

        func union(_ other: Self) -> Self {
            Self(
                start: min(start, other.start), end: max(end, other.end),
                top: min(top, other.top), bottom: max(bottom, other.bottom))
        }
    }

    struct TableRegion: Decodable, Equatable {
        var leftInset: CGFloat
        var width: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var headTop: CGFloat?
        var headHeight: CGFloat?
        var ruleWidth: CGFloat
        var color: [CGFloat]
    }

    struct Continuation: Decodable, Equatable {
        var breaks: [CGFloat]
        var gap: CGFloat = 0
        var bottomBleed: CGFloat = 0
        var tables: [TableRegion]?
    }

    struct Band: Decodable, Equatable {
        var start: CGFloat
        var end: CGFloat
        var keepNext: Bool = false
        var chapter: Bool?
        var ink: Ink?
        var continuation: Continuation?

        mutating func includeInk(of other: Self) {
            if let continuation = other.continuation { self.continuation = continuation }
            if let otherInk = other.ink { ink = ink?.union(otherInk) ?? otherInk }
        }
    }

    static func lines(for fragments: [Band]) -> [Band] {
        var lines: [Band] = []
        for fragment in fragments.sorted(by: { $0.start < $1.start }) {
            if let last = lines.indices.last, fragment.start < lines[last].end {
                lines[last].includeInk(of: fragment)
                lines[last].end = max(lines[last].end, fragment.end)
                if fragment.chapter == true { lines[last].chapter = true }
                lines[last].keepNext = lines[last].keepNext || fragment.keepNext
            } else {
                lines.append(fragment)
            }
        }

        return lines
    }

    static func groups(for fragments: [Band], capacity: CGFloat) -> [Band] {
        groups(of: lines(for: fragments)[...], capacity: capacity)
    }

    static func groups(of lines: ArraySlice<Band>, capacity: CGFloat, keepsTwoLines: Bool = false) -> [Band] {
        // Group from the end so even a run of headings longer than a page keeps the last heading with its text.
        var groups: [Band] = []
        for i in lines.indices.reversed() {
            let line = lines[i]
            let followsHeading =
                keepsTwoLines && i > lines.startIndex && lines[i - 1].keepNext
                && i + 1 < lines.endIndex && !lines[i + 1].keepNext
                && lines[i + 1].end - lines[i - 1].start <= capacity
            if line.keepNext || followsHeading, let next = groups.indices.last,
                line.continuation == nil, groups[next].continuation == nil,
                groups[next].end - line.start <= capacity
            {
                groups[next].includeInk(of: line)
                groups[next].start = line.start
            } else {
                var group = line
                group.keepNext = false
                group.chapter = nil
                groups.append(group)
            }
        }
        return groups.reversed()
    }

    static func pages(for fragments: [Band], capacity: CGFloat) -> [Band] {
        pages(forGroups: groups(for: fragments, capacity: capacity), capacity: capacity)
    }

    static func pages(forGroups groups: [Band], capacity: CGFloat) -> [Band] {
        var pages: [Band] = []
        for group in groups {
            if let last = pages.indices.last, group.continuation == nil, pages[last].continuation == nil,
                group.end - pages[last].start <= capacity
            {
                pages[last].includeInk(of: group)
                pages[last].end = group.end
            } else {
                pages.append(group)
            }
        }
        return pages
    }
}

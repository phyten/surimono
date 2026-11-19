import Foundation

/// Coordinates increase in reading order. Overlapping fragments (ruby, emphasis or different fonts on a line)
/// form one band. The caller supplies the axis and places each returned band on paper.
enum FlowPageCuts {
    struct Band: Decodable, Equatable {
        var start: CGFloat
        var end: CGFloat
        var keepNext: Bool = false
    }

    static func pages(for fragments: [Band], capacity: CGFloat) -> [Band] {
        var lines: [Band] = []
        for fragment in fragments.sorted(by: { $0.start < $1.start }) {
            if let last = lines.indices.last, fragment.start < lines[last].end {
                lines[last].end = max(lines[last].end, fragment.end)
                lines[last].keepNext = lines[last].keepNext || fragment.keepNext
            } else {
                lines.append(fragment)
            }
        }

        // Group from the end so even a run of headings longer than a page keeps the last heading with its text.
        var groups: [Band] = []
        for line in lines.reversed() {
            if line.keepNext, let next = groups.indices.last, groups[next].end - line.start <= capacity {
                groups[next].start = line.start
            } else {
                groups.append(Band(start: line.start, end: line.end))
            }
        }
        var pages: [Band] = []
        for group in groups.reversed() {
            if let last = pages.indices.last, group.end - pages[last].start <= capacity {
                pages[last].end = group.end
            } else {
                pages.append(group)
            }
        }
        return pages
    }
}

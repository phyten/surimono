public struct ReadingPosition: Codable, Equatable, Sendable {
    private let fraction: Double
    private let anchor: Anchor?

    private struct Anchor: Codable, Equatable, Sendable {
        let title: String
        let level: Int
        let occurrence: Int
        let offset: Int
        let length: Int
    }

    public init(page: Int, pageCount: Int, entries: [OutlineEntry]) {
        let lastPage = pageCount > 0 ? pageCount - 1 : 0
        let page = min(max(0, page), lastPage)
        fraction = lastPage > 0 ? Double(page) / Double(lastPage) : 0
        guard pageCount > 0, let index = DocumentOutline.currentEntry(in: entries, page: page),
            let start = entries[index].pageIndex
        else {
            anchor = nil
            return
        }
        let entry = entries[index]
        let occurrence = entries[..<index].filter { $0.title == entry.title && $0.level == entry.level }.count
        anchor = Anchor(
            title: entry.title, level: entry.level, occurrence: occurrence,
            offset: page - max(0, start),
            length: Self.sectionLength(in: entries, index: index, start: max(0, start), pageCount: pageCount))
    }

    public func page(pageCount: Int, entries: [OutlineEntry]) -> Int {
        guard pageCount > 0 else { return 0 }
        let lastPage = pageCount - 1
        if let anchor {
            var occurrence = 0
            for index in entries.indices {
                let entry = entries[index]
                guard entry.title == anchor.title, entry.level == anchor.level else { continue }
                defer { occurrence += 1 }
                guard occurrence == anchor.occurrence else { continue }
                guard let page = entry.pageIndex else { break }
                let start = min(max(0, page), lastPage)
                let length = Self.sectionLength(in: entries, index: index, start: start, pageCount: pageCount)
                let offset: Int
                if length == anchor.length {
                    // Avoid rounding away an unchanged position.
                    offset = min(max(0, anchor.offset), length - 1)
                } else {
                    offset = Self.roundedPage(
                        Double(anchor.offset) / Double(max(1, anchor.length)) * Double(length), limit: length - 1)
                }
                return start + offset
            }
        }
        return Self.roundedPage(fraction * Double(lastPage), limit: lastPage)
    }

    private static func sectionLength(in entries: [OutlineEntry], index: Int, start: Int, pageCount: Int) -> Int {
        let end = entries[(index + 1)...].lazy.compactMap(\.pageIndex).first ?? pageCount
        return max(1, min(max(0, end), pageCount) - start)
    }

    private static func roundedPage(_ value: Double, limit: Int) -> Int {
        let rounded = value.rounded()
        // Double can round Int.max upward beyond the representable integer range.
        if rounded >= Double(limit) { return limit }
        guard rounded > 0 else { return 0 }
        return Int(rounded)
    }
}

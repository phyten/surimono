/// One screenful of the view mode. Page numbers are 1-based.
public enum DisplayUnit: Equatable, Sendable {
    case single(Int)
    /// A facing pair as it appears on screen; one side is empty for a lone cover or a leftover last page.
    case spread(left: Int?, right: Int?)

    public var pages: [Int] {
        switch self {
        case .single(let page): [page]
        case .spread(let left, let right): [left, right].compactMap { $0 }.sorted()
        }
    }
}

public enum SpreadLayout {
    /// Arranges pages like a bound book. Left-to-right books pair `[1|2] [3|4]`, or `[ |1] [2|3]` with the cover
    /// alone; right-to-left books mirror that as `[2|1] [4|3]` and `[1| ] [3|2]`. A page left over at the end keeps
    /// the side it would have in its pair.
    public static func units(
        pageCount: Int, layout: ViewOptions.Layout, showsCoverAlone: Bool, direction: ViewOptions.Direction
    ) -> [DisplayUnit] {
        guard pageCount > 0 else { return [] }
        guard layout != .single else { return (1...pageCount).map(DisplayUnit.single) }
        let rightToLeft = direction == .rightToLeft
        var units: [DisplayUnit] = []
        var page = 1
        if showsCoverAlone {
            // The cover is a recto: the right-hand page of a left-bound book.
            units.append(rightToLeft ? .spread(left: 1, right: nil) : .spread(left: nil, right: 1))
            page = 2
        }
        while page <= pageCount {
            let next = page + 1 <= pageCount ? page + 1 : nil
            units.append(rightToLeft ? .spread(left: next, right: page) : .spread(left: page, right: next))
            page += 2
        }
        return units
    }

    public static func unitIndex(containing page: Int, in units: [DisplayUnit]) -> Int? {
        units.firstIndex { $0.pages.contains(page) }
    }
}

extension SpreadLayout {
    /// The units that a strip with room for `capacity` of them shows: all of them when they fit, otherwise a run
    /// around `current` that stays within the document.
    public static func visibleRange(unitCount: Int, current: Int?, capacity: Int) -> Range<Int> {
        guard unitCount > 0, capacity > 0 else { return 0..<0 }
        guard unitCount > capacity else { return 0..<unitCount }
        let center = min(max(current ?? 0, 0), unitCount - 1)
        let start = min(max(center - (capacity - 1) / 2, 0), unitCount - capacity)
        return start..<(start + capacity)
    }
}

/// The page indicator of the view mode: "3 / 12" for a page, "2–3 / 12" for a spread.
public enum PageIndicator {
    public static func text(pages: [Int], pageCount: Int) -> String {
        guard let first = pages.first, let last = pages.last else { return "" }
        let shown = first == last ? "\(first)" : "\(first)–\(last)"
        return "\(shown) / \(pageCount)"
    }

    /// The widest text that any unit of this document can show, with "8" standing for every digit; in a font with
    /// tabular digits, reserving its width keeps the indicator from changing size while turning pages.
    public static func widestText(pageCount: Int, layout: ViewOptions.Layout) -> String {
        let digits = String(repeating: "8", count: String(max(pageCount, 1)).count)
        let shown = layout == .single ? digits : "\(digits)–\(digits)"
        return "\(shown) / \(pageCount)"
    }
}

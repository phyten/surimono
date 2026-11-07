public enum BinderPagination {
    /// Zero-based starts. Empty or failed children consume neither pages nor separators.
    public static func offsets(pageCounts: [Int], startsOnFront: Bool) -> [Int] {
        var count = 0
        return pageCounts.map { pages in
            guard pages > 0 else { return count }
            if startsOnFront, count % 2 == 1 { count += 1 }
            let offset = count
            count += pages
            return offset
        }
    }
    /// Starts must be in reading order. A separator belongs to the preceding document.
    public static func documentIndex(containing page: Int, starts: [Int], pageCount: Int) -> Int? {
        guard page >= 0, page < pageCount else { return nil }
        return starts.lastIndex { $0 <= page }
    }

    /// Keep a clicked document selected while either half of the spread still shows it.
    public static func selection(current: Int?, visiblePages: [Int], starts: [Int], pageCount: Int) -> Int? {
        let visible = visiblePages.sorted().compactMap {
            documentIndex(containing: $0, starts: starts, pageCount: pageCount)
        }
        if let current, visible.contains(current) { return current }
        return visible.first ?? current
    }
}

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
}

import Foundation

/// Uses Finder's name order with a raw UTF-8 tie-break for stable sorting.
public enum NaturalOrder {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let comparison = lhs.localizedStandardCompare(rhs)
        guard comparison == .orderedSame else { return comparison }
        if lhs.utf8.elementsEqual(rhs.utf8) { return .orderedSame }
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8) ? .orderedAscending : .orderedDescending
    }

    public static func areInIncreasingOrder(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    public static func comparePaths(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsComponents = lhs.split(separator: "/", omittingEmptySubsequences: false)
        let rhsComponents = rhs.split(separator: "/", omittingEmptySubsequences: false)
        for (lhsComponent, rhsComponent) in zip(lhsComponents, rhsComponents) {
            let comparison = compare(String(lhsComponent), String(rhsComponent))
            if comparison != .orderedSame { return comparison }
        }
        if lhsComponents.count == rhsComponents.count { return .orderedSame }
        return lhsComponents.count < rhsComponents.count ? .orderedAscending : .orderedDescending
    }

    public static func arePathsInIncreasingOrder(_ lhs: String, _ rhs: String) -> Bool {
        comparePaths(lhs, rhs) == .orderedAscending
    }
}

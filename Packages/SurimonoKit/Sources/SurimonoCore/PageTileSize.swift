import CoreGraphics

public struct PageTileSize: Sendable {
    public static let currentLineWidth: CGFloat = 3
    public static let framePadding: CGFloat = currentLineWidth + 2

    public let paper: CGSize
    public let paperAreaHeight: CGFloat

    public static func availableWidth(in drawer: CGFloat, columns: Int, bundle: Bool) -> CGFloat {
        let count = CGFloat(max(1, columns))
        // The bundle gives each drop target two 5pt half-gutters and its button a 2pt inset on both sides.
        let width = bundle ? floor((drawer - 8) / count) - 14 : floor((drawer - (count - 1) * 10 - 12) / count)
        return max(32, min(200, width))
    }

    /// Each section begins a row of its own, even if its first page has an odd index.
    public static func rowMate(of page: Int, in pages: Range<Int>, columns: Int) -> Int? {
        guard columns == 2 else { return nil }
        let other = (page - pages.lowerBound).isMultiple(of: 2) ? page + 1 : page - 1
        return pages.contains(other) ? other : nil
    }

    public init(width: CGFloat, aspect: CGFloat, rowMateAspect: CGFloat?) {
        let width = max(0, width - 2 * Self.framePadding)
        let limit = 208 - 2 * Self.framePadding
        let height = min(limit, width / aspect)
        paper = CGSize(width: min(width, height * aspect), height: height)
        // Only the taller image in this row reserves space. Two landscapes still make a short row.
        paperAreaHeight = 2 * Self.framePadding + max(height, rowMateAspect.map { min(limit, width / $0) } ?? height)
    }
}

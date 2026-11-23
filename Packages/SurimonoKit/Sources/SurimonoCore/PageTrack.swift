import CoreGraphics

/// The reading order is independent of the slots occupied by a spread or a lone cover.
public struct PageTrack: Sendable {
    public let count: Int
    public let rightToLeft: Bool

    public init(count: Int, rightToLeft: Bool) {
        self.count = max(0, count)
        self.rightToLeft = rightToLeft
    }

    public var stepToRight: Int { rightToLeft ? -1 : 1 }

    public func page(at fraction: CGFloat) -> Int? {
        guard count > 0, fraction.isFinite else { return nil }
        let position = min(1, max(0, fraction))
        let progress = rightToLeft ? 1 - position : position
        return progress == 1 ? count - 1 : Int((progress * CGFloat(count - 1)).rounded())
    }

    public func fraction(for page: Int) -> CGFloat {
        let position = CGFloat(min(max(0, page), max(0, count - 1))) / CGFloat(max(1, count - 1))
        return rightToLeft ? 1 - position : position
    }

    public func ticks(chapters: [Int], width: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        for page in chapters.sorted() where (0..<count).contains(page) {
            let x = fraction(for: page) * width
            if let previous = result.last, abs(x - previous) < 8 { continue }
            result.append(x)
        }
        return result
    }

    public static func previewCaption(page: Int, chapter: String?) -> String {
        let number = String(page + 1)
        guard let chapter, !chapter.isEmpty else { return number }
        return number + " · " + chapter
    }

    public static func previewPaper(aspect: CGFloat, available: CGSize) -> CGSize {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 0.707
        let width = min(ratio > 1 ? 210 : 160, max(0, available.width))
        let height = min(220, max(0, available.height), width / ratio)
        return CGSize(width: height * ratio, height: height)
    }

    public static func previewCenter(pointer: CGFloat, width: CGFloat, window: CGFloat) -> CGFloat {
        let inset = min(window / 2, 12 + width / 2)
        return min(max(inset, pointer), window - inset)
    }

    public static func hoverMark(fraction: CGFloat, size: CGSize) -> CGRect {
        let x = min(size.width - 2.5, max(2.5, fraction * size.width))
        return CGRect(x: x - 2.5, y: size.height / 2 - 2.5, width: 5, height: 5)
    }
}

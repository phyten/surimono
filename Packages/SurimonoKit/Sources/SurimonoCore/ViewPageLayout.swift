import Foundation

/// A presentation-only plan. Indices are zero-based; nil slots are unnumbered paper.
/// Slots follow reading order; PDFKit mirrors each pair when displaysRTL is set.
public struct ViewPageLayout: Equatable, Sendable {
    /// Breathing room kept below a page's lowest drawn content when trimming unused paper at a scroll seam.
    public static let seamTrailingPadding: CGFloat = 10

    public let logicalIndices: [Int?]
    public let cropsMargins: Bool
    public let showsNumbers: Bool
    private let pagesPerUnit: Int
    private let pageScales: [CGFloat]
    /// The margins joined pages keep, by logical page: those that hold the printed header or footer.
    private let keptEdges: [Int: CropEdges]
    /// Distance in points from the bottom of a logical page's crop box to its lowest drawn content.
    private let contentBottoms: [Int: CGFloat]

    public struct CropEdges: Equatable, Sendable {
        public var top = false
        public var bottom = false

        public init(top: Bool = false, bottom: Bool = false) {
            self.top = top
            self.bottom = bottom
        }
    }

    public struct CropInsets: Equatable, Sendable {
        public var top: CGFloat = 0
        public var bottom: CGFloat = 0

        public init(top: CGFloat = 0, bottom: CGFloat = 0) {
            self.top = top
            self.bottom = bottom
        }
    }

    /// Only inputs that change PDF content, excluding options whose effects are confined to PDFView.
    public struct DocumentKey: Equatable, Sendable {
        let logicalIndices: [Int?]
        let edges: [CropEdges]
        let trimmedBottoms: [Int: Double]
        let showsNumbers: Bool
        let margin: Double
        let pageScales: [CGFloat]

        public var requiresCopy: Bool {
            logicalIndices.contains(nil) || showsNumbers || edges.contains { $0 != CropEdges() }
                || !trimmedBottoms.isEmpty || !pageScales.isEmpty
        }
    }

    public func documentKey(margin: Double) -> DocumentKey {
        let edges = logicalIndices.indices.map { margin > 0 ? crops(at: $0) : CropEdges() }
        let baseMargin = max(0, margin)
        var trimmedBottoms: [Int: Double] = [:]
        if cropsMargins, !contentBottoms.isEmpty {
            for viewIndex in logicalIndices.indices {
                guard crops(at: viewIndex).bottom, let index = logicalIndex(at: viewIndex),
                    let bottom = contentBottoms[index], bottom.isFinite
                else { continue }
                let trimmed = Double(bottom - Self.seamTrailingPadding)
                if trimmed > baseMargin { trimmedBottoms[viewIndex] = trimmed }
            }
        }
        let usesMargin = showsNumbers || edges.contains { $0 != CropEdges() }
        return DocumentKey(
            logicalIndices: logicalIndices, edges: edges, trimmedBottoms: trimmedBottoms,
            showsNumbers: showsNumbers, margin: usesMargin ? margin : 0, pageScales: pageScales)
    }

    /// - Parameters:
    ///   - keptEdges: The margins a logical page keeps where pages are joined, because the printed header or footer
    ///     stands in them. A page without one has its margins cut at the seams as before.
    ///   - contentBottoms: Distance from the bottom of a logical page's crop box to its lowest drawn content, in
    ///     points, used to trim unused paper below the last content on non-final pages in vertical Scroll mode.
    public init(
        pageCount: Int, options: ViewOptions, hasLogicalMargins: Bool, showsNumbers: Bool, pageSizes: [CGSize] = [],
        keptEdges: [Int: CropEdges] = [:], contentBottoms: [Int: CGFloat] = [:]
    ) {
        self.keptEdges = keptEdges
        self.contentBottoms = contentBottoms
        var indices = (0..<max(0, pageCount)).map(Optional.some)
        if options.layout == .spread && !indices.isEmpty {
            if options.showsCoverAlone { indices.insert(nil, at: 0) }
            if !indices.count.isMultiple(of: 2) { indices.append(nil) }
        }
        pagesPerUnit = options.layout == .spread ? 2 : 1
        logicalIndices = indices
        cropsMargins = hasLogicalMargins && options.canJoinPages && options.joinsPages
        self.showsNumbers = showsNumbers && !options.isSinglePageContinuous
        let representative = PageSizes.representative(pageSizes)
        if options.isContinuous, pageSizes.contains(where: { !PageSizes.matches($0, representative) }) {
            pageScales = pageSizes.map { size in
                guard !PageSizes.matches(size, representative),
                    size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                    representative.width > 0, representative.height > 0
                else { return 1 }
                let widthScale = representative.width / size.width
                // PDFKit spaces horizontal spreads using the widest page, so both dimensions must fit.
                let fit =
                    options.scrollAxis == .vertical ? widthScale : min(widthScale, representative.height / size.height)
                return min(1, fit)
            }
        } else {
            pageScales = []
        }
    }

    public func scale(at viewIndex: Int) -> CGFloat {
        guard let logicalIndex = logicalIndex(at: viewIndex) ?? readingIndex(at: viewIndex),
            pageScales.indices.contains(logicalIndex)
        else { return 1 }
        return pageScales[logicalIndex]
    }

    public func viewIndex(for logicalIndex: Int) -> Int? {
        logicalIndices.firstIndex { $0 == logicalIndex }
    }

    public func logicalIndex(at viewIndex: Int) -> Int? {
        guard logicalIndices.indices.contains(viewIndex) else { return nil }
        return logicalIndices[viewIndex]
    }

    /// PDFKit may identify either half as currentPage. Report the first real page in reading order,
    /// independently of the physical left/right direction and of which half navigation landed on.
    public func readingIndex(at viewIndex: Int) -> Int? {
        guard logicalIndices.indices.contains(viewIndex) else { return nil }
        let start = viewIndex - viewIndex % pagesPerUnit
        return logicalIndices[start..<min(start + pagesPerUnit, logicalIndices.count)].compactMap { $0 }.first
    }

    /// Move by a whole display unit, not relative to PDFKit's choice of the current half.
    public func adjacentReadingIndex(at viewIndex: Int, forward: Bool) -> Int? {
        guard logicalIndices.indices.contains(viewIndex) else { return nil }
        let start = viewIndex - viewIndex % pagesPerUnit
        return readingIndex(at: start + (forward ? pagesPerUnit : -pagesPerUnit))
    }

    public func crops(at viewIndex: Int) -> CropEdges {
        guard cropsMargins, let index = logicalIndex(at: viewIndex) else { return CropEdges() }
        let kept = keptEdges[index] ?? CropEdges()
        return CropEdges(top: viewIndex > 0 && !kept.top, bottom: viewIndex < logicalIndices.count - 1 && !kept.bottom)
    }

    /// Logical page indices whose unused bottom paper can be trimmed at a scroll seam.
    public var trimmableBottomPages: [Int] {
        guard cropsMargins else { return [] }
        return logicalIndices.indices.compactMap { viewIndex in
            guard crops(at: viewIndex).bottom else { return nil }
            return logicalIndex(at: viewIndex)
        }
    }

    /// The vertical crop insets for the page at `viewIndex`, in points.
    ///
    /// When pages are joined in vertical Scroll mode and a non-final page has unused paper below its lowest drawn
    /// content, the bottom inset extends up to `contentBottom - seamTrailingPadding` while leaving at least `margin`
    /// cut and at least one point of visible page height.
    public func cropInsets(at viewIndex: Int, pageHeight: CGFloat, margin: CGFloat) -> CropInsets {
        guard pageHeight.isFinite, pageHeight > 0, margin.isFinite, margin >= 0 else { return CropInsets() }
        let edges = crops(at: viewIndex)
        let top: CGFloat = edges.top ? margin : 0
        var bottom: CGFloat = edges.bottom ? margin : 0
        if edges.bottom, let index = logicalIndex(at: viewIndex), let contentBottom = contentBottoms[index],
            contentBottom.isFinite, contentBottom > 0
        {
            let trimmed = contentBottom - Self.seamTrailingPadding
            if trimmed > bottom {
                let maximum = pageHeight - top - 1
                if maximum > bottom { bottom = min(trimmed, maximum) }
            }
        }
        guard top + bottom < pageHeight else { return CropInsets() }
        return CropInsets(top: top, bottom: bottom)
    }

    public func number(at viewIndex: Int) -> Int? {
        guard showsNumbers, let index = logicalIndex(at: viewIndex) else { return nil }
        return index + 1
    }
}

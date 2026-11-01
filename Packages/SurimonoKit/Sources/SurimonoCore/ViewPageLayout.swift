import Foundation

/// A presentation-only plan. Indices are zero-based; nil slots are unnumbered paper.
/// Slots follow reading order; PDFKit mirrors each pair when displaysRTL is set.
public struct ViewPageLayout: Equatable, Sendable {
    public let logicalIndices: [Int?]
    public let cropsMargins: Bool
    public let showsNumbers: Bool
    private let pagesPerUnit: Int
    private let scrollAxis: ViewOptions.ScrollAxis
    private let direction: ViewOptions.Direction
    private let pageScales: [CGFloat]

    public struct CropEdges: Equatable, Sendable {
        public var top = false
        public var bottom = false
        public var left = false
        public var right = false
    }

    /// Only inputs that change PDF content, excluding options whose effects are confined to PDFView.
    public struct DocumentKey: Equatable, Sendable {
        let logicalIndices: [Int?]
        let edges: [CropEdges]
        let showsNumbers: Bool
        let margin: Double
        let pageScales: [CGFloat]

        public var requiresCopy: Bool {
            logicalIndices.contains(nil) || showsNumbers || edges.contains { $0 != CropEdges() } || !pageScales.isEmpty
        }
    }

    public func documentKey(margin: Double) -> DocumentKey {
        let edges = logicalIndices.indices.map { margin > 0 ? crops(at: $0) : CropEdges() }
        let usesMargin = showsNumbers || edges.contains { $0 != CropEdges() }
        return DocumentKey(
            logicalIndices: logicalIndices, edges: edges, showsNumbers: showsNumbers,
            margin: usesMargin ? margin : 0, pageScales: pageScales)
    }

    public init(
        pageCount: Int, options: ViewOptions, hasLogicalMargins: Bool, showsNumbers: Bool, pageSizes: [CGSize] = []
    ) {
        var indices = (0..<max(0, pageCount)).map(Optional.some)
        if options.layout == .spread && !indices.isEmpty {
            if options.showsCoverAlone { indices.insert(nil, at: 0) }
            if !indices.count.isMultiple(of: 2) { indices.append(nil) }
        }
        scrollAxis = options.scrollAxis
        direction = options.direction
        pagesPerUnit = options.layout == .spread ? 2 : 1
        logicalIndices = indices
        cropsMargins = hasLogicalMargins && options.isSinglePageContinuous && options.joinsPages
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
        guard cropsMargins, logicalIndex(at: viewIndex) != nil else { return CropEdges() }
        let hasPrevious = viewIndex > 0
        let hasNext = viewIndex < logicalIndices.count - 1
        if scrollAxis == .vertical { return CropEdges(top: hasPrevious, bottom: hasNext) }
        return direction == .leftToRight
            ? CropEdges(left: hasPrevious, right: hasNext)
            : CropEdges(left: hasNext, right: hasPrevious)
    }

    public func number(at viewIndex: Int) -> Int? {
        guard showsNumbers, let index = logicalIndex(at: viewIndex) else { return nil }
        return index + 1
    }
}

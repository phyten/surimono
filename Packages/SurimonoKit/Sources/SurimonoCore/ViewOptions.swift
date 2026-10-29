import CoreGraphics
import Foundation

/// How the view mode lays out and turns logical pages. This is a reading preference only; the print layout
/// (imposition) is chosen separately.
public struct ViewOptions: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Sendable {
        case spread
        case single

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            // Two-page scrolling was merged into spread; keep existing document settings readable.
            if value == "twoPageScroll" {
                self = .spread
            } else if let layout = Self(rawValue: value) {
                self = layout
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown view layout: \(value)")
            }
        }
    }

    /// The reading direction and the binding side are one choice: left-to-right books are bound on the left.
    public enum Direction: String, Codable, CaseIterable, Sendable {
        case leftToRight
        case rightToLeft
    }

    public enum ScrollAxis: String, Codable, CaseIterable, Sendable {
        case vertical
        case horizontal
    }

    /// Motion and animation are one choice: scroll continuously, or turn pages instantly or with an animation.
    public enum Transition: String, Codable, CaseIterable, Sendable {
        case scroll
        case instant
        case slide
        case fade
        case pageCurl
    }

    public var layout: Layout
    public var direction: Direction
    public var scrollAxis: ScrollAxis
    public var transition: Transition
    public var showsCoverAlone: Bool

    public init(
        layout: Layout, direction: Direction = .leftToRight, scrollAxis: ScrollAxis, transition: Transition,
        showsCoverAlone: Bool
    ) {
        self.layout = layout
        self.direction = direction
        self.scrollAxis = scrollAxis
        self.transition = transition
        self.showsCoverAlone = showsCoverAlone
    }

    /// A single page has no facing page, so the cover option only applies to spreads.
    public var usesCoverOption: Bool { layout != .single }

    /// Pages form one scrolling strip instead of being turned one unit at a time.
    public var isContinuous: Bool { transition == .scroll }

    public enum SlideEdge: Equatable, Sendable {
        case left, right, top, bottom
    }

    /// The edge from which the next visible page or spread enters.
    public func slideEdge(forward: Bool) -> SlideEdge {
        if scrollAxis == .vertical { return forward ? .bottom : .top }
        return forward == (direction == .leftToRight) ? .right : .left
    }
}

/// What the view mode knows about a document when it picks the initial view options.
public struct ViewDefaultsContext: Equatable, Sendable {
    public enum Kind: Sendable {
        case pdf
        /// Markdown, Org, plain text, CSV and HTML, which flow onto as many pages as they need.
        case flowingText
        case image
        case imageBundle
    }

    public var kind: Kind
    public var pageCount: Int
    /// The size of the first page as displayed, after rotation.
    public var firstPageSize: CGSize
    /// The catalog's `/PageLayout` name, such as `TwoPageRight`.
    public var pdfPageLayout: String?
    /// The `/Direction` name of the viewer preferences, `L2R` or `R2L`.
    public var pdfDirection: String?

    public init(
        kind: Kind, pageCount: Int, firstPageSize: CGSize, pdfPageLayout: String? = nil, pdfDirection: String? = nil
    ) {
        self.kind = kind
        self.pageCount = pageCount
        self.firstPageSize = firstPageSize
        self.pdfPageLayout = pdfPageLayout
        self.pdfDirection = pdfDirection
    }
}

extension ViewOptions {
    /// Flowing documents read top to bottom without a cover; PDFs and image bundles read like the bound booklet
    /// they are often printed as.
    public static func defaults(for context: ViewDefaultsContext) -> ViewOptions {
        switch context.kind {
        case .flowingText:
            return ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        case .image:
            return ViewOptions(layout: .single, scrollAxis: .horizontal, transition: .slide, showsCoverAlone: false)
        case .imageBundle:
            return ViewOptions(layout: .spread, scrollAxis: .horizontal, transition: .slide, showsCoverAlone: true)
        case .pdf:
            return pdfDefaults(for: context)
        }
    }

    private static func pdfDefaults(for context: ViewDefaultsContext) -> ViewOptions {
        let direction: Direction = context.pdfDirection == "R2L" ? .rightToLeft : .leftToRight
        var options = ViewOptions(
            layout: .spread, direction: direction, scrollAxis: .horizontal, transition: .slide, showsCoverAlone: true)
        switch context.pdfPageLayout {
        case "SinglePage":
            options.layout = .single
        case "OneColumn":
            options.layout = .single
            options.scrollAxis = .vertical
            options.transition = .scroll
        case "TwoColumnLeft", "TwoColumnRight", "TwoPageLeft", "TwoPageRight":
            let layout = context.pdfPageLayout ?? ""
            if layout.hasPrefix("TwoColumn") {
                options.scrollAxis = .vertical
                options.transition = .scroll
            }
            // The names say on which physical side odd pages sit. Page 1 alone on the binding's far side is a cover.
            let oddPagesOnRight = layout.hasSuffix("Right")
            options.showsCoverAlone = direction == .leftToRight ? oddPagesOnRight : !oddPagesOnRight
        default:
            let landscape = context.firstPageSize.width > context.firstPageSize.height
            if context.pageCount <= 2 || landscape { options.layout = .single }
        }
        return options
    }
}

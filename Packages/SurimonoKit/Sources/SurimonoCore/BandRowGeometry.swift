import CoreGraphics

/// Measurements exclude gaps; fixtures with gap-inclusive widths use zero gap metrics.
public struct BandMeasurementsValue: Equatable, Sendable {
    public var items: [BandLayout.Item: BandLayout.Widths]
    public var name: CGFloat
    public var scrubber: CGFloat?
    /// The widest of the document's chapter titles, whole: the frame the band keeps for the current one on every
    /// page. Nil takes the chapter part's measured width as the title's.
    public var chapterTitle: CGFloat?
    /// What the chapter part adds around its title.
    public var chapterChrome: CGFloat

    public init(
        items: [BandLayout.Item: BandLayout.Widths], name: CGFloat, scrubber: CGFloat? = nil,
        chapterTitle: CGFloat? = nil, chapterChrome: CGFloat = 0
    ) {
        self.items = items
        self.name = name
        self.scrubber = scrubber
        self.chapterTitle = chapterTitle
        self.chapterChrome = chapterChrome
    }
}

public struct BandMetrics: Equatable, Sendable {
    /// Infrastructure including More, lights, padding, flexible-space minimum and reserved outer stack gaps.
    public var topFixed: CGFloat
    public var bottomFixed: CGFloat
    /// Separator including its extra stack gap, as in the existing renderer.
    public var separator: CGFloat
    public var titleGap: CGFloat
    public var toolGap: CGFloat
    public var outerGap: CGFloat

    public init(
        topFixed: CGFloat, bottomFixed: CGFloat, separator: CGFloat,
        titleGap: CGFloat = 6, toolGap: CGFloat = 8, outerGap: CGFloat = 10
    ) {
        self.topFixed = topFixed
        self.bottomFixed = bottomFixed
        self.separator = separator
        self.titleGap = titleGap
        self.toolGap = toolGap
        self.outerGap = outerGap
    }
}

public struct BandRowGeometry: Equatable, Sendable {
    public enum MoreDock: Equatable, Sendable { case beforePrint, trailing, absent }

    public var fixedWidth: CGFloat
    public var gapsBefore: [BandLayout.Item: CGFloat]
    public var separatorsBefore: [BandLayout.Item]
    public var separatorWidth: CGFloat
    public var moreDock: MoreDock
    public var usesStandardSpacing: Bool
    /// The gap the band draws between the last tool before "…" and "…". The Standard order counts it as that tool's
    /// stack gap instead, so it is zero there.
    public var moreGap: CGFloat = 0

    public var spacingWidth: CGFloat {
        fixedWidth + BandLayout.Item.allCases.reduce(0) { $0 + (gapsBefore[$1] ?? 0) }
            + CGFloat(separatorsBefore.count) * separatorWidth + moreGap
    }
}

public struct BandRowPlan: Equatable, Sendable {
    public var leading: [BandLayout.Item]
    public var trailing: [BandLayout.Item]
    public var forms: [BandLayout.Item: BandLayout.Form]
    public var nameWidth: CGFloat
    public var minimumWidth: CGFloat
    public var geometry: BandRowGeometry
    /// Includes the allocated name width even below the threshold at which the renderer hides it.
    public var requiredWidth: CGFloat
    public var showsScrubber = false
    /// The frame of the chapter title on a bottom band, where it shares the room with the slider. Nil elsewhere: there
    /// the chapter part keeps the room its widest title needs.
    public var chapterTitleWidth: CGFloat? = nil

    public var showsName: Bool { nameWidth >= BandLayout.nameHidingWidth }
}

public struct BandResolvedPlan: Equatable, Sendable {
    public var top: BandRowPlan
    public var bottom: BandRowPlan?
    public var overflow: [BandLayout.Item]
    public var unusedAvailable: [BandLayout.Item]

}

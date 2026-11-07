import CoreGraphics

/// Where the parts of the press bar go. SwiftUI only measures the parts; what goes beside what is decided here from
/// plain numbers, so that each fold can be pinned by a test.
///
/// The bar has two groups. The choices (the paper, its orientation and the layout cards) are on the left; the result
/// and the ways to send it out (what comes out, the printer, PDF and Print) are on the right. Where the window cannot
/// hold them side by side, the second group takes a row of its own under the first, without the rule between them.
///
/// It is `nonisolated` because `Layout` calls it from methods that are not isolated to the main actor.
nonisolated struct PrintPressArrangement: Equatable {
    enum Form: Equatable {
        /// The choices on the left; the result over the printer, PDF and Print on the right.
        case beside
        /// The result and the buttons on a row of their own under the choices.
        case stacked
    }

    /// The sizes SwiftUI measured. A part that wraps answers for the width it is given.
    struct Parts {
        /// The paper switch and the orientation menu in one row.
        var paperRow: CGSize
        /// All the layout cards in one row.
        var cardsWidth: CGFloat
        var cardsHeight: (CGFloat) -> CGFloat
        /// The result's longest line unwrapped.
        var summaryWidth: CGFloat
        var summaryHeight: (CGFloat) -> CGFloat
        /// The printer and PDF buttons: the narrowest width they take, and the one they would like.
        var actionsWidth: ClosedRange<CGFloat>
        var actionsHeight: CGFloat
        var button: CGSize
    }

    /// Between the paper row and the cards.
    static let rowGap: CGFloat = 4
    /// Between the choices and the row under them, when stacked.
    static let stackGap: CGFloat = 8
    /// Between the printer and PDF buttons and Print.
    static let clusterGap: CGFloat = 8
    /// Between the result and the buttons, in a column and in a row.
    static let columnGap: CGFloat = 8
    static let rowSpacing: CGFloat = 12
    /// Either side of the rule between the groups.
    static let ruleGap: CGFloat = 8
    static let ruleWidth: CGFloat = 1
    static let ruleSpan = ruleGap + ruleWidth + ruleGap
    /// A result wider than this gains nothing from more room; its longest line is a note, which may be cut.
    static let summaryLimit: CGFloat = 360
    /// The narrowest the result is made to stand beside the buttons on a row of its own.
    static let summaryMinimum: CGFloat = 150

    let form: Form
    let paperRow: CGRect
    let cards: CGRect
    let summary: CGRect
    let actions: CGRect
    let button: CGRect
    /// The rule between the groups; empty when they are stacked.
    let rule: CGRect
    let size: CGSize

    init(width: CGFloat, parts: Parts) {
        let narrowest = parts.actionsWidth.lowerBound + Self.clusterGap + parts.button.width
        let wanted = parts.actionsWidth.upperBound + Self.clusterGap + parts.button.width
        // The choices are as wide as the wider of the paper row and the cards.
        let choicesWidth = max(parts.cardsWidth, parts.paperRow.width)
        let cardsY = parts.paperRow.height + Self.rowGap
        let clusterHeight = max(parts.actionsHeight, parts.button.height)
        let buttonX = width - parts.button.width
        self.paperRow = CGRect(origin: .zero, size: parts.paperRow)

        if choicesWidth + Self.ruleSpan + narrowest <= width {
            let room = width - choicesWidth - Self.ruleSpan
            let blockWidth = min(room, max(wanted, min(parts.summaryWidth, Self.summaryLimit)))
            let summaryHeight = parts.summaryHeight(blockWidth)
            let cardsHeight = parts.cardsHeight(parts.cardsWidth)
            let height = max(cardsY + cardsHeight, summaryHeight + Self.columnGap + clusterHeight)
            let actionsWidth = Self.clamp(blockWidth - Self.clusterGap - parts.button.width, to: parts.actionsWidth)
            self.form = .beside
            self.cards = CGRect(x: 0, y: cardsY, width: parts.cardsWidth, height: cardsHeight)
            self.summary = CGRect(x: width - blockWidth, y: 0, width: blockWidth, height: summaryHeight)
            self.actions = CGRect(
                x: buttonX - Self.clusterGap - actionsWidth, y: height - parts.actionsHeight, width: actionsWidth,
                height: parts.actionsHeight)
            self.button = CGRect(
                x: buttonX, y: height - parts.button.height, width: parts.button.width, height: parts.button.height)
            self.rule = CGRect(
                x: width - blockWidth - Self.ruleGap - Self.ruleWidth, y: 0, width: Self.ruleWidth, height: height)
            self.size = CGSize(width: width, height: height)
            return
        }

        let cardsHeight = parts.cardsHeight(width)
        let rowY = cardsY + cardsHeight + Self.stackGap
        self.form = .stacked
        self.cards = CGRect(x: 0, y: cardsY, width: width, height: cardsHeight)
        self.rule = .zero
        if Self.summaryMinimum + Self.rowSpacing + narrowest <= width {
            // The result on the left, the buttons on the right, centered on one another.
            let summaryWidth = max(Self.summaryMinimum, width - Self.rowSpacing - wanted)
            let actionsWidth = Self.clamp(
                width - summaryWidth - Self.rowSpacing - Self.clusterGap - parts.button.width, to: parts.actionsWidth)
            let summaryHeight = parts.summaryHeight(summaryWidth)
            let rowHeight = max(summaryHeight, clusterHeight)
            self.summary = CGRect(
                x: 0, y: rowY + (rowHeight - summaryHeight) / 2, width: summaryWidth, height: summaryHeight)
            self.actions = CGRect(
                x: buttonX - Self.clusterGap - actionsWidth, y: rowY + (rowHeight - parts.actionsHeight) / 2,
                width: actionsWidth, height: parts.actionsHeight)
            self.button = CGRect(
                x: buttonX, y: rowY + (rowHeight - parts.button.height) / 2, width: parts.button.width,
                height: parts.button.height)
            self.size = CGSize(width: width, height: rowY + rowHeight)
        } else {
            // Too narrow even for that: the result over the buttons.
            let summaryHeight = parts.summaryHeight(width)
            let clusterBottom = rowY + summaryHeight + Self.columnGap + clusterHeight
            let actionsWidth = Self.clamp(width - Self.clusterGap - parts.button.width, to: parts.actionsWidth)
            self.summary = CGRect(x: 0, y: rowY, width: width, height: summaryHeight)
            self.actions = CGRect(
                x: buttonX - Self.clusterGap - actionsWidth, y: clusterBottom - parts.actionsHeight,
                width: actionsWidth, height: parts.actionsHeight)
            self.button = CGRect(
                x: buttonX, y: clusterBottom - parts.button.height, width: parts.button.width,
                height: parts.button.height)
            self.size = CGSize(width: width, height: clusterBottom)
        }
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

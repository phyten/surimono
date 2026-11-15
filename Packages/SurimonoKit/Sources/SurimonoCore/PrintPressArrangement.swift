import CoreGraphics

/// Where the parts of the print screen's press bar go. SwiftUI only measures the parts; what goes beside what is
/// decided here from plain numbers, so that each step of folding is pinned by a test.
///
/// The bar has two groups. The choices (the paper series and orientation menus over the six layout cards) are on the
/// left; the result and the ways to send it out (what comes out, the printer, PDF and Print) are on the right. The
/// six cards always stand in one row, and neither they nor their titles shrink: the bar is never narrower than that
/// row (`fittingWidth`), which is the narrowest the print screen's window gets. When the window is narrower than both
/// groups need, the bar gives way in this order, each step only when the previous ones are not enough:
///
/// 1. The right group moves to a row of its own under the choices, before the printer's name is cut.
/// 2. The PDF button drops its label and keeps its icon.
/// 3. The printer's name loses its middle, down to `printerMinimum`.
///
/// The name is cut, last, to keep the result's first line on one line: three lines of "Paper A3 · 10 sheets ·
/// Two-Sided" beside a whole printer name read worse than a name whose middle the menu, its hint and VoiceOver give.
///
/// Print, the printer, the result, the copies and the six cards stay on the bar at every width, so printing never
/// takes more than the two steps of choosing a card and pressing Print.
public struct PrintPressArrangement: Equatable, Sendable {
    public enum Form: Equatable, Sendable {
        /// The choices on the left; the result over the printer, PDF and Print on the right.
        case beside
        /// The result, the printer, PDF and Print on a row of their own under the choices.
        case stacked
    }

    /// The sizes SwiftUI measured, each at its ideal size unless said otherwise.
    public struct Parts {
        /// The paper series and orientation menus side by side.
        public var menus: CGSize
        /// One layout card; all six are as large as this.
        public var card: CGSize
        public var cardCount: Int
        /// The result's longest line, unwrapped.
        public var summaryWidth: CGFloat
        /// The result's first line (the paper, sheets and sides), which should not wrap.
        public var summaryLeadWidth: CGFloat
        /// The result's height at a width; its notes wrap.
        public var summaryHeight: (CGFloat) -> CGFloat
        /// The printer menu with its whole name.
        public var printer: CGSize
        /// The PDF button with its label.
        public var pdf: CGSize
        /// The PDF button with its icon alone.
        public var pdfCompactWidth: CGFloat
        /// The Print button.
        public var button: CGSize

        public init(
            menus: CGSize, card: CGSize, cardCount: Int = 6, summaryWidth: CGFloat, summaryLeadWidth: CGFloat,
            summaryHeight: @escaping (CGFloat) -> CGFloat, printer: CGSize, pdf: CGSize, pdfCompactWidth: CGFloat,
            button: CGSize
        ) {
            self.menus = menus
            self.card = card
            self.cardCount = cardCount
            self.summaryWidth = summaryWidth
            self.summaryLeadWidth = summaryLeadWidth
            self.summaryHeight = summaryHeight
            self.printer = printer
            self.pdf = pdf
            self.pdfCompactWidth = pdfCompactWidth
            self.button = button
        }

        /// The cards in their one row.
        public var cardsSize: CGSize {
            CGSize(
                width: CGFloat(cardCount) * card.width
                    + CGFloat(max(cardCount - 1, 0)) * PrintPressArrangement.cardSpacing,
                height: card.height)
        }

        /// The printer's whole name, up to the widest the menu is ever drawn.
        var printerIdeal: CGFloat { min(printer.width, PrintPressArrangement.printerLimit) }
    }

    /// Between neighboring cards.
    public static let cardSpacing: CGFloat = 4
    /// Between the menus and the cards.
    public static let rowGap: CGFloat = 6
    /// Between the choices and the row under them, when stacked.
    public static let stackGap: CGFloat = 8
    /// Between the printer and PDF column and Print.
    public static let clusterGap: CGFloat = 8
    /// Between the printer and the PDF button over it.
    public static let actionGap: CGFloat = 6
    /// Between the result and the buttons under it.
    public static let columnGap: CGFloat = 8
    /// Between the result and the buttons beside it, when stacked.
    public static let rowSpacing: CGFloat = 12
    /// Either side of the rule between the groups.
    public static let ruleGap: CGFloat = 8
    public static let ruleWidth: CGFloat = 1
    public static let ruleSpan = ruleGap + ruleWidth + ruleGap
    /// A result wider than this gains nothing from more room; its notes wrap instead.
    public static let summaryLimit: CGFloat = 340
    /// The widest the result's first line asks for before it may wrap.
    public static let summaryLeadLimit: CGFloat = 260
    /// The widest the printer menu is drawn: a longer name loses its middle even in a wide window.
    public static let printerLimit: CGFloat = 280
    /// The narrowest the printer menu is drawn; below it a name can no longer be told from another.
    public static let printerMinimum: CGFloat = 120

    public let form: Form
    /// Whether the PDF button shows its icon without its label.
    public let pdfIsCompact: Bool
    public let menus: CGRect
    public let cards: CGRect
    public let summary: CGRect
    public let printer: CGRect
    public let pdf: CGRect
    public let button: CGRect
    /// The rule between the groups; empty when they are stacked.
    public let rule: CGRect
    public let size: CGSize

    public init(width: CGFloat, parts: Parts) {
        let oneRow = parts.cardsSize
        let choicesWidth = max(oneRow.width, parts.menus.width)
        let cardsY = parts.menus.height + Self.rowGap
        let printerIdeal = parts.printerIdeal
        let actionsHeight = parts.printer.height + Self.actionGap + parts.pdf.height
        let clusterHeight = max(actionsHeight, parts.button.height)
        let fullActions = max(printerIdeal, parts.pdf.width)
        let fullCluster = fullActions + Self.clusterGap + parts.button.width
        let lead = min(parts.summaryLeadWidth, Self.summaryLeadLimit)
        self.menus = CGRect(origin: .zero, size: parts.menus)

        if choicesWidth + Self.ruleSpan + max(fullCluster, lead) <= width {
            let room = width - choicesWidth - Self.ruleSpan
            let blockWidth = min(room, max(fullCluster, lead, min(parts.summaryWidth, Self.summaryLimit)))
            let summaryHeight = parts.summaryHeight(blockWidth)
            let height = max(cardsY + oneRow.height, summaryHeight + Self.columnGap + clusterHeight)
            let buttonX = width - parts.button.width
            let actionsX = buttonX - Self.clusterGap - fullActions
            let actionsY = height - actionsHeight
            self.form = .beside
            self.pdfIsCompact = false
            self.cards = CGRect(origin: CGPoint(x: 0, y: cardsY), size: oneRow)
            self.summary = CGRect(x: width - blockWidth, y: 0, width: blockWidth, height: summaryHeight)
            self.printer = CGRect(x: actionsX, y: actionsY, width: fullActions, height: parts.printer.height)
            self.pdf = CGRect(
                x: actionsX, y: actionsY + parts.printer.height + Self.actionGap, width: fullActions,
                height: parts.pdf.height)
            self.button = CGRect(
                x: buttonX, y: height - parts.button.height, width: parts.button.width,
                height: parts.button.height)
            self.rule = CGRect(
                x: width - blockWidth - Self.ruleGap - Self.ruleWidth, y: 0, width: Self.ruleWidth, height: height)
            self.size = CGSize(width: width, height: height)
            return
        }

        // Stacked: the choices over a row of the result and the buttons.
        let rowY = cardsY + oneRow.height + Self.stackGap
        let fixed = Self.rowSpacing + Self.clusterGap + parts.button.width
        // The PDF label goes before the printer's name is cut.
        let pdfIsCompact = lead + fixed + fullActions > width
        let pdfNeed = pdfIsCompact ? parts.pdfCompactWidth : parts.pdf.width
        // The printer's name gives way last, to keep the result's first line whole, and never below the width that
        // still tells one name from another; past that the result wraps.
        let printerWidth =
            lead + fixed + max(printerIdeal, pdfNeed) <= width
            ? printerIdeal : min(printerIdeal, max(Self.printerMinimum, width - fixed - lead))
        let actionsWidth = max(printerWidth, pdfNeed)
        let pdfWidth = pdfIsCompact ? parts.pdfCompactWidth : actionsWidth
        let summaryWidth = max(0, width - fixed - actionsWidth)
        let summaryHeight = parts.summaryHeight(summaryWidth)
        let rowHeight = max(summaryHeight, clusterHeight)
        let buttonX = width - parts.button.width
        let actionsX = buttonX - Self.clusterGap - actionsWidth
        let actionsY = rowY + (rowHeight - actionsHeight) / 2
        self.form = .stacked
        self.pdfIsCompact = pdfIsCompact
        self.cards = CGRect(origin: CGPoint(x: 0, y: cardsY), size: oneRow)
        self.rule = .zero
        self.summary = CGRect(
            x: 0, y: rowY + (rowHeight - summaryHeight) / 2, width: summaryWidth, height: summaryHeight)
        self.printer = CGRect(x: actionsX, y: actionsY, width: actionsWidth, height: parts.printer.height)
        // The icon-only button keeps to the leading edge under the printer, where the labeled one began.
        self.pdf = CGRect(
            x: actionsX, y: actionsY + parts.printer.height + Self.actionGap, width: pdfWidth,
            height: parts.pdf.height)
        self.button = CGRect(
            x: buttonX, y: rowY + (rowHeight - parts.button.height) / 2, width: parts.button.width,
            height: parts.button.height)
        self.size = CGSize(width: width, height: rowY + rowHeight)
    }

    /// The width the bar is measured at for a proposed width: the proposal, but never narrower than the menus and the
    /// cards in one row, and with no proposal the width that puts the two groups side by side.
    ///
    /// SwiftUI asks a window's content for its size at zero width to find the window's smallest size, so the cards'
    /// one row is the narrowest the print screen's window can be made, in every language.
    public static func fittingWidth(for proposal: CGFloat?, parts: Parts) -> CGFloat {
        let oneRow = parts.cardsSize.width
        let choices = max(oneRow, parts.menus.width)
        guard let proposal, proposal.isFinite else {
            let cluster = max(parts.printerIdeal, parts.pdf.width) + clusterGap + parts.button.width
            return choices + ruleSpan
                + max(cluster, min(parts.summaryLeadWidth, summaryLeadLimit), min(parts.summaryWidth, summaryLimit))
        }
        return max(proposal, choices)
    }
}

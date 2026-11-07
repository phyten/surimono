import SwiftUI

/// Measures the actual controls of the press bar and moves only their positions, preserving open menus and popovers.
/// Its parts, in this order: the paper row, the layout cards, the result, the printer and PDF buttons, Print and the
/// rule between the two groups. Where each goes is `PrintPressArrangement`'s decision.
struct PrintPressLayout: Layout {
    static let partCount = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == Self.partCount else { return .zero }
        let parts = parts(of: subviews)
        let width =
            proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? parts.cardsWidth + PrintPressArrangement.ruleSpan
            + max(
                parts.actionsWidth.upperBound + PrintPressArrangement.clusterGap + parts.button.width,
                min(parts.summaryWidth, PrintPressArrangement.summaryLimit))
        return PrintPressArrangement(width: width, parts: parts).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == Self.partCount else { return }
        let arrangement = PrintPressArrangement(width: bounds.width, parts: parts(of: subviews))
        let frames = [
            arrangement.paperRow, arrangement.cards, arrangement.summary, arrangement.actions, arrangement.button,
            arrangement.rule,
        ]
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func parts(of subviews: Subviews) -> PrintPressArrangement.Parts {
        let paperRow = subviews[0]
        let cards = subviews[1]
        let summary = subviews[2]
        let actions = subviews[3]
        let button = subviews[4]
        let actionsIdeal = actions.sizeThatFits(.unspecified)
        let actionsNarrowest = min(
            actions.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width, actionsIdeal.width)
        return PrintPressArrangement.Parts(
            paperRow: paperRow.sizeThatFits(.unspecified),
            cardsWidth: cards.sizeThatFits(.unspecified).width,
            cardsHeight: { cards.sizeThatFits(ProposedViewSize(width: $0, height: nil)).height },
            summaryWidth: summary.sizeThatFits(.unspecified).width,
            summaryHeight: { summary.sizeThatFits(ProposedViewSize(width: $0, height: nil)).height },
            actionsWidth: actionsNarrowest...actionsIdeal.width, actionsHeight: actionsIdeal.height,
            button: button.sizeThatFits(.unspecified))
    }
}

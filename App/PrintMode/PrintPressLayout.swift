import SurimonoCore
import SwiftUI

/// Measures the actual controls of the press bar and moves only their positions, so that a change of form keeps open
/// menus, the keyboard focus and the chosen card. Its parts, in this order: the paper menus, the layout cards, the
/// result, the printer menu, the PDF button, Print, the rule between the two groups, and an invisible copy of the
/// result's first line that only measures it. Where each goes is `PrintPressArrangement`'s decision.
struct PrintPressLayout: Layout {
    static let partCount = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == Self.partCount else { return .zero }
        let parts = parts(of: subviews)
        let width = PrintPressArrangement.fittingWidth(for: proposal.width, parts: parts)
        return PrintPressArrangement(width: width, parts: parts).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == Self.partCount else { return }
        let arrangement = PrintPressArrangement(width: bounds.width, parts: parts(of: subviews))
        let frames = [
            arrangement.menus, arrangement.cards, arrangement.summary, arrangement.printer, arrangement.pdf,
            arrangement.button, arrangement.rule, .zero,
        ]
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func parts(of subviews: Subviews) -> PrintPressArrangement.Parts {
        let cards = subviews[1]
        let summary = subviews[2]
        let pdf = subviews[4]
        // The cards answer for one card at zero width: the grid takes the size of its cells from the first card.
        let card = cards.sizeThatFits(ProposedViewSize(width: 0, height: nil))
        return PrintPressArrangement.Parts(
            menus: subviews[0].sizeThatFits(.unspecified),
            card: CGSize(width: card.width, height: card.height),
            summaryWidth: summary.sizeThatFits(.unspecified).width,
            summaryLeadWidth: subviews[7].sizeThatFits(.unspecified).width,
            summaryHeight: { summary.sizeThatFits(ProposedViewSize(width: $0, height: nil)).height },
            printer: subviews[3].sizeThatFits(.unspecified), pdf: pdf.sizeThatFits(.unspecified),
            pdfCompactWidth: pdf.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width,
            button: subviews[5].sizeThatFits(.unspecified))
    }
}

/// The layout cards in one row, every cell as large as the first card: the cards never shrink, and the press bar is
/// never narrower than their row.
struct PrintCardGrid: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let cell = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        // At zero width the grid tells the size of one card, which the press bar arranges the cards by.
        if proposal.width == 0 { return cell }
        let spacing = PrintPressArrangement.cardSpacing
        return CGSize(
            width: CGFloat(subviews.count) * cell.width + CGFloat(max(subviews.count - 1, 0)) * spacing,
            height: cell.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let cell = subviews.first?.sizeThatFits(.unspecified) else { return }
        let spacing = PrintPressArrangement.cardSpacing
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (cell.width + spacing), y: bounds.minY),
                proposal: ProposedViewSize(cell))
        }
    }
}

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

/// The layout cards in as many columns as the width they are given holds: all of them in one row, otherwise three.
/// Every cell is as large as the first card, so the cards never shrink to keep a row.
struct PrintCardGrid: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let cell = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        // At zero width the grid tells the size of one card, which the press bar arranges the cards by.
        if proposal.width == 0 { return cell }
        return size(
            columns: columns(for: proposal.width, cell: cell, count: subviews.count), cell: cell,
            count: subviews.count)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let cell = subviews.first?.sizeThatFits(.unspecified) else { return }
        let columns = columns(for: bounds.width, cell: cell, count: subviews.count)
        let spacing = PrintPressArrangement.cardSpacing
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index % columns) * (cell.width + spacing)
            let y = bounds.minY + CGFloat(index / columns) * (cell.height + spacing)
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(cell))
        }
    }

    private func columns(for width: CGFloat?, cell: CGSize, count: Int) -> Int {
        guard let width else { return max(count, 1) }
        return size(columns: count, cell: cell, count: count).width <= width + 0.5 ? max(count, 1) : min(3, count)
    }

    private func size(columns: Int, cell: CGSize, count: Int) -> CGSize {
        let columns = max(columns, 1)
        let rows = (count + columns - 1) / columns
        let spacing = PrintPressArrangement.cardSpacing
        return CGSize(
            width: CGFloat(columns) * cell.width + CGFloat(columns - 1) * spacing,
            height: CGFloat(rows) * cell.height + CGFloat(max(rows - 1, 0)) * spacing)
    }
}

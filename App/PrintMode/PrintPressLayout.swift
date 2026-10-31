import SwiftUI

/// Measures the actual controls and moves only their positions, preserving open menus and popovers.
struct PrintPressLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width, subviews: subviews)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in frames(width: bounds.width, subviews: subviews).enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat?, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 4 else { return [] }
        var sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // The summary's minimum includes the full orientation label, not the unwrapped summary text.
        sizes[1] = subviews[1].sizeThatFits(ProposedViewSize(width: 0, height: nil))
        let available = width ?? sizes.map(\.width).reduce(0, +) + 36
        let arrangement = Arrangement(width: available, minimumWidths: sizes.map(\.width))
        sizes[1] = subviews[1].sizeThatFits(ProposedViewSize(width: arrangement.summaryWidth, height: nil))
        let rowHeight = max(88, sizes.dropFirst(arrangement.wraps ? 1 : 0).map(\.height).max() ?? 0)
        var frames: [CGRect] = []
        var x: CGFloat = 0
        let rowY = arrangement.wraps ? sizes[0].height + 8 : 0
        for index in sizes.indices {
            let size = sizes[index]
            if index == 0 && arrangement.wraps {
                frames.append(CGRect(x: (available - size.width) / 2, y: 0, width: size.width, height: size.height))
            } else {
                frames.append(
                    CGRect(x: x, y: rowY + (rowHeight - size.height) / 2, width: size.width, height: size.height))
                x += size.width + 12
            }
        }
        return frames
    }

    struct Arrangement {
        let wraps: Bool
        let summaryWidth: CGFloat

        init(width: CGFloat, minimumWidths: [CGFloat]) {
            wraps = minimumWidths.reduce(0, +) + 36 > width
            let occupied = minimumWidths[2] + minimumWidths[3] + (wraps ? 24 : minimumWidths[0] + 36)
            summaryWidth = max(minimumWidths[1], width - occupied)
        }
    }
}

/// Allows two-line text in a narrow column while retaining the orientation menu's intrinsic width.
struct PrintSummaryColumnLayout: Layout {
    private func columnProposal(_ proposal: ProposedViewSize, subviews: Subviews) -> ProposedViewSize {
        let minimum = max(150, subviews.first?.sizeThatFits(.unspecified).width ?? 0)
        return ProposedViewSize(width: max(minimum, proposal.width ?? minimum), height: nil)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposal = columnProposal(proposal, subviews: subviews)
        let heights = subviews.map { $0.sizeThatFits(proposal).height }
        return CGSize(
            width: proposal.width ?? 150,
            height: heights.reduce(0, +) + 3 * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let proposal = columnProposal(ProposedViewSize(bounds.size), subviews: subviews)
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(proposal)
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(size))
            y += size.height + 3
        }
    }
}

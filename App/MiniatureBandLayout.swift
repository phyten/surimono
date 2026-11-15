import SwiftUI

/// Reserve the title and both zones before wrapping chips. A crowded band grows vertically, never across its neighbour.
struct MiniatureBandLayout: Layout {
    var fixedPrefix: Int
    private let gap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (view, frame) in zip(subviews, result.frames) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let left = fixedPrefix
        let right = left + 1
        let fixed = ideal.enumerated().filter { $0.offset != left && $0.offset != right }
            .reduce(CGFloat.zero) { $0 + $1.element.width }
        let gaps = gap * CGFloat(max(0, subviews.count - 1))
        // A parent may propose no width, or an infinite one to ask for the largest size. Both lay out at the natural
        // width, so that no frame is infinite.
        let natural = ideal.reduce(0) { $0 + $1.width } + gaps
        let width = width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? natural
        let room = max(0, width - fixed - gaps)
        let leftMinimum = subviews[left].sizeThatFits(.zero).width
        let rightMinimum = subviews[right].sizeThatFits(.zero).width
        let stacked = leftMinimum + rightMinimum > room
        let leftWidth =
            stacked
            ? max(leftMinimum, room) : min(room - rightMinimum, min(ideal[left].width, max(leftMinimum, room / 2)))
        let rightWidth = stacked ? max(rightMinimum, room) : max(rightMinimum, room - leftWidth)
        let sizes = ideal.enumerated().map { index, size in
            if index == left || index == right {
                return subviews[index].sizeThatFits(
                    ProposedViewSize(width: index == left ? leftWidth : rightWidth, height: nil))
            }
            return size
        }
        let height =
            stacked
            ? max(sizes[left].height + gap + sizes[right].height, sizes.map(\.height).max() ?? 0)
            : sizes.map(\.height).max() ?? 0
        var x: CGFloat = 0
        var frames: [CGRect] = []
        for (index, size) in sizes.enumerated() {
            if index == right && stacked {
                frames.append(
                    CGRect(x: frames[left].minX, y: sizes[left].height + gap, width: size.width, height: size.height))
                x = max(frames[left].maxX, frames[right].maxX) + gap
            } else {
                if index == right && !stacked {
                    let suffix = sizes.dropFirst(right + 1)
                    let suffixWidth = suffix.reduce(CGFloat.zero) { $0 + $1.width } + gap * CGFloat(suffix.count)
                    x = max(x, width - suffixWidth - size.width)
                }
                frames.append(
                    CGRect(x: x, y: stacked ? 0 : (height - size.height) / 2, width: size.width, height: size.height))
                // Keep the flexible middle between the two zones.
                x += (index == left && !stacked ? leftWidth : size.width) + gap
            }
        }
        return (frames, CGSize(width: max(width, (frames.map(\.maxX).max() ?? 0)), height: height))
    }
}

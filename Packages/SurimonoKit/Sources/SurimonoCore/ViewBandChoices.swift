import CoreGraphics
import Foundation

/// How the view mode's menu is arranged around the paper.
public enum MenuArrangement: String, CaseIterable, Codable, Sendable {
    case top, split

    /// The bands, each of which takes room beside the paper while it shows.
    public var bandCount: Int { self == .split ? 2 : 1 }
}

/// When the bands show. Bands that always show have their own room beside the paper; bands that show on pointing take
/// it only while they show, and the window is the paper alone in between.
public enum BandVisibility: String, CaseIterable, Codable, Sendable {
    case onHover, always
}

public enum OutlinePresentation: String, CaseIterable, Codable, Sendable {
    case popover, drawer
}

/// What the view mode does after a saved change redraws the paper.
public enum ChangeFollowing: String, CaseIterable, Codable, Sendable {
    case jump, mark, ask
}

public enum ChangeNavigation {
    /// The next page with a change after `page`, going round to the first one.
    public static func next(after page: Int, in pages: [Int]) -> Int? {
        let sorted = pages.sorted()
        return sorted.first { $0 > page } ?? sorted.first
    }

    /// The target viewport in screen points, with the current viewport starting at (0, 0) and y increasing downward.
    /// At fit the usual page turn is sufficient unless the mark touches the pinned band.
    public static func targetViewport(
        for mark: CGRect, size: CGSize, zoomed: Bool, pinnedBandHeight: CGFloat
    ) -> CGRect {
        var target = CGRect(origin: .zero, size: size)
        guard !mark.isEmpty, !target.isEmpty else { return target }
        if zoomed {
            target.origin.y = mark.height <= size.height ? mark.midY - size.height / 2 : mark.minY - 12
            if mark.width > size.width {
                target.origin.x = mark.minX
            } else {
                target.origin.x = max(mark.maxX - size.width, min(0, mark.minX))
            }
        } else if pinnedBandHeight > 0 {
            target.origin.y = min(0, mark.minY - pinnedBandHeight)
        }
        return target
    }
}

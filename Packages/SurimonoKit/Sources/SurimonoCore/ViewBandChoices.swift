import Foundation

/// How the view mode's menu is arranged around the paper.
public enum MenuArrangement: String, CaseIterable, Codable, Sendable {
    case top, split

    /// The bands that take room beside the paper.
    public var bandCount: Int { self == .split ? 2 : 1 }
}

/// When the bands show their contents. Their room stays either way, so the window never changes with the pointer.
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

/// The family of paper the view mode lays text out on. A4 and B5 are nearly the same shape, so switching keeps the
/// window's shape and changes how much fits on a page.
public enum ViewPaperSeries: String, CaseIterable, Codable, Sendable {
    case a, b

    public var layout: PrintLayout { self == .a ? .a4Single : .b5Single }
}

public enum ChangeNavigation {
    /// The next page with a change after `page`, going round to the first one.
    public static func next(after page: Int, in pages: [Int]) -> Int? {
        let sorted = pages.sorted()
        return sorted.first { $0 > page } ?? sorted.first
    }
}

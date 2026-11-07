import CoreGraphics

/// How the comparison stage sets out its candidates. Four pages across leave each too small to read in a narrow
/// window, whatever the window's height, so the stage goes to two across, and then to one, before a page gets
/// narrower than `minimumCardWidth`. What does not fit the stage's height then scrolls.
public struct ThemeCompareLayout: Equatable, Sendable {
    public static let minimumCardWidth: CGFloat = 280
    public static let maximumCardWidth: CGFloat = 420
    /// A window too small for even one page of the minimum width; the page shrinks to this rather than vanish.
    private static let smallestCardWidth: CGFloat = 120
    /// Between cards, and from the stage's edge to the first and last card.
    public static let gap: CGFloat = 24
    public static let margin: CGFloat = 32
    public static let topInset: CGFloat = 16
    /// A card's parts besides its page, and the space between them.
    public static let tagRowHeight: CGFloat = 20
    public static let nameRowHeight: CGFloat = 34
    public static let buttonHeight: CGFloat = 28
    public static let rowSpacing: CGFloat = 8
    private static let cardChrome: CGFloat = tagRowHeight + nameRowHeight + buttonHeight + rowSpacing * 3

    public let columns: Int
    public let cardWidth: CGFloat

    /// - Parameters:
    ///   - stage: The room for the cards, under the top bar and above the row of candidates to add.
    ///   - paper: The size of the sampled page, whose shape gives the height of a card.
    ///   - capacity: How many candidates the stage holds.
    public init(stage: CGSize, paper: CGSize, capacity: Int = ThemeComparison.capacity) {
        let aspect = max(paper.height, 1) / max(paper.width, 1)
        func widthAcross(_ count: Int) -> CGFloat {
            (stage.width - Self.margin * 2 - Self.gap * CGFloat(count - 1)) / CGFloat(count)
        }
        let most = max(capacity, 1)
        // The columns follow the width alone: a short window keeps its pages side by side and scrolls instead.
        let columns = [most, 2, 1].first { $0 <= most && widthAcross($0) >= Self.minimumCardWidth } ?? 1
        let room = widthAcross(columns)
        // The widest page whose row, with its name and button, still fits the stage's height.
        let fitsHeight = (stage.height - Self.topInset - Self.cardChrome) / aspect
        let width = max(min(room, fitsHeight, Self.maximumCardWidth), min(Self.minimumCardWidth, room))
        self.columns = columns
        self.cardWidth = max(width, Self.smallestCardWidth)
    }
}

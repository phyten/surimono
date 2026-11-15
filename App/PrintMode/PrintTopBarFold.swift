import CoreGraphics

/// What the print screen's top bar leaves out at a given width. The file name keeps room for about 120 points at
/// every width, so it never vanishes or turns into a letter; the parts around it give way first, one step at a time and
/// always in the same order.
struct PrintTopBarFold: Equatable {
    enum Step: Int, CaseIterable, Comparable {
        /// The "esc" tag on Back to View; the hint keeps the key.
        case escTag
        /// The name of the setting set in use; the menu and its hint keep it.
        case setName
        /// The page count beside the file name; the tray's own instructions keep it.
        case pageCount
        /// The word "Style" (or "Preset") before the style's name.
        case styleTitle
        /// The words of Back to View, leaving its arrow; the hint and VoiceOver keep them.
        case backTitle
        /// The words "Setting Sets", leaving the menu's icon; its hint and VoiceOver keep them.
        case setsTitle

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How many steps, from the first, are taken.
    let foldedCount: Int
    /// The widest the style's name is drawn, when even the last step leaves the bar too wide (a long name of the
    /// reader's own style); nil while the name fits whole.
    let styleNameLimit: CGFloat?

    /// The narrowest a cut style name is drawn: a few letters from each end.
    static let styleNameMinimum: CGFloat = 48

    /// - Parameters:
    ///   - available: The bar's width.
    ///   - needed: The width the bar needs with none of the steps taken, then with the first, the first two, and so on;
    ///     one more value than there are steps.
    ///   - styleNameWidth: The style's name, whole.
    init(available: CGFloat, needed: [CGFloat], styleNameWidth: CGFloat = 0) {
        foldedCount = min(needed.firstIndex { $0 <= available } ?? Step.allCases.count, Step.allCases.count)
        if let last = needed.last, last > available, styleNameWidth > 0 {
            styleNameLimit = max(Self.styleNameMinimum, styleNameWidth - (last - available))
        } else {
            styleNameLimit = nil
        }
    }

    func folds(_ step: Step) -> Bool { step.rawValue < foldedCount }
}

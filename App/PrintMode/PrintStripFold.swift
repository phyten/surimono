import CoreGraphics

/// How the strip of print settings over the press bar fits its row. The row never wraps and never sets the window's
/// smallest width: when its menus and "All Print Settings…" do not fit, the button first shows its icon alone, and
/// then the menus become one menu that holds each of them. Nothing is lost on the way: the sheet of all settings has
/// every one of them.
struct PrintStripFold: Equatable {
    enum Form: Equatable {
        /// Every menu, and "All Print Settings…" with its label.
        case full
        /// Every menu, and the icon of "All Print Settings…".
        case iconDetails
        /// One menu that holds the others, and the icon of "All Print Settings…".
        case combined
    }

    let form: Form

    /// - Parameters:
    ///   - available: The width of the row between its margins.
    ///   - itemWidths: The width each menu takes in its current form, in the order of the row.
    ///   - detailsWidth: The width of "All Print Settings…" with its label.
    ///   - detailsIconWidth: The width of its icon alone.
    ///   - spacing: The gap between neighbors. The row's spacer has one on each side, so the last menu and the button
    ///     are two gaps apart however little room the spacer gets.
    init(
        available: CGFloat, itemWidths: [CGFloat], detailsWidth: CGFloat, detailsIconWidth: CGFloat, spacing: CGFloat
    ) {
        let menus = itemWidths.reduce(0) { $0 + spacing + $1 }
        if menus + spacing + detailsWidth <= available {
            form = .full
        } else if menus + spacing + detailsIconWidth <= available {
            form = .iconDetails
        } else {
            form = .combined
        }
    }
}

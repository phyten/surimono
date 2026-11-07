import CoreGraphics

/// Which of the strip's menus stay in its row. The row never wraps and "All Print Settings…" stays at its right end, so
/// when the menus do not all fit they fold from the right. A folded menu loses nothing: the sheet of all settings has
/// every one of them.
struct PrintStripFold: Equatable {
    /// How many of the menus, counted from the left, stay in the row.
    let visibleCount: Int

    /// - Parameters:
    ///   - available: The width of the row between its margins.
    ///   - itemWidths: The width each menu takes in its current form, in the order of the row.
    ///   - trailingWidth: The width of the button that stays at the right end.
    ///   - spacing: The gap between neighbors. The row's spacer has one on each side, so the last menu and the button
    ///     are two gaps apart however little room the spacer gets.
    init(available: CGFloat, itemWidths: [CGFloat], trailingWidth: CGFloat, spacing: CGFloat) {
        var used = trailingWidth + spacing
        var count = 0
        for width in itemWidths {
            used += spacing + width
            guard used <= available else { break }
            count += 1
        }
        visibleCount = count
    }
}

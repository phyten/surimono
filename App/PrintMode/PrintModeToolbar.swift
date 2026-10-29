import SwiftUI

/// Stands in for the document toolbar while the print mode hides its items.
///
/// Without any item SwiftUI removes the window's toolbar: the title bar then shrinks, the traffic lights leave the
/// middle of the tray's top bar, and the title bar starts taking the clicks meant for the top bar's buttons.
struct PrintModeToolbarPlaceholder: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem { placeholder }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem { placeholder }
        }
    }

    private var placeholder: some View {
        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
    }
}

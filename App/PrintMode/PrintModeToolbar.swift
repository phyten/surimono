import SwiftUI

/// Stands in for the document toolbar while the print mode hides its items.
///
/// Without any item SwiftUI removes the window's toolbar: the title bar then shrinks, the traffic lights leave the
/// middle of the tray's top bar, and the title bar starts taking the clicks meant for the top bar's buttons.
///
/// The item is hidden, not merely invisible. A visible item, even one of an empty 1×1 view without its shared
/// background, gets an item viewer of 44pt by the full title bar height right after the traffic lights; the title bar
/// is in front of the content, so that viewer took the clicks over the left part of "Back to View" (other placements
/// only move it onto other controls). A hidden item keeps the toolbar, and with it the title bar's height and the
/// traffic lights' place, but has no viewer, so the toolbar lets every click through to the top bar.
struct PrintModeToolbarPlaceholder: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }.hidden()
    }
}

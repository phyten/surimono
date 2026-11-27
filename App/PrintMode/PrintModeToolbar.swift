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
private struct PrintModeToolbarPlaceholder: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }.hidden()
    }
}

extension View {
    @ViewBuilder func documentStageToolbar(_ model: DocumentViewModel) -> some View {
        if #available(macOS 26, *) {
            toolbar { [mode = model.mode] in
                if mode != .view { PrintModeToolbarPlaceholder() }
            }
        } else {
            // Handle both mode changes and windows first attached while already printing (e.g. a binder).
            background {
                WindowReader { [weak model] window in
                    guard let model, !model.isWindowClosed else { return }
                    SequoiaStageToolbar.update(window, onStage: model.mode != .view)
                }
                .id(model.mode)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Keep the traffic lights in the compact top bar without installing any item in front of its controls.
private final class SequoiaStageToolbar: NSToolbar {
    let readingStyle: NSWindow.ToolbarStyle

    init(readingStyle: NSWindow.ToolbarStyle) {
        self.readingStyle = readingStyle
        super.init(identifier: "SurimonoStage")
    }

    static func update(_ window: NSWindow, onStage: Bool) {
        if onStage, window.toolbar == nil {
            let toolbar = SequoiaStageToolbar(readingStyle: window.toolbarStyle)
            window.toolbarStyle = .unifiedCompact
            window.toolbar = toolbar
        } else if !onStage, let toolbar = window.toolbar as? SequoiaStageToolbar {
            window.toolbar = nil
            window.toolbarStyle = toolbar.readingStyle
        }
    }
}

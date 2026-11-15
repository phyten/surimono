import AppKit
import SwiftUI

/// The × that closes a popover, at the right end of its heading row: the same button the side panels and the find bar
/// close with. It also makes Esc close the popover while one of its fields has the focus, as its tooltip says: a
/// focused text field keeps Esc to itself.
struct PopoverCloseButton: View {
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
        @State private var id = UUID()
    #endif

    var body: some View {
        PanelIconButton("xmark", label: "Close", help: "Close (Esc)") { dismiss() }
            .background {
                Button {
                    dismiss()
                } label: {
                    EmptyView()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .focusable(false)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            #if DEBUG
                .background {
                    WindowReader { [id, dismiss] window in Self.shown[id] = Shown(window: window, dismiss: dismiss) }
                }
                .onDisappear { Self.shown[id] = nil }
            #endif
    }

    #if DEBUG
        /// A × on screen and the window it is in, for tests: hosted tests have no accessibility client, so SwiftUI
        /// builds no accessibility tree to find the buttons in.
        struct Shown {
            weak var window: NSWindow?
            let dismiss: DismissAction
        }

        static var shown: [UUID: Shown] = [:]

        /// What the ×s in a window do.
        static func dismissActions(in window: NSWindow) -> [DismissAction] {
            shown.values.filter { $0.window === window }.map(\.dismiss)
        }
    #endif
}

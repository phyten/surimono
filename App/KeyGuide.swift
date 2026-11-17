import AppKit
import SurimonoCore
import SwiftUI

// The guide and paper adapter read the same catalog; cancellation and focus traversal stay fixed.
enum KeyGuideEntry: CaseIterable {
    case menu, alwaysShowToolbar, viewOptions, selectText, alternateDrag, pageEdge, doubleClick, pinch
    case find, findStep, goToPage, reload
    case print, systemPrint, printLayouts, escape
    case moveSelection, removeFromList, showList

    var trigger: String { trigger(controller: .shared) }

    func trigger(controller: ShortcutController) -> String {
        let text =
            switch self {
            case .menu:
                (["Tab", "⇧Tab"] + controller.localKeys(for: .viewToolbarToggle).map { controller.layout.display($0) })
                    .joined(separator: " / ")
            case .alwaysShowToolbar: ShortcutHints.keys([.viewToolbarAlways], controller: controller)
            case .viewOptions: shortcutHint(.viewOptions, controller: controller)
            case .selectText: shortcutHint(.viewSelectText, controller: controller)
            case .alternateDrag: String(localized: "Hold ⌥")
            case .pageEdge: String(localized: "Click a paper edge")
            case .doubleClick: String(localized: "Double-click")
            case .pinch: String(localized: "Pinch / ⌘-scroll")
            case .find: ShortcutHints.keys([.documentFind], controller: controller)
            case .findStep: ShortcutHints.keys([.documentFindNext, .documentFindPrevious], controller: controller)
            case .goToPage: ShortcutHints.keys([.documentGoToPage], controller: controller)
            case .reload: ShortcutHints.keys([.documentReload], controller: controller)
            case .print: ShortcutHints.keys([.documentPrint], controller: controller)
            case .systemPrint: ShortcutHints.keys([.documentPrintSystem], controller: controller)
            case .printLayouts: ShortcutHints.keys(ShortcutHints.layouts, controller: controller)
            case .escape: "Esc"
            case .moveSelection: ShortcutHints.keys([.listMoveUp, .listMoveDown], controller: controller)
            case .removeFromList: shortcutHint(.listRemove, controller: controller)
            case .showList: ShortcutHints.keys([.listToggle], controller: controller)
            }
        return text.isEmpty ? String(localized: "Unassigned") : text
    }

    private func shortcutHint(_ operation: ShortcutOperationID, controller: ShortcutController) -> String {
        ShortcutHints.keys([operation], controller: controller)
    }

    var explanation: String {
        switch self {
        case .menu: String(localized: "Show or hide the toolbar")
        // The View menu is the one place of this switch, so the guide names it as the menu does.
        case .alwaysShowToolbar: String(localized: "Always Show Toolbar")
        case .viewOptions: String(localized: "Open view options")
        case .selectText: String(localized: "Select text ⇄ move paper")
        case .alternateDrag: String(localized: "Swap what dragging the paper does")
        case .pageEdge: String(localized: "Turn the page")
        case .doubleClick: String(localized: "Zoom ⇄ fit to window")
        case .pinch: String(localized: "Zoom in and out; drag paper that does not fit to move it")
        case .find: String(localized: "Find in the document; Esc closes the find bar")
        case .findStep: String(localized: "Go to the next or previous match")
        case .goToPage: String(localized: "Go to a page by its number")
        case .reload: String(localized: "Reload the document")
        case .print: String(localized: "Open the print screen; print when on it")
        case .systemPrint: String(localized: "Open the system print dialog")
        case .printLayouts: String(localized: "Choose a layout and open the print screen")
        case .escape: String(localized: "Hide the toolbar; leave the print screen")
        case .moveSelection: String(localized: "Move the selected document or image")
        case .removeFromList: String(localized: "Remove from List")
        case .showList: String(localized: "Show or hide the list")
        }
    }

    static func fixedPaperAction(for event: NSEvent) -> Self? {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return nil }
        if event.specialKey == .tab { return .menu }
        if event.keyCode == 53 { return .escape }
        return nil
    }

    static func paperAction(for event: NSEvent, controller: ShortcutController = .shared) -> Self? {
        if let fixed = fixedPaperAction(for: event) { return fixed }
        switch ShortcutSurfaceKeys.match(event, region: .paperReading, controller: controller) {
        case .viewToolbarToggle: return .menu
        case .viewOptions: return .viewOptions
        case .viewSelectText: return .selectText
        default: return nil
        }
    }
}

struct KeyGuide: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    ForEach(KeyGuideEntry.allCases, id: \.self) { entry in
                        GridRow(alignment: .top) {
                            let trigger = entry.trigger
                            Text(verbatim: trigger)
                                .font(
                                    .system(
                                        size: 12,
                                        design: trigger == String(localized: "Unassigned") ? .default : .monospaced))
                            Text(verbatim: entry.explanation)
                                .font(.system(size: 12))
                        }
                    }
                }
                .foregroundStyle(Color.primary)
                Divider()
                Text("Paper keys work when the paper has focus.")
                Text(
                    "Edge clicks and double-click zoom work when text selection is off. Edge clicks also require fit-to-window and non-continuous page turns."
                )
                Text("On the print screen, Esc closes the folded preview first if it is open.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(24)
        }
        .foregroundStyle(.primary)
        .frame(minWidth: 500, minHeight: 440)
    }
}

@MainActor
final class KeyGuideWindow {
    static let shared = KeyGuideWindow()
    private var window: NSWindow?

    private init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // A separate window works from both DocumentGroup and AppKit-hosted image bundles, even without a document.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Keys and Gestures")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: KeyGuide())
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

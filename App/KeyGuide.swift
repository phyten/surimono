import AppKit
import SwiftUI

// The paper dispatches through these entries so the guide cannot silently lose a handled key.
enum KeyGuideEntry: CaseIterable {
    case menu, viewOptions, selectText, alternateDrag, pageEdge, doubleClick
    case print, systemPrint, printLayouts, escape

    var trigger: String {
        switch self {
        case .menu: "Tab / M"
        case .viewOptions: "V"
        case .selectText: "T"
        case .alternateDrag: String(localized: "Hold ⌥")
        case .pageEdge: String(localized: "Click a paper edge")
        case .doubleClick: String(localized: "Double-click")
        case .print: "⌘P"
        case .systemPrint: "⌥⌘P"
        case .printLayouts: "⌘1–⌘6"
        case .escape: "Esc"
        }
    }

    var explanation: String {
        switch self {
        case .menu: String(localized: "Show or hide the menu band")
        case .viewOptions: String(localized: "Open view options")
        case .selectText: String(localized: "Select text ⇄ move paper")
        case .alternateDrag: String(localized: "Swap what dragging the paper does")
        case .pageEdge: String(localized: "Turn the page")
        case .doubleClick: String(localized: "Zoom ⇄ fit to window")
        case .print: String(localized: "Open the print tray; print when on the tray")
        case .systemPrint: String(localized: "Open the system print dialog")
        case .printLayouts: String(localized: "Choose a layout and open the print tray")
        case .escape: String(localized: "Hide the menu band; leave the print tray")
        }
    }

    static func paperAction(for event: NSEvent) -> Self? {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return nil }
        if event.specialKey == .tab { return .menu }
        if event.keyCode == 53 { return .escape }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m": return .menu
        case "v": return .viewOptions
        case "t": return .selectText
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
                            Text(verbatim: entry.trigger)
                                .font(.system(size: 12, design: .monospaced))
                            Text(verbatim: entry.explanation)
                                .font(.system(size: 12))
                        }
                    }
                }
                .foregroundStyle(Color.primary)
                Divider()
                Text("Paper keys work when the paper has focus. A pinned menu band stays visible.")
                Text(
                    "Edge clicks and double-click zoom work when text selection is off. Edge clicks also require fit-to-window and non-continuous page turns."
                )
                Text("On the print tray, Esc closes the folded preview first if it is open.")
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

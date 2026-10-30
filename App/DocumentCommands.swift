import SurimonoCore
import SwiftUI

struct DocumentCommands: Commands {
    private var model: DocumentViewModel? { DocumentWindows.shared.activeModel }
    private var language: String { model?.language ?? Bundle.main.preferredLocalizations.first ?? "en" }

    var body: some Commands {
        // A viewer creates nothing. The standard Open… item stays: AppDelegate answers its action so that a multi-file
        // selection reaches OpenRouter, and Open Recent opens a single file.
        CommandGroup(replacing: .newItem) {}
        // SwiftUI applies a new enabled state to these items only when a menu opens, so a state derived from the key
        // window's model goes stale and swallows the shortcuts. The items stay enabled; the model ignores what it
        // cannot do.
        CommandGroup(replacing: .printItem) {
            // On the tray ⌘P prints right away, so the item loses its ellipsis there.
            Button(model?.mode == .print ? LocalizedStringKey("Print") : LocalizedStringKey("Print…")) {
                model?.performPrintCommand()
            }
            .keyboardShortcut("p")
            Button("Print with System Dialog…") { model?.printDocument(quick: false) }
                .keyboardShortcut("p", modifiers: [.option, .command])
            Button("Export as PDF…") { model?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.shift, .command])
        }
        CommandGroup(after: .toolbar) {
            // Names where the item goes, as the print item does; HTML only, and nothing happens for other documents.
            Button(
                model?.htmlPresentation == .paper
                    ? LocalizedStringKey("Show as Web") : LocalizedStringKey("Show as Paper")
            ) {
                model?.toggleHTMLPresentation()
            }
            .keyboardShortcut("p", modifiers: [.control, .command])
            Divider()
            ForEach(Array(ViewOptions.Layout.allCases.enumerated()), id: \.element) { index, layout in
                Button(layout.title) { model?.setLayout(layout) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.option, .command])
            }
            Button("View Options…") {
                guard let model, model.mode == .view else { return }
                model.isViewOptionsPresented = true
            }
            Divider()
            Button("Increase Text Size") { model?.increaseTextSize() }
                .keyboardShortcut("+", modifiers: [.option, .command])
            Button("Decrease Text Size") { model?.decreaseTextSize() }
                .keyboardShortcut("-", modifiers: [.option, .command])
            Button("Original Text Size") { model?.resetTextSize() }
                .keyboardShortcut("0", modifiers: [.option, .command])
            Divider()
            Button("Zoom In") { model?.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { model?.zoomOut() }
                .keyboardShortcut("-")
            Button("Fit to Window") { model?.zoomToFit() }
                .keyboardShortcut("0")
            Divider()
            Toggle(
                "Select Text",
                isOn: Binding(
                    get: { model?.isSelectingText ?? false }, set: { _ in model?.toggleSelectingText() })
            )
            Toggle(
                "Keep Menu Visible",
                isOn: Binding(get: { model?.isMenuPinned ?? false }, set: { model?.isMenuPinned = $0 })
            )
            .keyboardShortcut("t", modifiers: [.option, .command])
            Toggle(
                "Float on Top",
                isOn: Binding(get: { model?.isAlwaysOnTop ?? false }, set: { model?.isAlwaysOnTop = $0 })
            )
            Divider()
            Button("Reset Document Settings") { model?.resetDocumentSettings() }
            Button("Reload") { model?.reload() }
        }
        CommandMenu("Layout") {
            ForEach(Array(PrintLayout.presets.enumerated()), id: \.element.id) { index, layout in
                Button(layout.displayName(language: language)) { model?.chooseLayout(layout.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
        }
        CommandMenu("Images") {
            Toggle(
                "Show Thumbnails",
                isOn: Binding(get: { model?.isDrawerOpen ?? false }, set: { model?.isDrawerOpen = $0 })
            )
            .keyboardShortcut("s", modifiers: [.control, .command])
            Button("Move Image Up") { model?.imageBundle?.moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            Button("Move Image Down") { model?.imageBundle?.moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            Button("Sort by Name") { model?.imageBundle?.sortByName() }
        }
    }
}

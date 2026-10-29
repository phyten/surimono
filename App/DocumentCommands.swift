import SurimonoCore
import SwiftUI

struct DocumentCommands: Commands {
    private var model: DocumentViewModel? { DocumentWindows.shared.activeModel }
    private var language: String { model?.language ?? Bundle.main.preferredLocalizations.first ?? "en" }

    var body: some Commands {
        // A viewer creates nothing. The standard Open… item stays: AppDelegate answers its action so that a multi-file
        // selection reaches OpenRouter, and Open Recent opens a single file.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .printItem) {
            Button("Print…") { model?.printDocument() }
                .keyboardShortcut("p").disabled(model?.canOutput != true)
            Button("Quick Print") { model?.printDocument(quick: true) }
                .keyboardShortcut("p", modifiers: [.option, .command]).disabled(model?.canOutput != true)
            Button("Export as PDF…") { model?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.shift, .command]).disabled(model?.canOutput != true)
        }
        CommandGroup(after: .toolbar) {
            ForEach(Array(ViewOptions.Layout.allCases.enumerated()), id: \.element) { index, layout in
                Button(layout.title) { model?.setLayout(layout) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.option, .command])
                    .disabled(model == nil)
            }
            Button("View Options…") { model?.isViewOptionsPresented = true }
                .disabled(model == nil)
            Divider()
            Button("Zoom In") { model?.paper.zoomIn() }
                .keyboardShortcut("+").disabled(model == nil)
            Button("Zoom Out") { model?.paper.zoomOut() }
                .keyboardShortcut("-").disabled(model == nil)
            Button("Fit to Window") { model?.paper.zoomToFit() }
                .keyboardShortcut("0").disabled(model == nil)
            Divider()
            Toggle(
                "Keep Menu Visible",
                isOn: Binding(get: { model?.isMenuPinned ?? false }, set: { model?.isMenuPinned = $0 })
            )
            .keyboardShortcut("t", modifiers: [.option, .command]).disabled(model == nil)
            Toggle(
                "Float on Top",
                isOn: Binding(get: { model?.isAlwaysOnTop ?? false }, set: { model?.isAlwaysOnTop = $0 })
            )
            .disabled(model == nil)
            Divider()
            Button("Reset Document Settings") { model?.resetDocumentSettings() }
                .disabled(model?.hasSavedSettings != true)
            Button("Reload") { model?.reload() }.disabled(model == nil)
        }
        CommandMenu("Layout") {
            ForEach(Array(PrintLayout.presets.enumerated()), id: \.element.id) { index, layout in
                Button(layout.displayName(language: language)) { model?.layoutID = layout.id }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(model == nil)
            }
        }
        CommandMenu("Images") {
            Toggle(
                "Show Thumbnails",
                isOn: Binding(get: { model?.isDrawerOpen ?? false }, set: { model?.isDrawerOpen = $0 })
            )
            .keyboardShortcut("s", modifiers: [.control, .command]).disabled(model?.imageBundle == nil)
            Button("Move Image Up") { model?.imageBundle?.moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(model?.imageBundle?.canMoveSelection(by: -1) != true)
            Button("Move Image Down") { model?.imageBundle?.moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(model?.imageBundle?.canMoveSelection(by: 1) != true)
            Button("Sort by Name") { model?.imageBundle?.sortByName() }
                .disabled(model?.imageBundle == nil)
        }
    }
}

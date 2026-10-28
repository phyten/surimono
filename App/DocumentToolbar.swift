import SurimonoCore
import SwiftUI

struct DocumentToolbar: ToolbarContent {
    @Bindable var model: DocumentViewModel

    var body: some ToolbarContent {
        ToolbarItemGroup { DocumentLayoutControls(model: model) }
        ToolbarItemGroup { DocumentPreviewControls(model: model) }
        ToolbarItem(placement: .primaryAction) { DocumentPrintButton(model: model) }
    }
}

struct DocumentLayoutControls: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Picker("Layout", selection: $model.layoutID) {
            ForEach(PrintLayout.presets) { layout in
                Text(verbatim: layout.displayName(language: model.language)).tag(layout.id)
            }
        }.help("Layout")
        if model.format.usesPrintTheme {
            Picker("Print Theme", selection: $model.themeID) {
                ForEach(model.library.themes) { theme in
                    Text(verbatim: theme.displayName(language: model.language)).tag(theme.id)
                }
            }.help("Print Theme")
        }
        if model.format.usesHTMLPreset {
            Picker("HTML Preset", selection: $model.presetID) {
                ForEach(model.library.presets) { preset in
                    Text(verbatim: preset.displayName(language: model.language)).tag(preset.id)
                }
            }.help("HTML Preset")
        }
    }
}

struct DocumentPreviewControls: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Picker("Preview", selection: $model.previewMode) {
            Text("Sheets").tag(PreviewMode.sheets)
            Text("Pages").tag(PreviewMode.pages)
        }.pickerStyle(.segmented).help("Preview")
        Button {
            model.cycleAppearance()
        } label: {
            Label("Cycle Appearance", systemImage: model.appearance.symbol)
        }.help("Cycle Appearance")
        Button {
            model.exportPDF()
        } label: {
            Label("Export as PDF…", systemImage: "square.and.arrow.up")
        }.disabled(!model.canOutput).help("Export as PDF…")
    }
}

struct DocumentPrintButton: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Button {
            model.printDocument()
        } label: {
            Label("Print…", systemImage: "printer")
        }.disabled(!model.canOutput).help("Print…")
    }
}

struct DocumentCommands: Commands {
    private var model: DocumentViewModel? { DocumentWindows.shared.activeModel }

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
        CommandMenu("Layout") {
            ForEach(Array(PrintLayout.presets.enumerated()), id: \.element.id) { index, layout in
                Button(
                    layout.displayName(language: model?.language ?? Bundle.main.preferredLocalizations.first ?? "en")
                ) {
                    model?.layoutID = layout.id
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                .disabled(model == nil)
            }
        }
        CommandMenu("Images") {
            Button("Move Image Up") { model?.imageBundle?.moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(model?.imageBundle?.canMoveSelection(by: -1) != true)
            Button("Move Image Down") { model?.imageBundle?.moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(model?.imageBundle?.canMoveSelection(by: 1) != true)
        }
        CommandGroup(after: .toolbar) {
            Button("Cycle Appearance") { model?.cycleAppearance() }
                .keyboardShortcut("t", modifiers: [.control, .command]).disabled(model == nil)
            Button("Reload") { model?.reload() }.disabled(model == nil)
        }
    }
}

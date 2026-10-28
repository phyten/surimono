import SurimonoCore
import SwiftUI

struct DocumentToolbar: ToolbarContent {
    @Bindable var model: DocumentViewModel

    var body: some ToolbarContent {
        ToolbarItemGroup {
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
        ToolbarItemGroup {
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
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.printDocument()
            } label: {
                Label("Print…", systemImage: "printer")
            }.disabled(!model.canOutput).help("Print…")
        }
    }
}

private struct DocumentModelKey: FocusedValueKey {
    typealias Value = DocumentViewModel
}

extension FocusedValues {
    var documentModel: DocumentViewModel? {
        get { self[DocumentModelKey.self] }
        set { self[DocumentModelKey.self] = newValue }
    }
}

struct DocumentCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
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
        CommandGroup(after: .toolbar) {
            Button("Cycle Appearance") { model?.cycleAppearance() }
                .keyboardShortcut("t", modifiers: [.control, .command]).disabled(model == nil)
            Button("Reload") { model?.reload() }.disabled(model == nil)
        }
    }
}

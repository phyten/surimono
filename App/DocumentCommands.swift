import SurimonoCore
import SwiftUI

struct DocumentCommands: Commands {
    let preferences: AppPreferences
    private var model: DocumentViewModel? { DocumentWindows.shared.activeModel }
    private var language: String { model?.language ?? Bundle.main.preferredLocalizations.first ?? "en" }
    private var layoutCards: [PrintLayout] {
        let cards = PrintLayout.presets(in: model?.trayPaperSeries ?? .a)
        return cards.contains(.a4Handout3) ? cards : cards + [.a4Handout3]
    }

    /// Named as the binder's window is.
    private func title(of binder: RecentBinder) -> String {
        BinderModel.title(firstName: binder.firstName, count: binder.files.count, language: language)
    }

    var body: some Commands {
        // The standard Open… item stays: AppDelegate answers its action so that a multi-file
        // selection reaches OpenRouter, and Open Recent opens a single file.
        CommandGroup(replacing: .newItem) {
            Button("Open from Clipboard") { ClipboardWindows.shared.open() }
                .keyboardShortcut("n")
            Button("Streaming Preview") { StreamingPreviewWindows.shared.open() }
            // A binder has no file of its own, so the standard Open Recent cannot list it.
            if !preferences.recentBinders.isEmpty {
                Menu("Recent Binders") {
                    ForEach(preferences.recentBinders.entries) { binder in
                        Button(title(of: binder)) { OpenRouter.shared.open(recentBinder: binder) }
                    }
                    Divider()
                    Button("Clear Menu") { preferences.clearRecentBinders() }
                }
            }
        }
        // Next to the document's own save items, which stay hidden: this one writes a new file for a document that has
        // none, and never touches a file that was opened.
        CommandGroup(after: .saveItem) {
            if model?.canSaveAsFile == true {
                Button("Save as File…") { model?.saveAsFile() }
            }
        }
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
        // Like the print items, these stay enabled; the model does nothing where there is no paper to search.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { model?.performFind() }
                .keyboardShortcut("f")
            Button("Find Next") { model?.findStep(forward: true) }
                .keyboardShortcut("g")
            Button("Find Previous") { model?.findStep(forward: false) }
                .keyboardShortcut("g", modifiers: [.shift, .command])
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
            // For a page that only looks like a slide deck; other documents ignore it.
            Toggle(
                "Don't Treat as Slides",
                isOn: Binding(get: { model?.ignoresSlides ?? false }, set: { model?.setIgnoresSlides($0) })
            )
            Divider()
            ForEach(Array(ViewOptions.Layout.allCases.enumerated()), id: \.element) { index, layout in
                Button(layout.title) { model?.setLayout(layout) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.option, .command])
            }
            Button("View Options…") {
                guard let model, model.mode == .view else { return }
                model.isViewOptionsPresented = true
            }
            Button("Go to Page…") { model?.presentGoToPage() }
                .keyboardShortcut("g", modifiers: [.option, .command])
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
                "Always Show Toolbar",
                isOn: Binding(
                    get: { model?.isBandAlwaysVisible ?? false }, set: { model?.isBandAlwaysVisible = $0 })
            )
            .keyboardShortcut("t", modifiers: [.option, .command])
            Toggle(
                "Float on Top",
                isOn: Binding(get: { model?.isAlwaysOnTop ?? false }, set: { model?.isAlwaysOnTop = $0 })
            )
            Divider()
            SettingSetMenu(preferences: preferences, model: { model })
        }
        CommandGroup(replacing: .help) {
            Button("Keys and Gestures") { KeyGuideWindow.shared.show() }
        }
        CommandMenu("Document") {
            Menu("Print Layout") {
                // The shortcuts stay six and ask the model, whose cards can change before the menu next opens.
                ForEach(Array(layoutCards.enumerated()), id: \.element.id) { index, layout in
                    Button(layout.displayName(language: language)) { model?.chooseCard(at: index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
            }
            Button("Choose Style…") { model?.openThemePalette() }
            if model?.includePlan != nil {
                Button("Open as Binder") { model?.openIncludesAsBinder() }
            }
            Button("Add Documents…") { model?.chooseDocumentsToAdd() }
            if model?.binder != nil || model?.imageBundle != nil {
                Menu(LocalizedStringKey(model?.binder == nil ? "Images" : "Binder")) {
                    Toggle(
                        "Show List",
                        isOn: Binding(get: { model?.isDrawerOpen ?? false }, set: { model?.isDrawerOpen = $0 })
                    )
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    if model?.binder != nil {
                        Button("Remove from List") {
                            if let url = model?.binder?.selection { model?.removeFromBinder(url) }
                        }
                        Toggle(
                            "Start Each Document on an Odd Page",
                            isOn: Binding(
                                get: { model?.binderStartsOnFront ?? false }, set: { model?.binderStartsOnFront = $0 }))
                    }
                    Button(LocalizedStringKey(model?.binder == nil ? "Move Image Up" : "Move Document Up")) {
                        model?.imageBundle?.moveSelection(by: -1)
                        model?.binder?.moveSelection(by: -1)
                    }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                    Button(LocalizedStringKey(model?.binder == nil ? "Move Image Down" : "Move Document Down")) {
                        model?.imageBundle?.moveSelection(by: 1)
                        model?.binder?.moveSelection(by: 1)
                    }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                    Button("Sort by Name") {
                        model?.imageBundle?.sortByName()
                        model?.binder?.sortByName()
                    }
                }
            }
            Divider()
            Button("Reset Document Settings") { model?.resetDocumentSettings() }
            Button("Reload") { model?.reload() }
                .keyboardShortcut("r")
        }
    }
}

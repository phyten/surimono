import SurimonoCore
import SwiftUI

struct DocumentCommands: Commands {
    let preferences: AppPreferences
    let library: UserLibrary
    private var model: DocumentViewModel? { DocumentWindows.shared.activeModel }
    private func perform(_ operation: ShortcutOperationID) { ShortcutDispatcher.shared.perform(operation) }
    private var language: String { model?.language ?? Bundle.main.preferredLocalizations.first ?? "en" }
    private var layoutCards: [PrintLayout] {
        let cards = PrintLayout.presets(in: model?.trayPaperSeries ?? .a)
        return model?.trayPaperSeries == .b ? Array(cards.prefix(5)) + [.a4Handout3] : cards
    }

    /// Named as the binder's window is.
    private func title(of binder: RecentBinder) -> String {
        BinderModel.title(firstName: binder.firstName, count: binder.files.count, language: language)
    }

    // Keep the original keys on newly assembled or unidentifiable items. The bridge applies accepted overrides
    // synchronously on menu changes and before dispatch, including clearing a deliberately unassigned key.
    var body: some Commands {
        // The standard Open… item stays: AppDelegate answers its action so that a multi-file
        // selection reaches OpenRouter, and Open Recent opens a single file.
        CommandGroup(replacing: .newItem) {
            Button("Open from Clipboard") { perform(.clipboardOpen) }
                .keyboardShortcut("n")
            Button("Streaming Preview") { perform(.appStreamingPreview) }
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
            Button("Save as File…") { perform(.documentSaveAsFile) }
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
            Button("Find…") { perform(.documentFind) }
                .keyboardShortcut("f")
            Button("Find Next") { perform(.documentFindNext) }
                .keyboardShortcut("g")
            Button("Find Previous") { perform(.documentFindPrevious) }
                .keyboardShortcut("g", modifiers: [.shift, .command])
        }
        CommandGroup(after: .toolbar) {
            // Names where the item goes, as the print item does; HTML only, and nothing happens for other documents.
            Button(
                model?.htmlPresentation == .paper
                    ? LocalizedStringKey("Show as Web") : LocalizedStringKey("Show as Paper")
            ) {
                perform(.viewHtmlPresentation)
            }
            .keyboardShortcut("p", modifiers: [.control, .command])
            // For a page that only looks like a slide deck; other documents ignore it.
            Toggle(
                "Don't Treat as Slides",
                isOn: Binding(get: { model?.ignoresSlides ?? false }, set: { _ in perform(.viewIgnoreSlides) })
            )
            Divider()
            ForEach(ViewOptions.Layout.displayOrder, id: \.self) { layout in
                Button(layout.title) { perform(layout == .single ? .viewSingle : .viewSpread) }
                    .keyboardShortcut(layout == .single ? "1" : "2", modifiers: [.option, .command])
            }
            Button("View Options…") {
                guard let model, model.mode == .view else { return }
                model.isViewOptionsPresented = true
            }
            Button("Go to Page…") { perform(.documentGoToPage) }
                .keyboardShortcut("g", modifiers: [.option, .command])
            Divider()
            Button("Increase Text Size") { model?.increaseTextSize() }
                .keyboardShortcut("+", modifiers: [.option, .command])
            Button("Decrease Text Size") { perform(.textDecrease) }
                .keyboardShortcut("-", modifiers: [.option, .command])
            Button("Original Text Size") { perform(.textReset) }
                .keyboardShortcut("0", modifiers: [.option, .command])
            Divider()
            Button("Zoom In") { model?.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { perform(.viewZoomOut) }
                .keyboardShortcut("-")
            Button("Fit to Window") { perform(.viewZoomFit) }
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
                    get: { model?.isBandAlwaysVisible ?? false }, set: { _ in perform(.viewToolbarAlways) })
            )
            .keyboardShortcut("t", modifiers: [.option, .command])
            Toggle(
                "Float on Top",
                isOn: Binding(get: { model?.isAlwaysOnTop ?? false }, set: { _ in perform(.viewFloatOnTop) })
            )
        }
        CommandGroup(replacing: .help) {
            Button("Getting Started with Surimono") { perform(.appGettingStarted) }
            Button("Keys and Gestures") { perform(.appKeyGuide) }
        }
        CommandMenu("Document") {
            Menu("Print Layout") {
                // The shortcuts stay six and ask the model, whose cards can change before the menu next opens.
                ForEach(Array(layoutCards.enumerated()), id: \.element.id) { index, layout in
                    Button(layout.displayName(language: language)) { model?.chooseCard(at: index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Divider()
                ForEach(PrintLayout.compactPresets(in: model?.trayPaperSeries ?? .a)) { layout in
                    Button(layout.displayName(language: language)) { model?.chooseLayout(layout.id) }
                }
            }
            SettingSetMenu(preferences: preferences, library: library, model: { model })
            // The same panel in both modes: off the window's edge in the view mode, beside the sheets on the tray.
            Button("Print Settings…") { model?.presentPrintSettings() }
            Button("Choose Style…") { perform(.styleChoose) }
            Button("Open as Binder") { perform(.documentOpenBinder) }
            Button("Add Documents…") { perform(.documentAdd) }
            Menu(LocalizedStringKey(model?.binder == nil ? "Images" : "Binder")) {
                Toggle(
                    "Show List",
                    isOn: Binding(get: { model?.isDrawerOpen ?? false }, set: { _ in perform(.listToggle) })
                )
                .keyboardShortcut("s", modifiers: [.control, .command])
                Button("Remove from List") {
                    if let url = model?.binder?.selection { model?.removeFromBinder(url) }
                }
                Toggle(
                    "Start Each Document on an Odd Page",
                    isOn: Binding(
                        get: { model?.binderStartsOnFront ?? false }, set: { _ in perform(.binderOddPageStarts) }))
                Button(LocalizedStringKey(model?.binder == nil ? "Move Image Up" : "Move Document Up")) {
                    perform(.listMoveUp)
                }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                Button(LocalizedStringKey(model?.binder == nil ? "Move Image Down" : "Move Document Down")) {
                    perform(.listMoveDown)
                }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                Button("Sort by Name") {
                    perform(.listSortByName)
                }
            }
            Divider()
            Button("Reset Document Settings") { perform(.documentResetSettings) }
            Button("Reload") { perform(.documentReload) }
                .keyboardShortcut("r")
        }
    }
}

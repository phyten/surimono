import SurimonoCore
import SurimonoRendering
import SwiftUI

struct SettingsView: View {
    var windowMinimum = SettingsWindowPlacement.minimumContentSize
    @Bindable var preferences: AppPreferences
    @Bindable var library: UserLibrary
    let arrangementEditor: BandArrangementEditorSession
    @State private var initialTextWell = InitialTextWell()
    @State private var query = ""
    @State private var pickedSearchFormat: DocumentFormat?
    @State private var bandHints = BandHintSession()
    @State private var editorFrame = CGRect.zero
    @State private var hintLayerFrame = CGRect.zero
    @State private var searchSelection = SettingsSearchSelection()
    @State private var pendingSearchPick: SettingsSection?
    private let updater = AppUpdater.shared
    private var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    private var furnitureChoice: Binding<PageFurniture.Preset> {
        Binding(
            get: { preferences.defaultFurniture.preset },
            set: { preset in
                guard preset != .custom else { return }
                preferences.defaultFurniture.apply(preset)
            })
    }

    private func changeColor(
        _ label: LocalizedStringKey, hex: String?, resetLabel: LocalizedStringKey, isDefault: Bool,
        set: @escaping (String?) -> Void
    ) -> some View {
        LabeledContent {
            HStack {
                if let hex {
                    ColorPicker(
                        label,
                        selection: Binding(
                            get: { Color(codeHex: hex) },
                            set: { if let hex = Self.hex(NSColor($0)) { set(hex) } }),
                        supportsOpacity: false
                    ).labelsHidden()
                    Button(resetLabel) {
                        initialTextWell.deactivate()
                        set(nil)
                    }.disabled(isDefault)
                } else {
                    Button("Choose…") { initialTextWell.choose { if let hex = Self.hex($0) { set(hex) } } }
                        .accessibilityLabel(Text(label))
                }
            }
            .controlSize(.small).fixedSize()
            // The well uses the row's vertical padding so the label has the same height as its neighbours.
            .frame(height: 16)
        } label: {
            Text(label)
        }
    }

    private static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return "#"
            + [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
                String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded()))
            }.joined()
    }

    /// Opening or closing the system panel leaves document ink selected until the reader picks a colour.
    private final class InitialTextWell: NSColorWell {
        private var selection: ((NSColor) -> Void)?

        func choose(_ selection: @escaping (NSColor) -> Void) {
            self.selection = nil
            supportsAlpha = false
            target = self
            action = #selector(selected)
            activate(true)
            NSColorPanel.shared.makeKeyAndOrderFront(nil)
            self.selection = selection
        }

        override func deactivate() {
            super.deactivate()
            selection = nil
        }

        @objc private func selected() { selection?(color) }
    }

    var body: some View {
        let results = searchResults
        let matches = results.rows
        let visible = query.isEmpty ? Set(SettingsSection.allCases) : Set(matches.map(\.section))
        NavigationSplitView {
            SettingsSidebar(
                query: searchText, visible: visible,
                selection: Binding(
                    get: { visible.contains(preferences.settingsSection) ? preferences.settingsSection : nil },
                    set: { if let section = $0 { selectSection(section) } }
                )
            )
            #if DEBUG
                .modifier(SnapshotSettingsSurface(sidebar: true))
            #endif
            // Without the sidebar toggle the split view lets a narrow window squeeze the column below its minimum.
            .frame(minWidth: 230)
            .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
            // Settings always shows its sections. Without the toggle the window has no toolbar row, so every
            // section starts right under the title bar with the system's own inset.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let section = preferences.settingsSection
            let format =
                pickedSearchFormat.flatMap { results.formats.contains($0) ? $0 : nil }
                ?? results.bestFormat(keeping: preferences.settingsDocumentFormat) ?? preferences.settingsDocumentFormat
            let hits = results.hits(for: section, format: format, query: query)
            let shown = visible.isEmpty ? nil : section
            SettingsDetail(section: shown, hits: hits) { selected in
                switch selected {
                case .toolbarArrangement:
                    BandArrangementSettings(session: arrangementEditor, hints: bandHints)
                case .keyboardShortcuts:
                    ShortcutSettingsView(controller: .shared)
                case .documents:
                    DocumentsChapterView(
                        formats: query.isEmpty ? DocumentsChapter.formats : results.formats,
                        selection: Binding(
                            get: { format },
                            set: { value in
                                preferences.settingsDocumentFormat = value
                                if !query.isEmpty {
                                    pickedSearchFormat = value
                                    searchSelection.pick(.documents)
                                }
                            })
                    ) {
                        documentSettingsPage(format)
                    }
                default:
                    ScrollViewReader { proxy in
                        form(selected).modifier(SettingsSearchReveal(proxy: proxy))
                    }
                }
            }
            // The split column allocates the viewport independently of the visited editor's ideal size.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background {
                if shown == .toolbarArrangement { BandHintWindowFrame(frame: $editorFrame) }
            }
            .onChange(of: shown, initial: true) {
                switch shown {
                case .toolbarArrangement: arrangementEditor.didAppear()
                case .keyboardShortcuts: ShortcutController.shared.refresh()
                default: break
                }
            }
            #if DEBUG
                .modifier(SnapshotSettingsSurface(sidebar: false))
            #endif
            .overlay(alignment: .topLeading) {
                if visible.isEmpty {
                    Text("No settings found").foregroundStyle(PrintPalette.ink2).padding(20)
                }
            }
            .overlay(alignment: .bottom) {
                if !visible.isEmpty { SettingSetRemovalNotice(preferences: preferences) }
            }
            .navigationTitle(
                visible.isEmpty ? Text(verbatim: "") : Text(LocalizedStringKey(preferences.settingsSection.rawValue))
            )
            // The split view uses navigationTitle internally. SettingsWindowTitle owns the AppKit window title.
            .background(
                SettingsWindowTitle(
                    title: visible.isEmpty
                        ? ""
                        : Bundle.main.localizedString(
                            forKey: preferences.settingsSection.rawValue, value: nil, table: nil)))
        }
        .modifier(SettingsViewport(windowMinimum: windowMinimum))
        .frame(
            minWidth: windowMinimum.width, idealWidth: SettingsWindowPlacement.defaultContentSize.width,
            minHeight: windowMinimum.height
        )
        .overlay {
            if !visible.isEmpty, preferences.settingsSection == .toolbarArrangement {
                BandHintLayer(
                    session: bandHints,
                    editorFrame: editorFrame.offsetBy(dx: -hintLayerFrame.minX, dy: -hintLayerFrame.minY)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { BandHintWindowFrame(frame: $hintLayerFrame) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onContinuousHover { phase in
            guard preferences.settingsSection == .toolbarArrangement else { return }
            let point: CGPoint?
            switch phase {
            case .active(let p):
                point = CGPoint(
                    x: p.x + hintLayerFrame.minX - editorFrame.minX,
                    y: p.y + hintLayerFrame.minY - editorFrame.minY)
            case .ended: point = nil
            }
            bandHints.moveInEditor(to: point, dragging: NSEvent.pressedMouseButtons != 0)
        }
        .onChange(of: query) {
            guard !query.isEmpty, let best = results.bestSection(keeping: preferences.settingsSection) else { return }
            arrangementEditor.showSection(best)
        }
        .onChange(of: visible) {
            // A conditional row can disappear while the reader keeps the same query.
            if !visible.contains(preferences.settingsSection), arrangementEditor.pendingLeave == nil,
                let best = results.bestSection(keeping: preferences.settingsSection)
            {
                arrangementEditor.showSection(best)
            }
        }
        .onChange(of: preferences.settingsNavigationRevision) { query = "" }
        .onChange(of: arrangementEditor.pendingLeave) { previous, pending in
            if pending == nil, let pick = pendingSearchPick {
                if preferences.settingsSection == pick { searchSelection.pick(pick) }
                pendingSearchPick = nil
            }
            if pending != nil && visible.isEmpty { query = "" }
            // Cancelling navigation leaves the editor selected, so restore its sidebar entry.
            if case .section = previous, pending == nil, !visible.contains(preferences.settingsSection) { query = "" }
        }
        .onChange(of: preferences.settingsSection) {
            bandHints.dismiss()
            if !visible.contains(preferences.settingsSection) { query = "" }
        }
        .onDisappear {
            initialTextWell.deactivate()
            query = ""
        }
        .background {
            WindowReader { window in
                let editor = arrangementEditor
                let preferences = preferences
                editor.undoRouter = SettingsUndoRouter.install(
                    on: window, history: { preferences.settingsSection == .toolbarArrangement ? editor.history : nil },
                    undo: { editor.undo() }, redo: { editor.redo() })
            }
        }
        #if DEBUG
            .snapshotControlAppearance()
        #endif
    }

    private func selectSection(_ section: SettingsSection) {
        arrangementEditor.showSection(section)
        guard !query.isEmpty else { return }
        if preferences.settingsSection == section {
            searchSelection.pick(section)
        } else if arrangementEditor.pendingLeave == .section(section) {
            // Remember this choice only after the reader has agreed to leave the toolbar editor.
            pendingSearchPick = section
        }
    }

    private var searchText: Binding<String> {
        Binding(
            get: { query },
            set: { value in
                if query.isEmpty && !value.isEmpty { searchSelection.begin(in: preferences.settingsSection) }
                pickedSearchFormat = nil
                query = value
                if value.isEmpty, let section = searchSelection.finish() { arrangementEditor.showSection(section) }
            })
    }

    private var searchResults: SettingsSearchResults {
        guard !query.isEmpty else { return SettingsSearchResults() }
        let sets = PrintSettingSet.builtIns(language: language) + preferences.printSettingSets
        let savedRows = sets.map { set in
            SettingsSearchRow(
                .settingSets, set.name, anchor: set.id.uuidString,
                words: set.isBuiltIn ? ["Built-in Sets"] : ["Your Sets", "Export…", "Rename…", "Delete"])
        }
        let rows =
            savedRows
            + SettingsCatalogue.rows.filter { row in
                switch row.label {
                case "Check for Updates Automatically", "When an Update Is Found": updater.isAvailable
                case "Updates are unavailable in development builds.":
                    #if APP_STORE
                        false
                    #else
                        !updater.isAvailable
                    #endif
                case "Move To": arrangementEditor.selectedEntry != nil
                case "Start Over": arrangementEditor.needsRecovery
                case "Use Saved": arrangementEditor.hasConflict
                case "Format to Open": preferences.clipboardFormat.mode == .fixed
                case "How Readily to Format": preferences.clipboardFormat.mode != .fixed
                default: true
                }
            }
        return SettingsCatalogue.search(query, in: rows)
    }

    @ViewBuilder func documentSettingsPage(_ format: DocumentFormat) -> some View {
        switch format {
        case .org: OrgReadingDefaultsPane(preferences: preferences)
        case .html:
            ScrollViewReader { proxy in form(.html).modifier(SettingsSearchReveal(proxy: proxy)) }
        case .plainText: CodeNumberDefaultsPane(preferences: preferences)
        default: FormatDefaultsPane(format: format, preferences: preferences)
        }
    }

    private func form(_ section: SettingsSection) -> some View {
        Form {
            switch section {
            case .general:
                Section {
                    LanguagePicker(preferences: preferences)
                        .settingSearchRow("Language")
                    Picker("Appearance", selection: $preferences.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .settingSearchRow("Appearance")
                    Toggle("Show in Menu Bar", isOn: $preferences.showsMenuBarItem)
                        .settingSearchRow("Show in Menu Bar")
                }
                Section {
                    Picker("When a Binder Is Down to One Document", selection: $preferences.singleDocumentBinderPolicy)
                    {
                        Text("Ask").tag(SingleDocumentBinderPolicy.ask)
                        Text("Leave Binder Mode Without Asking").tag(SingleDocumentBinderPolicy.leave)
                        Text("Stay a Binder Without Asking").tag(SingleDocumentBinderPolicy.stay)
                    }
                    .settingSearchRow("When a Binder Is Down to One Document")
                    Toggle("Reload When the File Changes", isOn: $preferences.reloadsChangedFiles)
                        .settingSearchRow("Reload When the File Changes")
                    Picker("After a File Is Saved", selection: $preferences.changeFollowing) {
                        Text("Jump to the Change").tag(ChangeFollowing.jump)
                        Text("Stay Here, Marks Only").tag(ChangeFollowing.mark)
                        Text("Ask Whether to Jump").tag(ChangeFollowing.ask)
                    }
                    .settingSearchRow("After a File Is Saved")
                    changeColor(
                        "Changed Places", hex: preferences.changeBackgroundHex,
                        resetLabel: "Restore Default",
                        isDefault: preferences.changeBackgroundHex == ChangeMark.defaultBackgroundHex,
                        set: { preferences.changeBackgroundHex = $0 ?? ChangeMark.defaultBackgroundHex }
                    )
                    .settingSearchRow("Changed Places")
                    changeColor(
                        "Changed Text", hex: preferences.changeTextHex,
                        resetLabel: "Same as the Document", isDefault: preferences.changeTextHex == nil,
                        set: { preferences.changeTextHex = $0 }
                    )
                    .settingSearchRow("Changed Text")
                } header: {
                    Text("After a Document Opens")
                } footer: {
                    SettingsFootnote("Changes are highlighted on screen only.")
                }
                Section("Window") {
                    Picker("Corners", selection: $preferences.corners) {
                        Text("Square").tag(CornerPreset.square)
                        Text("Standard").tag(CornerPreset.standard)
                        Text("Round").tag(CornerPreset.round)
                    }
                    .settingSearchRow("Corners")
                    Toggle("Float on Top", isOn: $preferences.defaultAlwaysOnTop)
                        .settingSearchRow("Float on Top")
                    Toggle("Show on All Spaces", isOn: $preferences.defaultShowsOnAllSpaces)
                        .settingSearchRow("Show on All Spaces")
                }
                if updater.isAvailable {
                    Section {
                        Toggle(
                            "Check for Updates Automatically",
                            isOn: Binding(
                                get: { updater.checksAutomatically }, set: { updater.setChecksAutomatically($0) })
                        )
                        .settingSearchRow("Check for Updates Automatically")
                        UpdateHandlingPicker(
                            installsAutomatically: Binding(
                                get: { updater.installsAutomatically },
                                set: { updater.setInstallsAutomatically($0) })
                        )
                        .settingSearchRow("When an Update Is Found")
                    } header: {
                        Text("Updates")
                    } footer: {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsFootnote("Nothing about your documents is sent to GitHub.")
                            SettingsFootnote(UpdateHandlingPicker.note)
                        }
                    }
                } else {
                    #if !APP_STORE
                        // Where the release build has its update settings, so both builds show updates in one place.
                        // The App Store build updates through the App Store and says nothing here.
                        Section("Updates") {
                            Text("Updates are unavailable in development builds.").foregroundStyle(PrintPalette.ink2)
                                .settingSearchRow("Updates are unavailable in development builds.")
                        }
                    #endif
                }
            case .view:
                Section {
                    Picker("Scroll Sensitivity", selection: $preferences.wheelSensitivity) {
                        Text("Low").tag(WheelPageTurner.Sensitivity.low)
                        Text("Normal").tag(WheelPageTurner.Sensitivity.normal)
                        Text("High").tag(WheelPageTurner.Sensitivity.high)
                    }.pickerStyle(.segmented)
                        .settingSearchRow("Scroll Sensitivity")
                }
                // The heading says these are defaults, so the labels need not; "Automatic" is explained once below.
                Section {
                    Picker("View Type", selection: $preferences.defaultViewLayout) {
                        Text("Automatic").tag(nil as ViewOptions.Layout?)
                        ForEach(ViewOptions.Layout.displayOrder, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .settingSearchRow("View Type")
                    Picker("Page Turning", selection: $preferences.defaultPageTurn) {
                        Text("Automatic").tag(nil as ViewOptions.Transition?)
                        ForEach(ViewOptions.Transition.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .settingSearchRow("Page Turning")
                    Picker("Reading Direction", selection: $preferences.defaultReadingDirection) {
                        Text("Automatic").tag(nil as ViewOptions.Direction?)
                        Text("Left to Right").tag(Optional(ViewOptions.Direction.leftToRight))
                        Text("Right to Left").tag(Optional(ViewOptions.Direction.rightToLeft))
                    }
                    .settingSearchRow("Reading Direction")
                    Picker("Scroll Direction", selection: $preferences.defaultScrollAxis) {
                        Text("Automatic").tag(nil as ViewOptions.ScrollAxis?)
                        Text("Vertical").tag(Optional(ViewOptions.ScrollAxis.vertical))
                        Text("Horizontal").tag(Optional(ViewOptions.ScrollAxis.horizontal))
                    }
                    .settingSearchRow("Scroll Direction")
                    Picker("Show First Page Alone", selection: $preferences.defaultShowsCoverAlone) {
                        Text("Automatic").tag(nil as Bool?)
                        Text("On").tag(Optional(true))
                        Text("Off").tag(Optional(false))
                    }
                    .settingSearchRow("Show First Page Alone")
                    // Beside the choice it depends on. Unlike the defaults around it, it applies to open windows too,
                    // which the footer says.
                    Picker("Window Width When the First Page Is Alone", selection: $preferences.loneCoverWidth) {
                        Text("One Page").tag(LoneCoverWidth.onePage)
                        Text("Two Pages").tag(LoneCoverWidth.twoPages)
                    }
                    .settingSearchRow("Window Width When the First Page Is Alone")
                    Toggle("Join Pages in Single-Page Scrolling", isOn: $preferences.defaultJoinsPages)
                        .settingSearchRow("Join Pages in Single-Page Scrolling")
                } header: {
                    Text("Defaults for New Documents")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsFootnote("Automatic follows the document.")
                        SettingsFootnote("The window width also applies to windows already open.")
                    }
                }
                Section {
                    Picker("Toolbar Layout", selection: $preferences.menuArrangement) {
                        Text("Top Only").tag(MenuArrangement.top)
                        Text("Split Top and Bottom").tag(MenuArrangement.split)
                    }
                    .settingSearchRow("Toolbar Layout")
                    BandVisibilityPicker(selection: $preferences.defaultBandVisibility)
                        .settingSearchRow("Toolbar Visibility")
                    // Which parts the toolbar shows, Contents among them, is the arrangement's business.
                    LabeledContent("Parts of the Toolbar") {
                        Button("Arrange…") { selectSection(.toolbarArrangement) }
                    }
                    .settingSearchRow("Parts of the Toolbar")
                } header: {
                    Text("Toolbar")
                } footer: {
                    SettingsFootnote("While it shows, the toolbar takes its own room outside the paper.")
                }
                Section("Contents") {
                    Picker("Show Contents As", selection: $preferences.outlinePresentation) {
                        Text("Popover").tag(OutlinePresentation.popover)
                        Text("Left Drawer").tag(OutlinePresentation.drawer)
                    }
                    .settingSearchRow("Show Contents As")
                }
            case .pageNumbers:
                Section {
                    Toggle("In View Mode", isOn: $preferences.viewPageNumbers)
                        .settingSearchRow("In View Mode")
                } footer: {
                    SettingsFootnote("Page numbers are never shown in single-page scrolling.")
                }
                // As in View and Page Turn and Printing, the heading says these are defaults.
                Section("Defaults for New Documents") {
                    Picker("In Print", selection: furnitureChoice) {
                        ForEach(PrintFurnitureChoice.choices.filter { $0.value != .custom }, id: \.value) { choice in
                            Text(choice.title).tag(choice.value)
                        }
                        // Written on the print screen; it stays until another choice replaces it.
                        if preferences.defaultFurniture.preset == .custom {
                            Text("Specify Contents…").tag(PageFurniture.Preset.custom)
                        }
                    }
                    .settingSearchRow("In Print")
                }
            case .printing:
                Section("Defaults for New Documents") {
                    Picker("Print Layout", selection: $preferences.layoutID) {
                        ForEach(PrintLayout.presets) { layout in
                            Text(verbatim: layout.displayName(language: language)).tag(layout.id)
                        }
                    }
                    .settingSearchRow("Print Layout")
                    Picker("Paper Orientation", selection: $preferences.defaultPaperOrientation) {
                        Text("Automatic").tag(PaperOrientation.auto)
                        Text("Portrait").tag(PaperOrientation.portrait)
                        Text("Landscape").tag(PaperOrientation.landscape)
                    }
                    .settingSearchRow("Paper Orientation")
                    // The same field, stepper and unit as the margins of the view options and the print screen.
                    LabeledContent("Text Margins") {
                        MarginField(title: "Text Margins", millimeters: preferences.margin, unit: .current) {
                            preferences.margin = $0
                        }
                    }
                    .settingSearchRow("Text Margins")
                }
                // Both belong to the printer: they are where a printer starts until it remembers its own.
                Section {
                    Toggle("Rotate Back Sides 180°", isOn: $preferences.rotateBack)
                        .settingSearchRow("Rotate Back Sides 180°")
                    PrintPageOrderPicker(order: $preferences.printPageOrder)
                        .pickerStyle(.segmented)
                        .settingSearchRow("Output Order")
                } header: {
                    Text("Printers Without Remembered Settings")
                } footer: {
                    SettingsFootnote(PrintPageOrderPicker.hint)
                }
            case .settingSets:
                SettingSetsSettings(preferences: preferences, library: library)
            case .styles:
                Section {
                    Toggle("Try a Style on the Paper When Pointing at It", isOn: $preferences.triesThemeOnHover)
                        .settingSearchRow("Try a Style on the Paper When Pointing at It")
                    Picker("Default Style", selection: $preferences.themeID) {
                        DefaultStyleChoices(library: library)
                    }
                    .settingSearchRow("Default Style")
                    Picker("Default Code Colors", selection: $preferences.defaultCodePaletteID) {
                        Text("Match Style").tag(CodePalette.matchesStyleID)
                        ForEach(library.codePalettes) { palette in
                            Text(verbatim: palette.displayName(language: language)).tag(palette.id)
                        }
                    }
                    .settingSearchRow("Default Code Colors")
                    LabeledContent("Default Text Size") {
                        TextSizeField(title: "Default Text Size", scale: preferences.defaultTextScale) {
                            preferences.defaultTextScale = $0
                        }
                    }
                    .settingSearchRow("Default Text Size")
                    Picker("Default Typeface", selection: $preferences.defaultTypeface) {
                        TypefaceChoices()
                    }
                    .settingSearchRow("Default Typeface")
                } footer: {
                    VStack(alignment: .leading) {
                        defaultsNote
                        SettingsFootnote(
                            "Each LaTeX document uses its class style until you choose a style for it.")
                    }
                }
                Section {
                    HStack {
                        Button("Open Styles Folder") { library.openFolder("Styles") }
                        Button("Reload") { library.reload() }
                    }
                    .settingSearchRow("Open Styles Folder")
                    libraryError
                }
            case .html:
                Section {
                    Picker("Default HTML Preset", selection: $preferences.presetID) {
                        ForEach(library.presets) { preset in
                            Text(verbatim: preset.displayName(language: language)).tag(preset.id)
                        }
                    }
                    .settingSearchRow("Default HTML Preset")
                    Toggle("Allow JavaScript in HTML", isOn: $preferences.allowsJavaScript)
                        .settingSearchRow("Allow JavaScript in HTML")
                } header: {
                    DocumentDefaultsHeader(
                        format: .html, status: preferences.usesDefaultHTMLSettings ? "Surimono defaults" : "Custom")
                } footer: {
                    defaultsNote
                }
                Section {
                    HStack {
                        Button("Open Presets Folder") { library.openFolder("Presets") }
                        Button("Reload") { library.reload() }
                    }
                    .settingSearchRow("Open Presets Folder")
                    libraryError
                    if !library.presetErrors.isEmpty {
                        Text("Some presets could not be loaded:").font(.headline)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(library.presetErrors, id: \.url) { error in
                                    Text(verbatim: error.url.lastPathComponent).bold()
                                    Text(LocalizedStringKey(error.message)).textSelection(.enabled)
                                }
                            }
                        }.frame(maxHeight: 130)
                    }
                }
            case .clipboard:
                ClipboardSettings(preferences: preferences)
            case .documents, .org, .keyboardShortcuts, .toolbarArrangement: EmptyView()
            }
        }
        .formStyle(.grouped)
    }

    private var defaultsNote: some View { SettingsFootnote("Defaults apply to newly opened documents.") }

    @ViewBuilder private var libraryError: some View {
        if let error = library.error {
            Text(verbatim: error).foregroundStyle(PrintPalette.warn).textSelection(.enabled)
        }
    }
}

/// Keep both split-view columns and their controls reachable when the display is smaller than their usual minimum.
private struct SettingsViewport: ViewModifier {
    let windowMinimum: CGSize

    func body(content: Content) -> some View {
        let usual = SettingsWindowPlacement.minimumContentSize
        if windowMinimum == usual {
            content
        } else {
            GeometryReader { viewport in
                // A non-overlay scroller can consume room on the other axis as well.
                ScrollView([.horizontal, .vertical]) {
                    content.frame(
                        width: max(viewport.size.width, usual.width), height: max(viewport.size.height, usual.height))
                }
            }
        }
    }
}

struct UpdateHandlingPicker: View {
    @Binding var installsAutomatically: Bool

    /// What installing automatically means, for the footer of the section the picker is in.
    static let note: LocalizedStringKey =
        "Automatic updates are installed when you quit and are ready the next time you open Surimono."

    var body: some View {
        Picker("When an Update Is Found", selection: $installsAutomatically) {
            Text("Notify Me").tag(false)
            Text("Install Automatically").tag(true)
        }
    }
}

/// A settings section's footer: outside the group, small and secondary.
struct SettingsFootnote: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim string: String) { text = Text(verbatim: string) }

    var body: some View {
        text.font(.caption).foregroundStyle(PrintPalette.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsSidebar: View {
    @Binding var query: String
    let visible: Set<SettingsSection>
    @Binding var selection: SettingsSection?

    var body: some View {
        VStack(spacing: 0) {
            SettingsSearchField(title: "Search Settings", text: $query)
                .padding(10)
            List(selection: $selection) {
                ForEach(SettingsGroup.allCases, id: \.self) { group in
                    let sections = group.sections.filter(visible.contains)
                    if !sections.isEmpty {
                        Section {
                            ForEach(sections) { section in
                                Label(LocalizedStringKey(section.rawValue), systemImage: section.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    // List does not change its binding when the already-selected row is clicked.
                                    .simultaneousGesture(
                                        TapGesture().onEnded { selection = section }, isEnabled: !query.isEmpty
                                    )
                                    .tag(section)
                            }
                        } header: {
                            Text(LocalizedStringKey(group.rawValue))
                        }
                    }
                }
            }
            // Replacing the filtered list keeps AppKit from changing selection during an outline update.
            .id(visible)
        }
    }
}

/// Gives the Settings window the selected pane's name as its title.
private struct SettingsWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleView { TitleView(title: title) }
    func updateNSView(_ view: TitleView, context: Context) {
        view.title = title
        view.apply()
    }

    final class TitleView: NSView {
        var title: String
        init(title: String) {
            self.title = title
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// SwiftUI observes the window while it updates its views; changing the title inside that update can
        /// crash it, so the change waits until the update is done.
        func apply() {
            Task { @MainActor [weak self] in
                guard let self, let window, window.title != title else { return }
                window.title = title
            }
        }
    }
}

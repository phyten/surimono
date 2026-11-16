import SurimonoCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case view = "View & Page Turn"
    case toolbarArrangement = "Toolbar Arrangement"
    case pageNumbers = "Page Numbers"
    case printing = "Printing"
    case settingSets = "Setting Sets"
    case styles = "Styles"
    case html = "HTML"
    case clipboard = "Clipboard"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .keyboardShortcuts: "keyboard"
        case .view: "book"
        case .toolbarArrangement: "menubar.rectangle"
        case .pageNumbers: "number"
        case .printing: "printer"
        case .settingSets: "slider.horizontal.3"
        // "textformat" is drawn as kana in Japanese, beside line icons; the band's palette is the same in every language.
        case .styles: "paintpalette"
        case .html: "globe"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var library: UserLibrary
    let arrangementEditor: BandArrangementEditorSession
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

    var body: some View {
        NavigationSplitView {
            List(
                selection: Binding<SettingsSection?>(
                    get: { preferences.settingsSection },
                    set: { section in
                        guard let section else { return }
                        // An unsaved arrangement is saved or discarded before the editor goes out of view.
                        arrangementEditor.showSection(section)
                    }
                )
            ) {
                ForEach(SettingsSection.allCases) { section in
                    Label(LocalizedStringKey(section.rawValue), systemImage: section.symbol).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            Group {
                if preferences.settingsSection == .toolbarArrangement {
                    BandArrangementSettings(session: arrangementEditor)
                } else if preferences.settingsSection == .keyboardShortcuts {
                    ShortcutSettingsView(controller: .shared)
                } else {
                    form
                }
            }
            .overlay(alignment: .bottom) { SettingSetRemovalNotice(preferences: preferences) }
            .navigationTitle(Text(LocalizedStringKey(preferences.settingsSection.rawValue)))
        }
        .frame(minWidth: 820, idealWidth: 860, minHeight: 540)
        .background {
            WindowReader { window in
                let editor = arrangementEditor
                let preferences = preferences
                editor.windowGuard = SettingsWindowGuard.install(
                    on: window,
                    shouldClose: {
                        guard editor.isDirty else { return true }
                        editor.pendingLeave = .closeWindow
                        return false
                    }, needsProtection: { editor.isDirty })
                editor.undoRouter = SettingsUndoRouter.install(
                    on: window, history: { preferences.settingsSection == .toolbarArrangement ? editor.history : nil },
                    undo: { editor.undo() }, redo: { editor.redo() })
            }
        }
    }

    private var form: some View {
        Form {
            switch preferences.settingsSection {
            case .general:
                Section {
                    LanguagePicker(preferences: preferences)
                    Picker("Appearance", selection: $preferences.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                }
                if updater.isAvailable {
                    Section {
                        Toggle(
                            "Check for Updates Automatically",
                            isOn: Binding(
                                get: { updater.checksAutomatically }, set: { updater.setChecksAutomatically($0) }))
                        UpdateHandlingPicker(
                            installsAutomatically: Binding(
                                get: { updater.installsAutomatically },
                                set: { updater.setInstallsAutomatically($0) }))
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
                            Text("Updates are unavailable in development builds.").foregroundStyle(.secondary)
                        }
                    #endif
                }
                Section("When Opening a Window") {
                    Toggle("Float on Top", isOn: $preferences.defaultAlwaysOnTop)
                }
                Section {
                    Picker("When a Binder Is Down to One Document", selection: $preferences.singleDocumentBinderPolicy)
                    {
                        Text("Ask").tag(SingleDocumentBinderPolicy.ask)
                        Text("Leave Binder Mode Without Asking").tag(SingleDocumentBinderPolicy.leave)
                        Text("Stay a Binder Without Asking").tag(SingleDocumentBinderPolicy.stay)
                    }
                    Picker("After a File Is Saved", selection: $preferences.changeFollowing) {
                        Text("Jump to the Change").tag(ChangeFollowing.jump)
                        Text("Stay Here, Marks Only").tag(ChangeFollowing.mark)
                        Text("Ask Whether to Jump").tag(ChangeFollowing.ask)
                    }
                } header: {
                    Text("After a Document Opens")
                } footer: {
                    SettingsFootnote("Changes are marked in Markdown documents.")
                }
            case .view:
                Section {
                    Picker("Scroll Sensitivity", selection: $preferences.wheelSensitivity) {
                        Text("Low").tag(WheelPageTurner.Sensitivity.low)
                        Text("Normal").tag(WheelPageTurner.Sensitivity.normal)
                        Text("High").tag(WheelPageTurner.Sensitivity.high)
                    }.pickerStyle(.segmented)
                }
                // The heading says these are defaults, so the labels need not; "Automatic" is explained once below.
                Section {
                    Picker("View", selection: $preferences.defaultViewLayout) {
                        Text("Automatic").tag(nil as ViewOptions.Layout?)
                        ForEach(ViewOptions.Layout.displayOrder, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    // Not the band's "Page Turn", which is short beside its value; here the label stands alone.
                    Picker("Page Turning", selection: $preferences.defaultPageTurn) {
                        Text("Automatic").tag(nil as ViewOptions.Transition?)
                        ForEach(ViewOptions.Transition.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker("Reading Direction", selection: $preferences.defaultReadingDirection) {
                        Text("Automatic").tag(nil as ViewOptions.Direction?)
                        Text("Left to Right").tag(Optional(ViewOptions.Direction.leftToRight))
                        Text("Right to Left").tag(Optional(ViewOptions.Direction.rightToLeft))
                    }
                    Picker("Scroll Direction", selection: $preferences.defaultScrollAxis) {
                        Text("Automatic").tag(nil as ViewOptions.ScrollAxis?)
                        Text("Vertical").tag(Optional(ViewOptions.ScrollAxis.vertical))
                        Text("Horizontal").tag(Optional(ViewOptions.ScrollAxis.horizontal))
                    }
                    Picker("Show First Page Alone", selection: $preferences.defaultShowsCoverAlone) {
                        Text("Automatic").tag(nil as Bool?)
                        Text("On").tag(Optional(true))
                        Text("Off").tag(Optional(false))
                    }
                    // Beside the choice it depends on. Unlike the defaults around it, it applies to open windows too,
                    // which the footer says.
                    Picker("Window Width When the First Page Is Alone", selection: $preferences.loneCoverWidth) {
                        Text("One Page").tag(LoneCoverWidth.onePage)
                        Text("Two Pages").tag(LoneCoverWidth.twoPages)
                    }
                    Toggle("Join Pages in Single-Page Scrolling", isOn: $preferences.defaultJoinsPages)
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
                    BandVisibilityPicker(selection: $preferences.defaultBandVisibility)
                    // Which parts the toolbar shows, Contents among them, is the arrangement's business.
                    LabeledContent("Parts of the Toolbar") {
                        Button("Arrange…") { arrangementEditor.showSection(.toolbarArrangement) }
                    }
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
                }
            case .pageNumbers:
                Section {
                    Toggle("In View Mode", isOn: $preferences.viewPageNumbers)
                } footer: {
                    SettingsFootnote("Page numbers are never shown in single-page scrolling.")
                }
                // As in View & Page Turn and Printing, the heading says these are defaults.
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
                }
            case .printing:
                Section("Defaults for New Documents") {
                    Picker("Print Layout", selection: $preferences.layoutID) {
                        ForEach(PrintLayout.presets) { layout in
                            Text(verbatim: layout.displayName(language: language)).tag(layout.id)
                        }
                    }
                    Picker("Paper Orientation", selection: $preferences.defaultPaperOrientation) {
                        Text("Automatic").tag(PaperOrientation.auto)
                        Text("Portrait").tag(PaperOrientation.portrait)
                        Text("Landscape").tag(PaperOrientation.landscape)
                    }
                    // The same field, stepper and unit as the margins of the view options and the print screen.
                    LabeledContent("Text Margins") {
                        MarginField(title: "Text Margins", millimeters: preferences.margin, unit: .current) {
                            preferences.margin = $0
                        }
                    }
                }
                // Both belong to the printer: they are where a printer starts until it remembers its own.
                Section {
                    Toggle("Rotate Back Sides 180°", isOn: $preferences.rotateBack)
                    PrintPageOrderPicker(order: $preferences.printPageOrder)
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
                    Picker("Default Style", selection: $preferences.themeID) {
                        DefaultStyleChoices(library: library)
                    }
                    Picker("Default Code Colors", selection: $preferences.defaultCodePaletteID) {
                        Text("Match Style").tag(CodePalette.matchesStyleID)
                        ForEach(library.codePalettes) { palette in
                            Text(verbatim: palette.displayName(language: language)).tag(palette.id)
                        }
                    }
                    LabeledContent("Default Text Size") {
                        TextSizeField(title: "Default Text Size", scale: preferences.defaultTextScale) {
                            preferences.defaultTextScale = $0
                        }
                    }
                } footer: {
                    defaultsNote
                }
                Section {
                    HStack {
                        Button("Open Styles Folder") { library.openFolder("Styles") }
                        Button("Reload") { library.reload() }
                    }
                    libraryError
                }
            case .html:
                Section {
                    Picker("Default HTML Preset", selection: $preferences.presetID) {
                        ForEach(library.presets) { preset in
                            Text(verbatim: preset.displayName(language: language)).tag(preset.id)
                        }
                    }
                    Toggle("Allow JavaScript in HTML", isOn: $preferences.allowsJavaScript)
                } footer: {
                    defaultsNote
                }
                Section {
                    HStack {
                        Button("Open Presets Folder") { library.openFolder("Presets") }
                        Button("Reload") { library.reload() }
                    }
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
            case .keyboardShortcuts: EmptyView()
            case .toolbarArrangement:
                EmptyView()
            }
        }
        .formStyle(.grouped)
        // The grouped form leaves a wide band of nothing under the title bar; the first group starts closer to it.
        .contentMargins(.top, -28, for: .scrollContent)
    }

    private var defaultsNote: some View { SettingsFootnote("Defaults apply to newly opened documents.") }

    @ViewBuilder private var libraryError: some View {
        if let error = library.error {
            Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
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
        text.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

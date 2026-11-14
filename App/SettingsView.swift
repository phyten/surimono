import SurimonoCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case view = "View & Page Turn"
    case pageNumbers = "Page Numbers"
    case printing = "Printing"
    case settingSets = "Setting Sets"
    case styles = "Styles"
    case html = "HTML"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .view: "book"
        case .pageNumbers: "number"
        case .printing: "printer"
        case .settingSets: "slider.horizontal.3"
        case .styles: "textformat"
        case .html: "globe"
        }
    }
}

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var library: UserLibrary
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
                    set: { if let section = $0 { preferences.settingsSection = section } }
                )
            ) {
                ForEach(SettingsSection.allCases) { section in
                    Label(LocalizedStringKey(section.rawValue), systemImage: section.symbol).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            Form {
                switch preferences.settingsSection {
                case .general:
                    LanguagePicker(preferences: preferences)
                    GlobalShortcutSettings()
                    if updater.isAvailable {
                        Section {
                            Toggle(
                                "Check for Updates Automatically",
                                isOn: Binding(
                                    get: { updater.checksAutomatically }, set: { updater.setChecksAutomatically($0) }))
                            Text(
                                "Surimono asks GitHub whether a newer version exists. Nothing about your documents is sent."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            UpdateHandlingPicker(
                                installsAutomatically: Binding(
                                    get: { updater.installsAutomatically },
                                    set: { updater.setInstallsAutomatically($0) }))
                        }
                    }

                    if !updater.isAvailable {
                        Text("Updates are unavailable in development builds.").foregroundStyle(.secondary)
                    }
                case .view:
                    Picker("Scroll Sensitivity", selection: $preferences.wheelSensitivity) {
                        Text("Low").tag(WheelPageTurner.Sensitivity.low)
                        Text("Normal").tag(WheelPageTurner.Sensitivity.normal)
                        Text("High").tag(WheelPageTurner.Sensitivity.high)
                    }.pickerStyle(.segmented)
                    Picker("New Document View", selection: $preferences.defaultViewLayout) {
                        Text("Automatic (Match Document)").tag(nil as ViewOptions.Layout?)
                        ForEach(ViewOptions.Layout.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker("Default Page Turn", selection: $preferences.defaultPageTurn) {
                        Text("Automatic (Match Document)").tag(nil as ViewOptions.Transition?)
                        ForEach(ViewOptions.Transition.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker("Default Reading Direction", selection: $preferences.defaultReadingDirection) {
                        Text("Automatic (Match Document)").tag(nil as ViewOptions.Direction?)
                        Text("Left to Right").tag(Optional(ViewOptions.Direction.leftToRight))
                        Text("Right to Left").tag(Optional(ViewOptions.Direction.rightToLeft))
                    }
                    Picker("Default Scroll Direction", selection: $preferences.defaultScrollAxis) {
                        Text("Automatic (Match Document)").tag(nil as ViewOptions.ScrollAxis?)
                        Text("Vertical").tag(Optional(ViewOptions.ScrollAxis.vertical))
                        Text("Horizontal").tag(Optional(ViewOptions.ScrollAxis.horizontal))
                    }
                    Picker("Show First Page Alone by Default", selection: $preferences.defaultShowsCoverAlone) {
                        Text("Automatic (Match Document)").tag(nil as Bool?)
                        Text("On").tag(Optional(true))
                        Text("Off").tag(Optional(false))
                    }
                    Toggle("Join Pages in Single-Page Scrolling", isOn: $preferences.defaultJoinsPages)
                    defaultsNote
                    // Unlike the defaults above, this applies to open windows as well.
                    Section {
                        Picker("Width of a Lone First Page", selection: $preferences.loneCoverWidth) {
                            Text("One Page").tag(LoneCoverWidth.onePage)
                            Text("Two Pages").tag(LoneCoverWidth.twoPages)
                        }
                        Text("With One Page, the window narrows to the first page while a spread shows it alone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Toolbar") {
                        Picker("Toolbar Arrangement", selection: $preferences.menuArrangement) {
                            Text("Top Only").tag(MenuArrangement.top)
                            Text("Split Top and Bottom").tag(MenuArrangement.split)
                        }
                        BandVisibilityPicker(selection: $preferences.defaultBandVisibility)
                        Text("The toolbar has its own room outside the paper, so it never covers the paper.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Contents") {
                        Picker("Show Contents As", selection: $preferences.outlinePresentation) {
                            Text("Popover").tag(OutlinePresentation.popover)
                            Text("Left Drawer").tag(OutlinePresentation.drawer)
                        }
                        Toggle("Show Contents on the Toolbar", isOn: $preferences.showsOutlineOnBand)
                    }
                    Section {
                        Picker("After a File Is Saved", selection: $preferences.changeFollowing) {
                            Text("Jump to the Change").tag(ChangeFollowing.jump)
                            Text("Stay Here, Marks Only").tag(ChangeFollowing.mark)
                            Text("Ask with a Notice").tag(ChangeFollowing.ask)
                        }
                        Text("Changes are marked in Markdown documents.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("When Opening a Window") {
                        Toggle("Float on Top", isOn: $preferences.defaultAlwaysOnTop)
                    }
                case .pageNumbers:
                    Toggle("In View Mode", isOn: $preferences.viewPageNumbers)
                    Text("Page numbers are never shown in single-page scrolling.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("In Print", selection: furnitureChoice) {
                        ForEach(PrintFurnitureChoice.choices.filter { $0.value != .custom }, id: \.value) { choice in
                            Text(choice.title).tag(choice.value)
                        }
                        // Written on the print screen; it stays until another choice replaces it.
                        if preferences.defaultFurniture.preset == .custom {
                            Text("Specify Contents…").tag(PageFurniture.Preset.custom)
                        }
                    }
                    defaultsNote
                case .printing:
                    Picker("Default Print Layout", selection: $preferences.layoutID) {
                        ForEach(PrintLayout.presets) { layout in
                            Text(verbatim: layout.displayName(language: language)).tag(layout.id)
                        }
                    }
                    Picker("Default Paper Orientation", selection: $preferences.defaultPaperOrientation) {
                        Text("Automatic").tag(PaperOrientation.auto)
                        Text("Portrait").tag(PaperOrientation.portrait)
                        Text("Landscape").tag(PaperOrientation.landscape)
                    }
                    TextField("Margins (mm)", value: $preferences.margin, format: .number)
                    defaultsNote
                    Toggle("Rotate Back Sides 180°", isOn: $preferences.rotateBack)
                    Text("Used for printers and bindings without a remembered rotation.")
                        .font(.caption).foregroundStyle(.secondary)
                    PrintPageOrderPicker(order: $preferences.printPageOrder)
                    Text(PrintPageOrderPicker.hint).font(.caption).foregroundStyle(.secondary)
                case .settingSets:
                    SettingSetsSettings(preferences: preferences, library: library)
                case .styles:
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
                    Picker("Default Text Size", selection: $preferences.defaultTextScale) {
                        ForEach(TextScale.steps, id: \.self) { scale in
                            Text(verbatim: "\(Int((scale * 100).rounded()))%").tag(scale)
                        }
                    }
                    HStack {
                        Button("Open Styles Folder") { library.openFolder("Styles") }
                        Button("Reload") { library.reload() }
                    }
                    libraryError

                    defaultsNote
                case .html:
                    Picker("Default HTML Preset", selection: $preferences.presetID) {
                        ForEach(library.presets) { preset in
                            Text(verbatim: preset.displayName(language: language)).tag(preset.id)
                        }
                    }
                    Toggle("Allow JavaScript in HTML", isOn: $preferences.allowsJavaScript)
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

                    defaultsNote
                }
            }
            .formStyle(.grouped)
            .overlay(alignment: .bottom) { SettingSetRemovalNotice(preferences: preferences) }
            .navigationTitle(Text(LocalizedStringKey(preferences.settingsSection.rawValue)))
        }
        .frame(minWidth: 820, idealWidth: 860, minHeight: 540)
    }

    private var defaultsNote: some View {
        Text("Defaults apply to newly opened documents.").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var libraryError: some View {
        if let error = library.error {
            Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

struct UpdateHandlingPicker: View {
    @Binding var installsAutomatically: Bool

    var body: some View {
        Picker("When an Update Is Found", selection: $installsAutomatically) {
            Text("Notify Me (Default)").tag(false)
            Text("Install Automatically").tag(true)
        }
        Text("Automatic updates are installed when you quit and are ready the next time you open Surimono.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

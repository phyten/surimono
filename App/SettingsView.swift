import SurimonoCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case view = "View & Page Turn"
    case pageNumbers = "Page Numbers"
    case printing = "Printing"
    case styles = "Styles"
    case html = "HTML"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .view: "book"
        case .pageNumbers: "number"
        case .printing: "printer"
        case .styles: "textformat"
        case .html: "globe"
        }
    }
}

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var library: UserLibrary
    @Environment(\.locale) private var locale
    private let updater = AppUpdater.shared
    private var language: String { locale.language.languageCode?.identifier ?? "en" }

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
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
        } detail: {
            Form {
                switch preferences.settingsSection {
                case .general:
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
                    Toggle("Join Pages in Single-Page Scrolling", isOn: $preferences.defaultJoinsPages)
                    defaultsNote
                case .pageNumbers:
                    Toggle("In View Mode", isOn: $preferences.viewPageNumbers)
                    Text("Page numbers are never shown in single-page scrolling.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("In Print", isOn: $preferences.pageNumbers)
                    defaultsNote
                case .printing:
                    Picker("Default Print Layout", selection: $preferences.layoutID) {
                        ForEach(PrintLayout.presets) { layout in
                            Text(verbatim: layout.displayName(language: language)).tag(layout.id)
                        }
                    }
                    TextField("Margins (mm)", value: $preferences.margin, format: .number)
                    Toggle("Rotate Back Sides 180°", isOn: $preferences.rotateBack)
                    defaultsNote
                case .styles:
                    Picker("Default Print Theme", selection: $preferences.themeID) {
                        DefaultStyleChoices(library: library)
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
            .navigationTitle(Text(LocalizedStringKey(preferences.settingsSection.rawValue)))
        }
        .frame(width: 720, height: 520)
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

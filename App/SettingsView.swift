import SurimonoCore
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var library: UserLibrary
    @Environment(\.locale) private var locale
    private let updater = AppUpdater.shared
    private var language: String { locale.language.languageCode?.identifier ?? "en" }

    var body: some View {
        TabView {
            Form {
                Picker("Default Layout", selection: $preferences.layoutID) {
                    ForEach(PrintLayout.presets) { layout in
                        Text(verbatim: layout.displayName(language: language)).tag(layout.id)
                    }
                }
                Text("Defaults apply to newly opened documents.").font(.caption).foregroundStyle(.secondary)
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
            }.tabItem { Label("General", systemImage: "gearshape") }
            Form {
                TextField("Margins (mm)", value: $preferences.margin, format: .number)
                Toggle("Page Numbers", isOn: $preferences.pageNumbers)
                Toggle("Rotate Back Sides 180°", isOn: $preferences.rotateBack)
            }.tabItem { Label("Printing", systemImage: "printer") }
            Form {
                Picker("Default Print Theme", selection: $preferences.themeID) {
                    ForEach(library.themeCategories) { category in
                        Section {
                            ForEach(library.themes.filter { $0.category == category.id }) { theme in
                                Text(verbatim: theme.displayName(language: language)).tag(theme.id)
                            }
                        } header: {
                            Text(verbatim: category.displayName(language: language))
                        }
                    }
                    // Themes without a known category: the user's styles, or every theme if the catalog failed.
                    let others = library.themes.filter { theme in
                        !library.themeCategories.contains { $0.id == theme.category }
                    }
                    if !others.isEmpty {
                        Section("My Styles") {
                            ForEach(others) { theme in
                                Text(verbatim: theme.displayName(language: language)).tag(theme.id)
                            }
                        }
                    }
                }
                HStack {
                    Button("Open Styles Folder") { library.openFolder("Styles") }
                    Button("Reload") { library.reload() }
                }
                libraryError
            }.tabItem { Label("Styles", systemImage: "textformat") }
            Form {
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
            }.tabItem { Label("HTML", systemImage: "globe") }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 540, height: 370)
    }

    @ViewBuilder private var libraryError: some View {
        if let error = library.error {
            Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

import SurimonoCore
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var library: UserLibrary
    @Environment(\.locale) private var locale
    private var language: String { locale.language.languageCode?.identifier ?? "en" }

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                Picker("Default Layout", selection: $preferences.layoutID) {
                    ForEach(PrintLayout.presets) { layout in
                        Text(verbatim: layout.displayName(language: language)).tag(layout.id)
                    }
                }
                Text("Defaults apply to newly opened documents.").font(.caption).foregroundStyle(.secondary)
            }.tabItem { Label("General", systemImage: "gearshape") }
            Form {
                TextField("Margins (mm)", value: $preferences.margin, format: .number)
                Toggle("Page Numbers", isOn: $preferences.pageNumbers)
                Toggle("Rotate Back Sides 180°", isOn: $preferences.rotateBack)
            }.tabItem { Label("Printing", systemImage: "printer") }
            Form {
                Picker("Default Print Theme", selection: $preferences.themeID) {
                    ForEach(library.themes) { theme in
                        Text(verbatim: theme.displayName(language: language)).tag(theme.id)
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
        .preferredColorScheme(preferences.appearance.colorScheme)
    }

    @ViewBuilder private var libraryError: some View {
        if let error = library.error {
            Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

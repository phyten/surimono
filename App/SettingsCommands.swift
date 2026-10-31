import SurimonoCore
import SwiftUI

struct SettingsCommands: Commands {
    @Bindable var preferences: AppPreferences
    let library: UserLibrary
    @Environment(\.openSettings) private var openSettings
    private var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    var body: some Commands {
        CommandMenu("Settings") {
            LanguagePicker(preferences: preferences)
            Divider()
            Picker("Scroll Sensitivity", selection: $preferences.wheelSensitivity) {
                Text("Low").tag(WheelPageTurner.Sensitivity.low)
                Text("Normal").tag(WheelPageTurner.Sensitivity.normal)
                Text("High").tag(WheelPageTurner.Sensitivity.high)
            }
            Picker("Default Page Turn", selection: $preferences.defaultPageTurn) {
                Text("Automatic (Match Document)").tag(nil as ViewOptions.Transition?)
                ForEach(ViewOptions.Transition.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            Picker("New Document View", selection: $preferences.defaultViewLayout) {
                Text("Automatic (Match Document)").tag(nil as ViewOptions.Layout?)
                ForEach(ViewOptions.Layout.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            Divider()
            Toggle("Join Pages in Single-Page Scrolling", isOn: $preferences.defaultJoinsPages)
            Toggle("Page Numbers in View Mode", isOn: $preferences.viewPageNumbers)
            Toggle("Page Numbers in Print", isOn: $preferences.pageNumbers)
            Divider()
            Picker("Default Print Layout", selection: $preferences.layoutID) {
                ForEach(PrintLayout.presets) { layout in
                    Text(verbatim: layout.displayName(language: language)).tag(layout.id)
                }
            }
            Picker("Default Margins", selection: $preferences.margin) {
                ForEach([0, 10, 15, 20, 25], id: \.self) { margin in
                    Text(verbatim: "\(margin) mm").tag(Double(margin))
                }
            }
            Menu("Default Style") {
                Picker("Default Style", selection: $preferences.themeID) {
                    DefaultStyleChoices(library: library)
                }.pickerStyle(.inline)
            }
            Divider()
            // ⌘, stays with the app menu's standard Settings… item, which opens the same window.
            Button("All Settings…") { openSettings() }
        }
    }
}

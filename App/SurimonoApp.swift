import SwiftUI

@main
struct SurimonoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var preferences = AppPreferences()
    @State private var library = UserLibrary()
    private let settingsStore: DocumentSettingsStore

    init() {
        let preferences = AppPreferences()
        _preferences = State(initialValue: preferences)
        let library = UserLibrary()
        _library = State(initialValue: library)
        settingsStore = DocumentSettingsStore(directory: library.root.appendingPathComponent("DocumentSettings"))
        WelcomeController.shared.preferences = preferences
        ImageBundleWindows.shared.preferences = preferences
        ImageBundleWindows.shared.library = library
        ImageBundleWindows.shared.settingsStore = settingsStore
    }

    var body: some Scene {
        DocumentGroup(viewing: SurimonoDocument.self) { configuration in
            DocumentViewer(
                document: configuration.document, fileURL: configuration.fileURL,
                preferences: preferences, library: library, settingsStore: settingsStore)
        }
        // The paper fills the window; the traffic lights appear with the overlay menu.
        .windowStyle(.hiddenTitleBar)
        .commands { DocumentCommands() }
        Settings {
            SettingsView(preferences: preferences, library: library)
        }
    }
}

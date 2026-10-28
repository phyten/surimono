import SwiftUI

@main
struct SurimonoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var preferences = AppPreferences()
    @State private var library = UserLibrary()

    init() {
        let preferences = AppPreferences()
        _preferences = State(initialValue: preferences)
        let library = UserLibrary()
        _library = State(initialValue: library)
        WelcomeController.shared.preferences = preferences
        ImageBundleWindows.shared.preferences = preferences
        ImageBundleWindows.shared.library = library
    }

    var body: some Scene {
        DocumentGroup(viewing: SurimonoDocument.self) { configuration in
            DocumentViewer(
                document: configuration.document, fileURL: configuration.fileURL,
                preferences: preferences, library: library)
        }
        .commands { DocumentCommands() }
        Settings {
            SettingsView(preferences: preferences, library: library)
        }
    }
}

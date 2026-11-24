import SurimonoRendering
import SwiftUI
import WebKit

@main
enum SurimonoMain {
    @MainActor static func main() {
        #if DEBUG
            DebugMenuDump.beginOwnershipTrace()
        #endif
        AppKitShell.run()
    }
}

struct ViewerEnvironment {
    let preferences: AppPreferences
    let library: UserLibrary
    let settingsStore: DocumentSettingsStore
    let arrangementEditor: BandArrangementEditorSession

    var settingsView: SettingsView {
        SettingsView(preferences: preferences, library: library, arrangementEditor: arrangementEditor)
    }

    init() {
        #if !APP_STORE
            if WKWebView.instancesRespond(to: NSSelectorFromString("_setDrawsBackground:")) {
                WebPaginator.clearBackground = { $0.setValue(false, forKey: "drawsBackground") }
            }
        #endif
        preferences = AppPreferences.shared
        library = UserLibrary()
        settingsStore = DocumentSettingsStore(directory: library.root.appendingPathComponent("DocumentSettings"))
        arrangementEditor = BandArrangementEditorSession(preferences: preferences)
        BandArrangementEditorSession.app = arrangementEditor
        RecentFileHistory.install(preferences: preferences)
        WelcomeController.shared.preferences = preferences
        ImageBundleWindows.shared.preferences = preferences
        ImageBundleWindows.shared.library = library
        ImageBundleWindows.shared.settingsStore = settingsStore
        BinderWindows.shared.preferences = preferences
        BinderWindows.shared.library = library
        BinderWindows.shared.settingsStore = settingsStore
        ClipboardWindows.shared.preferences = preferences
        ClipboardWindows.shared.library = library
        StreamingPreviewWindows.shared.preferences = preferences
        StreamingPreviewWindows.shared.library = library
        ShortcutEnvironment.preferences = preferences
        ShortcutEnvironment.library = library
        // Sparkle keeps its schedule from launch, not from the first time the menu is opened.
        _ = AppUpdater.shared
    }
}

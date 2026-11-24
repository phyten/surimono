import SurimonoRendering
import SwiftUI
import WebKit

@main
enum SurimonoMain {
    @MainActor static func main() {
        #if DEBUG
            DebugMenuDump.beginOwnershipTrace()
        #endif
        if AppKitShell.requested {
            AppKitShell.run()
            return
        }
        DocumentShareMenu.useExplicitPlacement(on: NSDocumentController.self)
        // SwiftUI creates its own NSApplication singleton unless ours exists before App.main().
        _ = ViewerApplication.shared
        SurimonoApp.main()
    }
}

struct SurimonoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let environment = ViewerEnvironment()
    var body: some Scene {
        DocumentGroup(viewing: SurimonoDocument.self) { configuration in
            DocumentViewer(
                document: configuration.document, fileURL: configuration.fileURL,
                preferences: environment.preferences, library: environment.library,
                settingsStore: environment.settingsStore
            )
            #if DEBUG
                .snapshotControlAppearance()
            #endif
        }
        // The paper fills the window; the traffic lights appear with the overlay menu.
        .windowStyle(.hiddenTitleBar)
        .commands {
            DocumentCommands(preferences: environment.preferences, menuState: ShortcutDispatcher.shared.menus.menuState)
        }
        Settings {
            environment.settingsView
                #if DEBUG
                    .snapshotControlAppearance()
                #endif
        }
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

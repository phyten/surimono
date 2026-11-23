import SurimonoRendering
import SwiftUI
import WebKit

@main
enum SurimonoMain {
    @MainActor static func main() {
        // SwiftUI creates its own NSApplication singleton unless ours exists before App.main().
        _ = ViewerApplication.shared
        SurimonoApp.main()
    }
}

struct SurimonoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var preferences: AppPreferences
    @State private var library = UserLibrary()
    private let settingsStore: DocumentSettingsStore
    /// Outlives the Settings window, which SwiftUI may build again.
    private let arrangementEditor: BandArrangementEditorSession

    init() {
        #if !APP_STORE
            if WKWebView.instancesRespond(to: NSSelectorFromString("_setDrawsBackground:")) {
                WebPaginator.clearBackground = { $0.setValue(false, forKey: "drawsBackground") }
            }
        #endif
        let preferences = AppPreferences.shared
        _preferences = State(initialValue: preferences)
        let library = UserLibrary()
        _library = State(initialValue: library)
        settingsStore = DocumentSettingsStore(directory: library.root.appendingPathComponent("DocumentSettings"))
        arrangementEditor = BandArrangementEditorSession(preferences: preferences)
        BandArrangementEditorSession.app = arrangementEditor
        OpenRouter.shared.openAsText = { [settingsStore] url in
            do {
                try await SourceFileOpening.open(url) { file, bytes in
                    let model = DocumentViewModel(
                        data: bytes, fileURL: file, format: .plainText, preferences: preferences,
                        library: library, settingsStore: settingsStore)
                    return MemoryDocumentWindowController(model: model, onClose: {})
                }
                return true
            } catch {
                NSApp.presentError(error)
                return false
            }
        }
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

    var body: some Scene {
        DocumentGroup(viewing: SurimonoDocument.self) { configuration in
            DocumentViewer(
                document: configuration.document, fileURL: configuration.fileURL,
                preferences: preferences, library: library, settingsStore: settingsStore
            )
            #if DEBUG
                .snapshotControlAppearance()
            #endif
        }
        // The paper fills the window; the traffic lights appear with the overlay menu.
        .windowStyle(.hiddenTitleBar)
        .commands {
            DocumentCommands(preferences: preferences, menuState: ShortcutDispatcher.shared.menus.menuState)
        }
        Settings {
            SettingsView(preferences: preferences, library: library, arrangementEditor: arrangementEditor)
                #if DEBUG
                    .snapshotControlAppearance()
                #endif
        }
    }
}

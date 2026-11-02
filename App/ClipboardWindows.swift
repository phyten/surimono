import AppKit
import SurimonoCore

final class ClipboardWindows {
    static let shared: ClipboardWindows = ClipboardWindows(
        openFiles: { OpenRouter.shared.open($0, from: $1) },
        warn: { window in
            let alert = NSAlert()
            alert.messageText = String(localized: "There is nothing to open on the clipboard")
            alert.informativeText = String(localized: "Copy Markdown, text, or an image, then try again.")
            alert.addButton(withTitle: String(localized: "OK"))
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }, closeWelcome: { WelcomeController.shared.close() })

    var preferences: AppPreferences?
    var library: UserLibrary?
    var settingsStore: DocumentSettingsStore?
    private var controllers: [ContentHash: MemoryDocumentWindowController] = [:]
    private var cascadePoint = NSPoint.zero
    private let openFiles: ([URL], NSWindow?) -> Void
    private let warn: (NSWindow?) -> Void
    private let closeWelcome: () -> Void

    var hasWindows: Bool { !controllers.isEmpty }

    init(
        openFiles: @escaping ([URL], NSWindow?) -> Void, warn: @escaping (NSWindow?) -> Void,
        closeWelcome: @escaping () -> Void
    ) {
        self.openFiles = openFiles
        self.warn = warn
        self.closeWelcome = closeWelcome
    }

    static func content(from pasteboard: NSPasteboard) -> ClipboardContent {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return ClipboardContent(
            fileURLs: urls ?? [], text: pasteboard.string(forType: .string),
            png: pasteboard.data(forType: .png), tiff: pasteboard.data(forType: .tiff))
    }

    @discardableResult
    func open(from pasteboard: NSPasteboard = .general, window: NSWindow? = NSApp.keyWindow)
        -> MemoryDocumentWindowController?
    {
        switch Self.content(from: pasteboard) {
        case .files(let urls):
            openFiles(urls, window)
            return nil
        case .empty:
            warn(window)
            return nil
        case .document(let data, let format):
            let hash = ContentHash.of(data)
            if let existing = controllers[hash] {
                existing.window?.deminiaturize(nil)
                existing.showWindow(nil)
                existing.window?.makeKeyAndOrderFront(nil)
                closeWelcome()
                return existing
            }
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            let model = DocumentViewModel(
                data: data, fileURL: nil, format: format,
                preferences: preferences ?? AppPreferences(), library: library ?? UserLibrary(),
                settingsStore: settingsStore, title: String(localized: "Clipboard") + " " + time)
            let controller = MemoryDocumentWindowController(model: model) { [weak self] in
                self?.controllers.removeValue(forKey: hash)
            }
            controllers[hash] = controller
            if let window = controller.window { cascadePoint = window.cascadeTopLeft(from: cascadePoint) }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            closeWelcome()
            return controller
        }
    }
}

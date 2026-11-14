import AppKit
import SurimonoCore

final class ClipboardWindows {
    static let shared: ClipboardWindows = ClipboardWindows(
        openFiles: { OpenRouter.shared.open($0, from: $1, printing: $2) },
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
    private let openFiles: ([URL], NSWindow?, Bool) -> Void
    private let warn: (NSWindow?) -> Void
    private let closeWelcome: () -> Void

    var hasWindows: Bool { !controllers.isEmpty }

    init(
        openFiles: @escaping ([URL], NSWindow?, Bool) -> Void, warn: @escaping (NSWindow?) -> Void,
        closeWelcome: @escaping () -> Void
    ) {
        self.openFiles = openFiles
        self.warn = warn
        self.closeWelcome = closeWelcome
    }

    static func content(from pasteboard: NSPasteboard) -> ClipboardContent {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        // Apps that keep only rich text offer no plain string.
        let richText = pasteboard.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
        return ClipboardContent(
            fileURLs: urls ?? [], text: pasteboard.string(forType: .string) ?? richText?.string,
            png: pasteboard.data(forType: .png), tiff: pasteboard.data(forType: .tiff))
    }

    @discardableResult
    func open(from pasteboard: NSPasteboard = .general, window: NSWindow? = NSApp.keyWindow, printing: Bool = false)
        -> MemoryDocumentWindowController?
    {
        switch Self.content(from: pasteboard) {
        case .files(let urls):
            openFiles(urls, window, printing)
            return nil
        case .empty:
            warn(window)
            return nil
        case .document(let data, let format):
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            return open(data, format: format, title: String(localized: "Clipboard") + " " + time, printing: printing)
        }
    }

    /// Opens bytes that have no file. The same content has one window, whichever way it came in.
    @discardableResult
    func open(_ data: Data, format: DocumentFormat, title: String, printing: Bool = false)
        -> MemoryDocumentWindowController
    {
        let hash = ContentHash.of(data)
        let controller = controllers[hash] ?? makeController(data, format: format, title: title, hash: hash)
        controller.window?.deminiaturize(nil)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        closeWelcome()
        if printing { controller.model.requestPrintMode() }
        return controller
    }

    private func makeController(_ data: Data, format: DocumentFormat, title: String, hash: ContentHash)
        -> MemoryDocumentWindowController
    {
        let model = DocumentViewModel(
            data: data, fileURL: nil, format: format,
            preferences: preferences ?? AppPreferences(), library: library ?? UserLibrary(),
            settingsStore: settingsStore, title: title)
        let controller = MemoryDocumentWindowController(model: model) { [weak self] in
            self?.controllers.removeValue(forKey: hash)
        }
        controllers[hash] = controller
        if let window = controller.window { cascadePoint = window.cascadeTopLeft(from: cascadePoint) }
        return controller
    }
}

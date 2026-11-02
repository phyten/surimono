import AppKit
import SurimonoCore

@MainActor
final class OpenRouter {
    static let shared: OpenRouter = OpenRouter(
        openDocument: { url, completion in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let error { NSApp.presentError(error) }
                // Explicitly bring an already open document forward as well.
                document?.showWindows()
                completion(document != nil)
            }
        },
        openBundle: { ImageBundleWindows.shared.open($0, excluded: $1) },
        openBinder: { BinderWindows.shared.open($0, excluded: $1) },
        warn: { window in
            let alert = NSAlert()
            alert.messageText = String(localized: "No supported documents to combine")
            alert.informativeText = String(
                localized:
                    "Choose Markdown, Org, text, CSV, LaTeX, HTML, PDF, or image files. Folders and ZIP archives cannot be combined."
            )
            alert.addButton(withTitle: String(localized: "OK"))
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        },
        hasOpenWindows: {
            !NSDocumentController.shared.documents.isEmpty || ImageBundleWindows.shared.hasWindows
                || ClipboardWindows.shared.hasWindows || BinderWindows.shared.hasWindows
        },
        showWelcome: { WelcomeController.shared.show() })

    private let openDocument: (URL, @escaping (Bool) -> Void) -> Void
    private let openBundle: ([URL], [URL]) -> Void
    private let openBinder: ([URL], [URL]) -> Void
    private let warn: (NSWindow?) -> Void
    private let hasOpenWindows: () -> Bool
    private let showWelcome: () -> Void
    /// Opens that have not finished, so that the welcome window does not cover a document that is still loading.
    private(set) var pendingOpens = 0

    /// Replaceable so that tests can follow the menu action without presenting a panel.
    var presentOpenPanel: (@escaping ([URL]) -> Void) -> Void = { completion in
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SurimonoDocument.readableContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK { completion(panel.urls) }
        }
    }

    init(
        openDocument: @escaping (URL, @escaping (Bool) -> Void) -> Void, openBundle: @escaping ([URL], [URL]) -> Void,
        openBinder: @escaping ([URL], [URL]) -> Void,
        warn: @escaping (NSWindow?) -> Void, hasOpenWindows: @escaping () -> Bool, showWelcome: @escaping () -> Void
    ) {
        self.openDocument = openDocument
        self.openBundle = openBundle
        self.openBinder = openBinder
        self.warn = warn
        self.hasOpenWindows = hasOpenWindows
        self.showWelcome = showWelcome
    }

    @discardableResult
    func open(_ urls: [URL], from window: NSWindow? = nil) -> Bool {
        let request = OpenRequest(urls: urls.filter(\.isFileURL))
        guard request != .empty else { return false }
        switch request {
        case .single(let url):
            pendingOpens += 1
            openDocument(url) { [weak self] opened in self?.finishOpening(opened) }
        case .imageBundle(let urls, let excluded): openBundle(urls, excluded)
        case .binder(let urls, let excluded): openBinder(urls, excluded)
        case .unsupported: warn(window)
        case .empty: break
        }
        return true
    }

    func showOpenPanel() {
        presentOpenPanel { [weak self] urls in self?.open(urls) }
    }

    /// Shows the welcome window unless something is open or still opening, as after a launch that opened nothing.
    func showWelcomeIfIdle() {
        if pendingOpens == 0, !hasOpenWindows() { showWelcome() }
    }

    private func finishOpening(_ opened: Bool) {
        pendingOpens -= 1
        // A document that fails to open, for example at launch, must not leave the app without any window.
        if !opened { showWelcomeIfIdle() }
    }
}

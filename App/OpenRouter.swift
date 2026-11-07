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
                || StreamingPreviewWindows.shared.hasWindow
        },
        showWelcome: { WelcomeController.shared.show() },
        openMemory: { data, format, printing in
            ClipboardWindows.shared.open(
                data, format: format, title: String(localized: "Selected Text"), printing: printing)
        },
        openIncludes: { BinderWindows.shared.open($0) },
        openWindows: { DocumentWindows.shared.openModels })

    private let openDocument: (URL, @escaping (Bool) -> Void) -> Void
    private let openBundle: ([URL], [URL]) -> DocumentViewModel?
    private let openBinder: ([URL], [URL]) -> DocumentViewModel?
    private let warn: (NSWindow?) -> Void
    private let hasOpenWindows: () -> Bool
    private let showWelcome: () -> Void
    private let openMemory: (Data, DocumentFormat, Bool) -> Void
    private let openIncludes: (MarkdownIncludes.Plan) -> Void
    private let openWindows: () -> [DocumentViewModel]
    /// Single files asked to open on the print tray. The document's model appears only with its window, and it is the
    /// one window that shows the file as itself; a binder or a bundle holding the same file is another print job.
    private var printRequests: Set<URL> = []
    /// Where documents go back to, for a binder made from them that is being undone.
    private var restorations: [URL: BinderOrigin] = [:]
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
        openDocument: @escaping (URL, @escaping (Bool) -> Void) -> Void,
        openBundle: @escaping ([URL], [URL]) -> DocumentViewModel?,
        openBinder: @escaping ([URL], [URL]) -> DocumentViewModel?,
        warn: @escaping (NSWindow?) -> Void, hasOpenWindows: @escaping () -> Bool, showWelcome: @escaping () -> Void,
        openMemory: @escaping (Data, DocumentFormat, Bool) -> Void = { _, _, _ in },
        openIncludes: @escaping (MarkdownIncludes.Plan) -> Void = { _ in },
        openWindows: @escaping () -> [DocumentViewModel] = { [] }
    ) {
        self.openDocument = openDocument
        self.openBundle = openBundle
        self.openBinder = openBinder
        self.warn = warn
        self.hasOpenWindows = hasOpenWindows
        self.showWelcome = showWelcome
        self.openMemory = openMemory
        self.openIncludes = openIncludes
        self.openWindows = openWindows
    }

    @discardableResult
    func open(_ urls: [URL], from window: NSWindow? = nil, printing: Bool = false) -> Bool {
        let request = OpenRequest(urls: urls.filter(\.isFileURL))
        guard request != .empty else { return false }
        switch request {
        case .single(let url):
            if printing { printRequests.insert(url.standardizedFileURL) }
            pendingOpens += 1
            openDocument(url) { [weak self] opened in
                if !opened { self?.printRequests.remove(url.standardizedFileURL) }
                self?.finishOpening(opened)
            }
        case .imageBundle(let urls, let excluded):
            let model = openBundle(urls, excluded)
            if printing { model?.requestPrintMode() }
        case .binder(let urls, let excluded):
            let model = openBinder(urls, excluded)
            if printing { model?.requestPrintMode() }
        case .unsupported: warn(window)
        case .empty: break
        }
        // A window that was open already shows nothing new, so nothing else would notice the request.
        for model in openWindows() { printIfRequested(model) }
        return true
    }

    /// What a service hands over: files take the way of any other file, and text and images open from memory, as the
    /// clipboard's do.
    @discardableResult
    func open(_ content: ClipboardContent, printing: Bool) -> Bool {
        switch content {
        case .files(let urls): return open(urls, printing: printing)
        case .document(let data, let format):
            openMemory(data, format, printing)
            return true
        case .empty: return false
        }
    }

    /// A parent file's binder, in the order the parent names its documents.
    func open(includes plan: MarkdownIncludes.Plan) {
        openIncludes(plan)
    }

    /// Opens a document again where it was when a binder took its place.
    func reopen(_ url: URL, restoring origin: BinderOrigin, completion: @escaping (Bool) -> Void) {
        let key = url.standardizedFileURL
        restorations[key] = origin
        if origin.wasPrinting { printRequests.insert(key) }
        pendingOpens += 1
        openDocument(url) { [weak self] opened in
            if !opened {
                self?.restorations.removeValue(forKey: key)
                self?.printRequests.remove(key)
            }
            self?.finishOpening(opened)
            completion(opened)
        }
    }

    /// Takes the window to the print tray if it is the document of a file that was asked to open there.
    func printIfRequested(_ model: DocumentViewModel) {
        guard let url = model.fileURL?.standardizedFileURL else { return }
        if let origin = restorations.removeValue(forKey: url) { model.restoreWindow(origin) }
        guard printRequests.remove(url) != nil else { return }
        model.requestPrintMode()
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
        for model in openWindows() { printIfRequested(model) }
        // A document that fails to open, for example at launch, must not leave the app without any window.
        if !opened { showWelcomeIfIdle() }
    }
}

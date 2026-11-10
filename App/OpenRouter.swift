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
        openMemory: { data, format, title, printing in
            ClipboardWindows.shared.open(
                data, format: format, title: title ?? String(localized: "Selected Text"), printing: printing)
        },
        openIncludes: { BinderWindows.shared.open($0) },
        openWindows: { DocumentWindows.shared.openModels }, isActive: { NSApp.isActive })

    private let openDocument: (URL, @escaping (Bool) -> Void) -> Void
    private let openBundle: ([URL], [URL]) -> DocumentViewModel?
    private let openBinder: ([URL], [URL]) -> DocumentViewModel?
    private let warn: (NSWindow?) -> Void
    private let hasOpenWindows: () -> Bool
    private let showWelcome: () -> Void
    private let openMemory: (Data, DocumentFormat, String?, Bool) -> Void
    private let openIncludes: (MarkdownIncludes.Plan) -> Void
    private let openWindows: () -> [DocumentViewModel]
    private let isActive: () -> Bool
    /// Work for a caller outside the app that shows no window, such as an export for Shortcuts.
    private(set) var headlessWork = 0
    /// The app was launched without coming forward, so the welcome window waits for the reader to come to the app.
    private var awaitsReader = false
    /// Access to files from outside the app, kept until the window of the document that is opening takes it over.
    private var arrivingAccess: [URL: [FolderAccess.Lease]] = [:]
    /// Single files asked to open on the print tray. The document's model appears only with its window, and it is the
    /// one window that shows the file as itself; a binder or a bundle holding the same file is another print job.
    private var printRequests: Set<URL> = []
    /// Where documents go back to, for a binder made from them that is being undone.
    private var restorations: [URL: BinderOrigin] = [:]
    /// Opens that have not finished, so that the welcome window does not cover a document that is still loading.
    private(set) var pendingOpens = 0

    /// Replaceable so that tests can open a recent binder without the sandbox.
    var recentFiles = RecentBinderFiles()
    /// Replaceable so that tests can follow a recent binder's moved files without the app's preferences.
    var replaceRecentBinder: (RecentBinder, RecentBinder) -> Void = {
        BinderWindows.shared.preferences?.replaceRecentBinder($0, with: $1)
    }

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
        openMemory: @escaping (Data, DocumentFormat, String?, Bool) -> Void = { _, _, _, _ in },
        openIncludes: @escaping (MarkdownIncludes.Plan) -> Void = { _ in },
        openWindows: @escaping () -> [DocumentViewModel] = { [] }, isActive: @escaping () -> Bool = { true }
    ) {
        self.isActive = isActive
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

    /// `access` is what lets the files be read when they come from outside the app's sandbox. It goes to the window
    /// that opens them and ends with it; access to a file that no new window shows ends here.
    @discardableResult
    func open(
        _ urls: [URL], from window: NSWindow? = nil, printing: Bool = false, access: [FolderAccess.Lease] = []
    ) -> Bool {
        let request = OpenRequest(urls: urls.filter(\.isFileURL))
        guard request != .empty else {
            for lease in access { lease.close() }
            return false
        }
        switch request {
        case .single(let url):
            let key = url.standardizedFileURL
            if printing { printRequests.insert(key) }
            // A window that shows the file already reads it by its own means and is only brought forward.
            if openWindows().contains(where: { $0.fileURL?.standardizedFileURL == key }) {
                for lease in access { lease.close() }
            } else if !access.isEmpty {
                arrivingAccess[key, default: []] += access
            }
            pendingOpens += 1
            openDocument(url) { [weak self] opened in
                if !opened {
                    self?.printRequests.remove(key)
                    self?.giveUpAccess(for: key)
                }
                self?.finishOpening(opened)
            }
        case .imageBundle(let urls, let excluded):
            let model = openBundle(urls, excluded)
            Self.hand(access, for: urls, to: model)
            if printing { model?.requestPrintMode() }
        case .binder(let urls, let excluded):
            let model = openBinder(urls, excluded)
            Self.hand(access, for: urls, to: model)
            if printing { model?.requestPrintMode() }
        case .unsupported:
            for lease in access { lease.close() }
            warn(window)
        case .empty: break
        }
        // A window that was open already shows nothing new, so nothing else would notice the request.
        for model in openWindows() { printIfRequested(model) }
        return true
    }

    /// What a service hands over: files take the way of any other file, and text and images open from memory, as the
    /// clipboard's do, under `title` when what they came from has a name.
    @discardableResult
    func open(_ content: ClipboardContent, printing: Bool, title: String? = nil) -> Bool {
        switch content {
        case .files(let urls): return open(urls, printing: printing)
        case .document(let data, let format):
            openMemory(data, format, title, printing)
            return true
        case .empty: return false
        }
    }

    /// A parent file's binder, in the order the parent names its documents.
    func open(includes plan: MarkdownIncludes.Plan) {
        openIncludes(plan)
    }

    /// A binder the reader closed, from the Recent Binders menu. The reader made these files a binder, so it stays one
    /// even when they are all images, which `OpenRequest` would open as an image bundle. A file that is gone opens
    /// anyway and shows as unreadable in the list.
    func open(recentBinder binder: RecentBinder) {
        let located = recentFiles.locate(binder)
        if located.binder != binder { replaceRecentBinder(binder, located.binder) }
        located.keep(until: openBinder(located.urls, [])?.window)
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

    /// The documents every open window shows.
    var openModels: [DocumentViewModel] { openWindows() }

    /// The window's model keeps the access to the files it shows; access to the files left out ends at once.
    private static func hand(_ access: [FolderAccess.Lease], for urls: [URL], to model: DocumentViewModel?) {
        let shown = Set(urls.map(\.standardizedFileURL))
        let kept = access.filter { shown.contains($0.url.standardizedFileURL) }
        for lease in access where !shown.contains(lease.url.standardizedFileURL) { lease.close() }
        if let model { model.keep(kept) } else { for lease in kept { lease.close() } }
    }

    /// Gives a document's window the access that waits for its file. The window takes it as soon as it exists, not
    /// when its pages are done: a window closed while it still lays out its pages would leave the access waiting.
    func handAccess(to model: DocumentViewModel) {
        // From here on what waits for this file belongs to a later request, which this model must not give up
        // when it ends.
        model.hasTakenItsFileAccess = true
        guard let url = model.fileURL?.standardizedFileURL, let access = arrivingAccess.removeValue(forKey: url)
        else { return }
        model.keep(access)
    }

    /// Ends the access that waits for a file whose window went away before taking it.
    func giveUpAccess(for url: URL) {
        for lease in arrivingAccess.removeValue(forKey: url.standardizedFileURL) ?? [] { lease.close() }
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

    /// Shows the welcome window unless something is open, still opening, or being worked on without a window.
    func showWelcomeIfIdle() {
        if pendingOpens == 0, headlessWork == 0, !hasOpenWindows() { showWelcome() }
    }

    /// The check a launch makes once restored windows had time to appear. The system launches the app without
    /// bringing it forward to do work for Shortcuts, whether or not that work has begun by now; a window then would
    /// greet nobody. The welcome window waits until the reader comes to the app.
    func showWelcomeAfterLaunch() {
        guard isActive() else {
            awaitsReader = true
            return
        }
        showWelcomeIfIdle()
    }

    /// The reader came to an app that was launched in the background. Only that first arrival counts: coming back
    /// to the app after closing its last window shows nothing, as before.
    func showWelcomeOnArrival() {
        guard awaitsReader else { return }
        awaitsReader = false
        showWelcomeIfIdle()
    }

    func beginHeadlessWork() {
        headlessWork += 1
    }

    func endHeadlessWork() {
        headlessWork -= 1
    }

    private func finishOpening(_ opened: Bool) {
        pendingOpens -= 1
        for model in openWindows() {
            handAccess(to: model)
            printIfRequested(model)
        }
        // A document that fails to open, for example at launch, must not leave the app without any window.
        if !opened { showWelcomeIfIdle() }
    }
}

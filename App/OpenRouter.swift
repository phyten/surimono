import AppKit
import SurimonoCore
import SurimonoRendering

@MainActor
final class OpenRouter {
    struct BinderFiles {
        let urls: [URL]
        /// A recent binder is resolved when reopened. A new binder already has its formats from the worker.
        var formats: [URL: DocumentFormat]?
    }

    struct OpenedFile {
        let destination: DocumentWindows.Registration
        var wasAlreadyOpen = false
    }

    static let shared: OpenRouter = OpenRouter(
        openDocument: { url, completion in
            if url.pathExtension.lowercased() == "doc" {
                NSApp.presentError(DocxError.encryptedOrLegacy)
                completion(nil)
                return
            }
            // Observe closes even when they precede both view registration and the open callback.
            let windows = DocumentWindows.shared
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
                document, wasAlreadyOpen, error in
                if let error { NSApp.presentError(error) }
                // Explicitly bring an already open document forward as well.
                let opened = document.map { windows.opened($0, wasAlreadyOpen: wasAlreadyOpen) }
                if let opened, !opened.destination.isClosed { document?.showWindows() }
                completion(opened)
            }
        },
        openBundle: { ImageBundleWindows.shared.open($0, excluded: $1) },
        openBinder: { BinderWindows.shared.open($0.urls, excluded: $1, formats: $0.formats) },
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
        openMemoryFile: { data, format, fileName, printing in
            ClipboardWindows.shared.open(data, format: format, title: fileName, printing: printing, fileName: fileName)
        },
        openIncludes: { BinderWindows.shared.open($0) },
        openWindows: { DocumentWindows.shared.openModels }, isActive: { NSApp.isActive },
        openText: { text, hints, title, printing in
            ClipboardWindows.shared.open(
                text: text, hints: hints, title: title ?? String(localized: "Selected Text"), source: .selection,
                window: NSApp.keyWindow, printing: printing)
        },
        refuse: { error in
            // The words the window itself uses for the same refusal.
            NSApp.presentError(
                NSError(
                    domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                    userInfo: [NSLocalizedDescriptionKey: DocumentViewModel.message(for: error)]))
        })

    /// Replaceable so that tests can stand in for a file without writing it.
    var route: @Sendable (URL) -> SourceFileOpening.Route = { SourceFileOpening.route(for: $0) }
    private var openingTask: Task<Void, Never>?

    /// Wait until the current requests have been handed to their windows, including any forced-text read.
    func waitForOpeningRequests() async { await openingTask?.value }

    private func enqueueOpening(_ work: @escaping @MainActor () async -> Void) {
        let previous = openingTask
        openingTask = Task {
            await previous?.value
            await work()
        }
    }

    private let openDocument: (URL, @escaping (OpenedFile?) -> Void) -> Void
    var openAsText: @MainActor (URL) async -> OpenedFile?
    private let refuse: (any Error) -> Void
    private let openBundle: ([URL], [URL]) -> DocumentViewModel?
    private let openBinder: (BinderFiles, [URL]) -> DocumentViewModel?
    private let warn: (NSWindow?) -> Void
    private let hasOpenWindows: () -> Bool
    private let showWelcome: () -> Void
    private let openMemory: (Data, DocumentFormat, String?, Bool) -> Void
    private let openMemoryFile: ((Data, DocumentFormat, String, Bool) -> Void)?
    private let openText: (String, ClipboardFormatHints, String?, Bool) -> Void
    private let openIncludes: (MarkdownIncludes.Plan) -> Void
    private let openWindows: () -> [DocumentViewModel]
    private let isActive: () -> Bool
    /// Work for a caller outside the app that shows no window, such as an export for Shortcuts.
    private(set) var headlessWork = 0
    /// The app was launched without coming forward, so the welcome window waits for the reader to come to the app.
    private var awaitsReader = false
    /// Each completion owns its request even when AppKit finishes two opens of the same URL out of order.
    private struct SingleFileRequest {
        let url: URL
        let printing: Bool
        let access: [FolderAccess.Lease]
        var origin: BinderOrigin?

        func deliver(_ opened: OpenedFile?) {
            guard let opened else {
                for lease in access { lease.close() }
                return
            }
            guard printing || !access.isEmpty || origin != nil else { return }
            let reused = opened.wasAlreadyOpen
            opened.destination.whenRegistered { model in
                guard let model else {
                    for lease in access { lease.close() }
                    return
                }
                if reused { for lease in access { lease.close() } } else { model.keep(access) }
                if let origin, origin.leavingBinder && reused {
                    // A separate reader may have opened the file while the binder's route was pending.
                    if origin.wasPrinting { model.requestPrintMode() }
                    return
                }
                if let origin {
                    if origin.leavingBinder {
                        model.restoreAfterLeavingBinder(origin)
                    } else {
                        model.restoreWindow(origin)
                    }
                }
                if printing { model.requestPrintMode() }
            }
        }
    }

    /// Opens that have not finished, so that the welcome window does not cover a document that is still loading.
    private(set) var pendingOpens = 0

    /// Replaceable so that tests can open a recent binder without the sandbox.
    var recentFiles = RecentBinderFiles()
    /// Replaceable so that tests can follow a recent binder's moved files without the app's preferences.
    var replaceRecentBinder: (RecentBinder, RecentBinder) -> Void = {
        BinderWindows.shared.preferences?.replaceRecentBinder($0, with: $1)
    }

    /// Replaceable so that tests can open the guide without the app's bundle.
    var gettingStartedURL: () -> URL? = { GettingStarted.url() }

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
        openDocument: @escaping (URL, @escaping (OpenedFile?) -> Void) -> Void,
        openBundle: @escaping ([URL], [URL]) -> DocumentViewModel?,
        openBinder: @escaping (BinderFiles, [URL]) -> DocumentViewModel?,
        warn: @escaping (NSWindow?) -> Void, hasOpenWindows: @escaping () -> Bool, showWelcome: @escaping () -> Void,
        openMemory: @escaping (Data, DocumentFormat, String?, Bool) -> Void = { _, _, _, _ in },
        openMemoryFile: ((Data, DocumentFormat, String, Bool) -> Void)? = nil,
        openIncludes: @escaping (MarkdownIncludes.Plan) -> Void = { _ in },
        openWindows: @escaping () -> [DocumentViewModel] = { [] }, isActive: @escaping () -> Bool = { true },
        openText: @escaping (String, ClipboardFormatHints, String?, Bool) -> Void = { _, _, _, _ in },
        openAsText: @escaping @MainActor (URL) async -> OpenedFile? = { _ in nil },
        refuse: @escaping (any Error) -> Void = { _ in }
    ) {
        self.openAsText = openAsText
        self.refuse = refuse
        self.isActive = isActive
        self.openText = openText
        self.openDocument = openDocument
        self.openBundle = openBundle
        self.openBinder = openBinder
        self.warn = warn
        self.hasOpenWindows = hasOpenWindows
        self.showWelcome = showWelcome
        self.openMemory = openMemory
        self.openMemoryFile = openMemoryFile
        self.openIncludes = openIncludes
        self.openWindows = openWindows
    }

    /// `access` is what lets the files be read when they come from outside the app's sandbox. It goes to the window
    /// that opens them and ends with it; access to a file that no new window shows ends here.
    @discardableResult
    func open(
        _ urls: [URL], from window: NSWindow? = nil, printing: Bool = false, access: [FolderAccess.Lease] = []
    ) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard let url = files.first else {
            for lease in access { lease.close() }
            return false
        }
        if files.count == 1 {
            openSingle(SingleFileRequest(url: url, printing: printing, access: access))
        } else {
            pendingOpens += 1
            enqueueOpening { [self] in
                let plan = await Task.detached(priority: .userInitiated) { OpenRequest.plan(files) }.value
                let model: DocumentViewModel?
                switch plan.request {
                case .imageBundle(let urls, let excluded):
                    model = openBundle(urls, excluded)
                    Self.hand(access, for: urls, to: model)
                case .binder(let urls, let excluded):
                    model = openBinder(BinderFiles(urls: urls, formats: plan.binderFormats), excluded)
                    Self.hand(access, for: urls, to: model)
                case .unsupported:
                    model = nil
                    for lease in access { lease.close() }
                    warn(window)
                case .empty, .single:
                    model = nil
                    for lease in access { lease.close() }
                }
                if printing { model?.requestPrintMode() }
                finishOpening(model != nil)
            }
        }
        return true
    }

    /// A file that exists only in memory, as one made by an earlier action of a shortcut. It opens as a document
    /// in memory under its own file name, which tells what the name of a file on disk would (a source file's
    /// language). Text from the clipboard has no such name and goes through `open(_:printing:title:)`.
    @discardableResult
    func open(memoryFile data: Data, format: DocumentFormat, fileName: String, printing: Bool) -> Bool {
        if let openMemoryFile {
            openMemoryFile(data, format, fileName, printing)
        } else {
            openMemory(data, format, fileName, printing)
        }
        return true
    }

    /// What a service hands over: files take the way of any other file, and text and images open from memory, as the
    /// clipboard's do, under `title` when what they came from has a name. Text takes the clipboard's way to its
    /// format, which may ask the reader first.
    @discardableResult
    func open(_ content: ClipboardContent, printing: Bool, title: String? = nil) -> Bool {
        switch content {
        case .files(let urls): return open(urls, printing: printing)
        case .document(let data, let format):
            openMemory(data, format, title, printing)
            return true
        case .text(let text, let hints):
            openText(text, hints, title, printing)
            return true
        case .empty: return false
        }
    }

    /// A parent file's binder, in the order the parent names its documents.
    func open(includes plan: MarkdownIncludes.Plan) {
        openIncludes(plan)
    }

    func openRecent(_ url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        let leases =
            started ? [FolderAccess.Lease(url: url, release: { url.stopAccessingSecurityScopedResource() })] : []
        open([url], access: leases)
    }

    /// A binder the reader closed, from the Recent Binders menu. The reader made these files a binder, so it stays one
    /// even when they are all images, which `OpenRequest` would open as an image bundle. A file that is gone opens
    /// anyway and shows as unreadable in the list.
    func open(recentBinder binder: RecentBinder) {
        let located = recentFiles.locate(binder)
        if located.binder != binder { replaceRecentBinder(binder, located.binder) }
        located.keep(until: openBinder(BinderFiles(urls: located.urls), [])?.window)
    }

    /// Opens a document again where it was when a binder took its place.
    func reopen(_ url: URL, restoring origin: BinderOrigin, completion: @escaping (Bool) -> Void) {
        openSingle(
            SingleFileRequest(
                url: url, printing: origin.wasPrinting && !origin.leavingBinder, access: [], origin: origin),
            completion: completion)
    }

    /// Whether one file would be turned away without a window: a video under `.ts`, a text too large to lay out.
    func refusesSingle(_ url: URL) async -> Bool {
        switch await firstRoute(for: url) {
        case .refuse, .tooLarge: true
        case .document, .asText: false
        }
    }

    /// One file, by the way its beginning calls for. A video under `.ts` is turned away here, before the document
    /// controller would load all of it to find out.
    private func openSingle(_ request: SingleFileRequest, completion: @escaping (Bool) -> Void = { _ in }) {
        pendingOpens += 1
        enqueueOpening { [self] in
            let url = request.url
            let finish: (OpenedFile?) -> Void = { [self] result in
                request.deliver(result)
                finishOpening(result != nil)
                completion(result != nil)
            }
            switch await firstRoute(for: url) {
            case .document: openDocument(url, finish)
            case .asText: finish(await openAsText(url))
            case .refuse:
                refuse(SourceFileError.notText)
                finish(nil)
            case .tooLarge(let bytes):
                refuse(DocumentRenderer.RenderingError.tooLarge(bytes: bytes))
                finish(nil)
            }
        }
    }

    private func firstRoute(for url: URL) async -> SourceFileOpening.Route {
        let route = route
        return await Task.detached(priority: .userInitiated) { route(url) }.value
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

    /// The guide that comes with the app opens as any single file does, so a second request brings its window
    /// forward. The recent files leave it out (`RecentFileHistory`).
    @discardableResult
    func openGettingStarted() -> Bool {
        guard let url = gettingStartedURL() else { return false }
        return open([url])
    }

    @discardableResult
    func openSampleDocument() -> Bool {
        guard let url = GettingStarted.sampleURL(), let data = try? Data(contentsOf: url) else { return false }
        openMemory(data, .markdown, url.deletingPathExtension().lastPathComponent, false)
        return true
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
        // A document that fails to open, for example at launch, must not leave the app without any window.
        if !opened { showWelcomeIfIdle() }
    }
}

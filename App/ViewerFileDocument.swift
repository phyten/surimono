import AppKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import UniformTypeIdentifiers
import os

@objc(SurimonoViewerDocumentController)
final class ViewerDocumentController: NSDocumentController {
    override var allowsAutomaticShareMenu: Bool { false }
    nonisolated override var documentClassNames: [String] { [NSStringFromClass(ViewerFileDocument.self)] }
    nonisolated override func documentClass(forType typeName: String) -> AnyClass? {
        guard let type = UTType(typeName), SourceFileOpening.reads(type) else { return nil }
        return ViewerFileDocument.self
    }

    // Reopening restored documents also asks for their type. Extensionless scripts must take the same
    // content gate as the Open panel, before NSDocumentController tries to interpret their generic UTI.
    override func typeForContents(of url: URL) throws -> String {
        switch SourceFileOpening.route(for: url) {
        case .asText: return UTType.plainText.identifier
        case .refuse: throw SourceFileError.notText
        case .tooLarge(let bytes): throw DocumentRenderer.RenderingError.tooLarge(bytes: bytes)
        case .document: return try super.typeForContents(of: url)
        }
    }

    override func openDocument(_ sender: Any?) { OpenRouter.shared.showOpenPanel() }

    override func noteNewRecentDocumentURL(_ url: URL) {
        guard !GettingStarted.isInsideApp(url) else { return }
        super.noteNewRecentDocumentURL(url)
        RecentFileHistory.shared?.record(url)
        NotificationCenter.default.post(name: RecentFileHistory.systemListChanged, object: self)
    }

    override func clearRecentDocuments(_ sender: Any?) {
        super.clearRecentDocuments(sender)
        RecentFileHistory.shared?.clear()
        NotificationCenter.default.post(name: RecentFileHistory.systemListChanged, object: self)
    }
}

@objc(SurimonoViewerFileDocument)
final class ViewerFileDocument: NSDocument {
    private static let windowPrefix = "surimono.file.v1."
    static func recognizes(window identifier: NSUserInterfaceItemIdentifier) -> Bool {
        identifier.rawValue.hasPrefix(windowPrefix)
    }

    // Reading may run off the main thread. Keep exactly the access obtained from the original URL
    // for the lifetime of the file watcher and release it even if initialization throws.
    private nonisolated final class Access: Sendable {
        let url: URL
        init?(_ url: URL) {
            guard url.startAccessingSecurityScopedResource() else { return nil }
            self.url = url
        }
        deinit { url.stopAccessingSecurityScopedResource() }
    }
    private let contents = OSAllocatedUnfairLock(
        initialState: (input: Optional<SurimonoDocument>.none, access: Optional<Access>.none))
    nonisolated override class var readableTypes: [String] { SurimonoDocument.readableContentTypes.map(\.identifier) }
    nonisolated override class var writableTypes: [String] { [] }
    nonisolated override class var autosavesInPlace: Bool { false }
    nonisolated override class var autosavesDrafts: Bool { false }
    // Undoable reading and print settings never change the source.
    override var isDocumentEdited: Bool { false }
    override var hasUnautosavedChanges: Bool { false }
    nonisolated override var autosavingFileType: String? { nil }

    // Concurrent reading stays off: with it AppKit also creates the document on a background queue, and the
    // document's initializer and stored state belong to the main actor (it trapped in `init()` when enabled).
    // The read itself is bounded by `SourceFileOpening.read`.

    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        let access = Access(url)
        let type = UTType(typeName) ?? .plainText
        let format = DocumentFormat(contentType: type) ?? .plainText
        let data = try SourceFileOpening.read(url, format: format)
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = url.lastPathComponent
        let input = try SurimonoDocument(file: file, contentType: type)
        contents.withLock { state in
            state.input = input
            if let access { state.access = access } else if state.access?.url != url { state.access = nil }
        }
    }

    nonisolated override func write(to url: URL, ofType typeName: String) throws {
        throw CocoaError(.fileWriteNoPermission)
    }

    nonisolated override func writeSafely(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }

    nonisolated override func data(ofType typeName: String) throws -> Data { throw CocoaError(.fileWriteNoPermission) }
    override func move(to url: URL, completionHandler: ((Error?) -> Void)? = nil) {
        completionHandler?(CocoaError(.fileWriteNoPermission))
    }

    override func lock(completionHandler: ((Error?) -> Void)? = nil) {
        completionHandler?(CocoaError(.fileWriteNoPermission))
    }

    override func unlock(completionHandler: ((Error?) -> Void)? = nil) {
        completionHandler?(CocoaError(.fileWriteNoPermission))
    }

    private var presentation: DocumentWindowContent?

    override func close() {
        presentation?.close()
        presentation = nil
        super.close()
        contents.withLock { $0 = (nil, nil) }
    }

    override func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
        completionHandler: @escaping @Sendable (NSWindow?, (any Error)?) -> Void
    ) {
        // NSDocumentController reopens the file first. Keep the archived identifier on its one
        // window before handing it back to AppKit, which restores frame, order and miniaturization.
        if windowControllers.isEmpty { makeWindowControllers() }
        windowControllers.first?.window?.identifier = identifier
        super.restoreWindow(withIdentifier: identifier, state: state, completionHandler: completionHandler)
    }

    override func makeWindowControllers() {
        guard windowControllers.isEmpty, let environment = AppKitShell.current?.environment,
            let input = contents.withLock({ state in
                defer { state.input = nil }
                return state.input
            })
        else { return }
        let model = DocumentViewer.makeModel(
            document: input, fileURL: fileURL, preferences: environment.preferences,
            library: environment.library, settingsStore: environment.settingsStore)
        let window = FileWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.model = model
        ViewerWindow.configure(window)
        presentation = DocumentWindowContent(model: model, in: window, usesSnapshotAppearance: true) {
            [weak window, weak model] _ in
            // AppKit can still encode the window during termination after the model has gone.
            window?.lastReadingPage = model?.pageForWindowRestoration
        }
        window.representedURL = fileURL
        window.title = displayName
        window.center()
        let controller = NSWindowController(window: window)
        controller.shouldCloseDocument = true
        addWindowController(controller)
        window.identifier = .init(Self.windowPrefix + UUID().uuidString)
        window.isRestorable = true
    }
}

// NSDocumentController restores the URL and AppKit restores the window frame. The reading page
// belongs to this open window (closing it and explicitly reopening the file still starts at page one).
private final class FileWindow: NSWindow {
    weak var model: DocumentViewModel?
    var lastReadingPage: Int?
    private static let pageKey = "SurimonoReadingPage"

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        if let page = model?.pageForWindowRestoration ?? lastReadingPage { coder.encode(page, forKey: Self.pageKey) }
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        if coder.containsValue(forKey: Self.pageKey) {
            model?.restoreReadingPage(coder.decodeInteger(forKey: Self.pageKey))
        }
    }
}

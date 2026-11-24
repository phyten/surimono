import AppKit
import SurimonoCore
import SwiftUI
import UniformTypeIdentifiers
import os

final class AppKitShell: NSObject {
    static let requested: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        return zip(arguments, arguments.dropFirst()).contains {
            $0 == "-SurimonoAppKitShell" && $1.uppercased() == "YES"
        }
    }()
    private(set) static var current: AppKitShell?
    let environment = ViewerEnvironment()
    private let delegate = AppDelegate()
    private lazy var menu = ViewerMainMenu(shell: self)
    private var settings: NSWindowController?

    static func run() {
        // AppKit uses the first document controller created as its shared controller.
        let documents = ViewerDocumentController()
        precondition(NSDocumentController.shared === documents)
        let application = ViewerApplication.shared
        let shell = AppKitShell()
        current = shell
        application.delegate = shell.delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(documents) {}
    }

    var menuTrackingDepth: Int { menu.trackingDepth }

    func installMenu() { menu.install() }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil {
            let host = NSHostingController(rootView: environment.settingsView)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = String(localized: "Settings…").trimmingCharacters(in: CharacterSet(charactersIn: "…"))
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 820, height: 540))
            window.center()
            settings = NSWindowController(window: window)
        }
        settings?.showWindow(sender)
        settings?.window?.makeKeyAndOrderFront(sender)
    }
}

private final class ViewerDocumentController: NSDocumentController {
    override var allowsAutomaticShareMenu: Bool { false }
    override var documentClassNames: [String] { [NSStringFromClass(ViewerFileDocument.self)] }
    override func documentClass(forType typeName: String) -> AnyClass? {
        guard let type = UTType(typeName), SourceFileOpening.reads(type) else { return nil }
        return ViewerFileDocument.self
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
    private let contents = OSAllocatedUnfairLock(initialState: Optional<SurimonoDocument>.none)
    override class var readableTypes: [String] { SurimonoDocument.readableContentTypes.map(\.identifier) }
    override class var writableTypes: [String] { [] }
    nonisolated override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    nonisolated override var autosavingFileType: String? { nil }

    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        let type = UTType(typeName) ?? .plainText
        let format = DocumentFormat(contentType: type) ?? .plainText
        let data = try SourceFileOpening.read(url, format: format)
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = url.lastPathComponent
        let input = try SurimonoDocument(file: file, contentType: type)
        contents.withLock { $0 = input }
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

    override func makeWindowControllers() {
        guard let environment = AppKitShell.current?.environment, let input = contents.withLock({ $0 }) else { return }
        let viewer = DocumentViewer(
            document: input, fileURL: fileURL, preferences: environment.preferences,
            library: environment.library, settingsStore: environment.settingsStore)
        #if DEBUG
            let host = NSHostingController(rootView: viewer.snapshotControlAppearance())
        #else
            let host = NSHostingController(rootView: viewer)
        #endif
        host.sizingOptions = []
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        ViewerWindow.configure(window)
        window.contentViewController = host
        window.representedURL = fileURL
        window.title = displayName
        window.center()
        let controller = NSWindowController(window: window)
        controller.shouldCloseDocument = true
        addWindowController(controller)
    }
}

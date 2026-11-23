import AppKit
import SurimonoCore
import SurimonoRendering
import UniformTypeIdentifiers

enum SourceFileError: LocalizedError, Equatable {
    /// A video under `.ts` or a binary property list: the extension of a text file on a file that is not text.
    case notText

    var errorDescription: String? { String(localized: "This is not a text file, so it cannot be displayed.") }
}

/// How one file is opened and read. `TextFileGate` reads the beginning of the files whose name does not settle what
/// they are, before anything loads their contents.
enum SourceFileOpening {
    nonisolated enum Route: Equatable, Sendable {
        /// The document controller opens it by its own type, as it opens any other file.
        case document
        /// Text that macOS gives no type the app reads (`Dockerfile`, `.env`, a script named only by its `#!`
        /// line): read as plain text. Declaring `public.data` for these would offer this app for every file.
        case asText
        /// Not text under a text file's name. Its contents are never loaded.
        case refuse
        /// Text of this many bytes, more than is laid out as pages. It is told before the framework reads it.
        case tooLarge(Int)
    }

    nonisolated static func route(for url: URL) -> Route {
        let inspection = TextFileGate.inspection(of: url)
        switch inspection.verdict {
        case .decided(.binary), .refused: return .refuse
        case .decided(.text):
            if let size = inspection.size, size > PageLayoutLimits.plainTextBytes { return .tooLarge(size) }
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            return type.map(reads) == true ? .document : .asText
        // A file that is missing or may not be read yet is the document controller's to report or to be given.
        case .decided(.notConcerned), .missing, .undecided: return .document
        }
    }

    /// Whether a file of this type opens through the document types the app declares.
    nonisolated static func reads(_ type: UTType) -> Bool {
        SurimonoDocument.readableContentTypes.contains { type.conforms(to: $0) }
    }

    /// The contents of a file a window or a binder shows, read again after the first time. A file of a kind the
    /// gate looks at is checked and read through one descriptor, so a video put in a `.ts` file's place is turned
    /// away before it is loaded, and what was checked is what is read. With `root`, the file must lie under it.
    nonisolated static func read(_ url: URL, format: DocumentFormat, within root: String? = nil) throws -> Data {
        if format == .plainText {
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            if TextFileGate.concerns(fileName: url.lastPathComponent, type: type) {
                return try readText(url, within: root)
            }
        }
        if let root { return try ConfinedFile.read(url, within: root) }
        return try ConfinedFile.read(url)
    }

    nonisolated static func readText(_ url: URL, within root: String? = nil) throws -> Data {
        do {
            return try TextFileGate.read(url, within: root, maximumSize: PageLayoutLimits.plainTextBytes)
        } catch is TextFileGate.Refusal {
            throw SourceFileError.notText
        }
    }

    /// Whether bytes read for a plain text document must not be shown: the gate's answer for the file's own name
    /// and type. A document in another format (an image with no extension) is not the gate's to judge.
    nonisolated static func refuses(_ data: Data, at url: URL, format: DocumentFormat) -> Bool {
        guard format == .plainText else { return false }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return TextFileGate.refuses(fileName: url.lastPathComponent, type: type, data: data)
    }

    /// Keep a real file document for recents, access and reload. Its window takes the bytes already checked by
    /// the worker; asking the document controller to open the URL here would read it a second time.
    @MainActor
    static func document(
        for url: URL, read: @escaping @Sendable (URL) throws -> Data = { try readText($0) },
        window: (URL, Data) -> NSWindowController
    ) async throws -> (document: NSDocument, isNew: Bool) {
        let controller = NSDocumentController.shared
        if let open = controller.document(for: url) { return (open, false) }
        let result = await Task.detached(priority: .userInitiated) {
            let bytes = try read(url)
            // The forced plain-text type does not describe the file itself. Recheck its name and actual bytes.
            guard !TextFileGate.refuses(fileName: url.lastPathComponent, data: bytes) else {
                throw SourceFileError.notText
            }
            return bytes
        }.result
        if let open = controller.document(for: url) { return (open, false) }
        let data = try result.get()
        let document = ReadOnlyTextDocument()
        document.fileType = UTType.plainText.identifier
        document.fileURL = url
        let viewer = window(url, data)
        viewer.shouldCloseDocument = true
        document.addWindowController(viewer)
        return (document, true)
    }

    @MainActor
    static func open(_ url: URL, window: (URL, Data) -> NSWindowController) async throws {
        let (document, isNew) = try await document(for: url, window: window)
        if isNew {
            NSDocumentController.shared.addDocument(document)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            // These windows are made by hand, not by the document group, so they cascade on their own like the
            // other windows the app makes; otherwise each one opens exactly over the last.
            if let window = document.windowControllers.first?.window {
                cascadePoint = window.cascadeTopLeft(from: cascadePoint)
            }
        }
        document.showWindows()
    }

    @MainActor private static var cascadePoint = NSPoint.zero

    private final class ReadOnlyTextDocument: NSDocument {
        nonisolated override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [] }

        nonisolated override func data(ofType typeName: String) throws -> Data {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}

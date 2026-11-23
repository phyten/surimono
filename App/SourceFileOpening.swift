import AppKit
import SurimonoCore
import SurimonoRendering
import UniformTypeIdentifiers

enum SourceFileError: LocalizedError, Equatable {
    /// A video under `.ts` or a binary property list: the extension of a text file on a file that is not text.
    case notText

    var errorDescription: String? { String(localized: "This file is not text, so Surimono cannot show it.") }
}

/// How one file is opened and read. `TextFileGate` reads the beginning of the files whose name does not settle what
/// they are, before anything loads their contents.
enum SourceFileOpening {
    enum Route: Equatable {
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
    nonisolated static func read(_ url: URL, within root: String? = nil) throws -> Data {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard TextFileGate.concerns(fileName: url.lastPathComponent, type: type) else {
            return try root.map { try ConfinedFile.read(url, within: $0) } ?? Data(contentsOf: url)
        }
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

    /// The document for `url` read as plain text, not yet shown; the one already open for it if there is one.
    @MainActor
    static func document(for url: URL) throws -> (document: NSDocument, isNew: Bool) {
        let controller = NSDocumentController.shared
        if let open = controller.document(for: url) { return (open, false) }
        return (try controller.makeDocument(withContentsOf: url, ofType: UTType.plainText.identifier), true)
    }

    @MainActor
    static func open(_ url: URL) throws {
        let (document, isNew) = try document(for: url)
        if isNew {
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        document.showWindows()
    }
}

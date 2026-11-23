import AppKit
import SurimonoCore
import UniformTypeIdentifiers

enum SourceFileError: LocalizedError, Equatable {
    /// A video under `.ts` or a binary property list: the extension of a text file on a file that is not text.
    case notText

    var errorDescription: String? { String(localized: "This file is not text, so Surimono cannot show it.") }
}

/// How one file is opened. `TextFileGate` reads the beginning of the files whose name does not settle what they
/// are, before anything loads their contents.
enum SourceFileOpening {
    enum Route: Equatable {
        /// The document controller opens it by its own type, as it opens any other file.
        case document
        /// Text that macOS gives no type the app reads (`Dockerfile`, `.env`, a script named only by its `#!`
        /// line): read as plain text. Declaring `public.data` for these would offer this app for every file.
        case asText
        /// Not text under a text file's name. Its contents are never loaded.
        case refuse
    }

    nonisolated static func route(for url: URL) -> Route {
        switch TextFileGate.decide(url) {
        case .refused: return .refuse
        case .unrelated: return .document
        case .text:
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            return type.map(reads) == true ? .document : .asText
        }
    }

    /// Whether a file of this type opens through the document types the app declares.
    nonisolated static func reads(_ type: UTType) -> Bool {
        SurimonoDocument.readableContentTypes.contains { type.conforms(to: $0) }
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

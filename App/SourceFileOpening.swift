import AppKit
import SurimonoCore
import SurimonoRendering
import UniformTypeIdentifiers

enum SourceFileError: LocalizedError, Equatable {
    /// A video under `.ts` or a binary property list: the extension of a text file on a file that is not text.
    case notText

    var errorDescription: String? { String(localized: "This file is not text, so Surimono cannot show it.") }
}

/// Opens the source files macOS has no type for because they have no extension: `Dockerfile`, `Gemfile`, `.env`, a
/// script that only its `#!` line names. Declaring `public.data` for them would offer this app for every file on the
/// Mac, so they are read as plain text only when their name or first line tells a language.
enum SourceFileOpening {
    /// Whether `url` should be read as plain text although its own type is none the app reads.
    nonisolated static func readsAsPlainText(_ url: URL) -> Bool {
        guard url.isFileURL,
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, let type = values.contentType, isUntyped(type),
            let size = values.fileSize, size <= PageLayoutLimits.plainTextBytes,
            let data = try? Data(contentsOf: url)
        else { return false }
        return DocumentRenderer.sourceLanguage(of: DocumentSource(data: data, fileURL: url, format: .plainText)) != nil
    }

    /// A type that says nothing about the content. A file with a type of its own (a video, an archive) is never
    /// read as text, whatever its name.
    nonisolated static func isUntyped(_ type: UTType) -> Bool {
        type == .data || type == .unixExecutable || type.identifier.hasPrefix("dyn.")
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

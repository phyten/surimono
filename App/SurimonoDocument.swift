import Foundation
import SurimonoCore
import SwiftUI
import UniformTypeIdentifiers

struct SurimonoDocument: FileDocument {
    nonisolated static var readableContentTypes: [UTType] {
        [
            .surimonoMarkdown, .surimonoOrg, .surimonoLaTeX, .surimonoNotebook, .plainText, .html, .pdf, .image,
            .commaSeparatedText,
            .tabSeparatedText, .zip,
        ]
    }

    nonisolated static var writableContentTypes: [UTType] { [] }

    let data: Data
    let contentType: UTType

    nonisolated var format: DocumentFormat? {
        DocumentFormat(contentType: contentType)
    }

    nonisolated init(configuration: ReadConfiguration) throws {
        try self.init(file: configuration.file, contentType: configuration.contentType)
    }

    nonisolated init(file: FileWrapper, contentType: UTType) throws {
        // regularFileContents raises an Objective-C exception for directory wrappers, so check the kind first.
        guard file.isRegularFile, let data = file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
        // Some systems have only the JSON association installed; use the file name without claiming all JSON.
        let suffix = ((file.preferredFilename ?? file.filename ?? "") as NSString).pathExtension
        self.contentType = DocumentFormat(fileExtension: suffix) == .notebook ? .surimonoNotebook : contentType
    }

    nonisolated func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // A viewer must reject writes even if a caller bypasses DocumentGroup(viewing:).
        throw CocoaError(.fileWriteNoPermission)
    }
}

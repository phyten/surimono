import Foundation
import SurimonoCore
import SwiftUI
import UniformTypeIdentifiers

struct SurimonoDocument: FileDocument {
    nonisolated static var readableContentTypes: [UTType] {
        [
            .surimonoMarkdown, .surimonoOrg, .surimonoAsciiDoc, .surimonoQuarto, .surimonoRMarkdown, .surimonoDjot,
            .surimonoTextile, .surimonoMediaWiki, .surimonoRST, .surimonoLaTeX,
            .surimonoNotebook, .surimonoGraphviz,
            .surimonoPlantUML,
            .plainText, .sourceCode, .surimonoSourceCode, .propertyList, .mpeg2TransportStream,
            .json, .yaml, .xml, .surimonoJSONLines, .surimonoTOML, .html, .pdf, .image,
            .commaSeparatedText,
            .tabSeparatedText, .zip,
        ]
            + ["com.apple.log", "public.ndjson", "public.toml", "public.css", "com.microsoft.ini"].compactMap {
                UTType($0)
            } + wordTemplate
            + [UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 }
    }

    /// macOS gives the `.dot` extension to Word templates, so a Graphviz file arrives with that type. The initializer
    /// goes by the file name and reads it as Graphviz.
    nonisolated private static var wordTemplate: [UTType] {
        UTType("com.microsoft.word.dot").map { [$0] } ?? []
    }

    nonisolated static var writableContentTypes: [UTType] { [] }

    let data: Data
    let contentType: UTType
    /// The gate looked at the bytes and found text. The document is then plain text, whatever its name says.
    let isGatedText: Bool

    nonisolated var format: DocumentFormat? {
        DocumentFormat(contentType: contentType)
    }

    /// The format the window shows the document in. The file's extension corrects what the type says (the system
    /// knows some extensions under another type), but only where the gate had nothing to say: text it found under
    /// a video's type stays plain text even when its name ends in `.md`.
    nonisolated func format(at fileURL: URL?) -> DocumentFormat {
        if isGatedText { return .plainText }
        if format == .html, fileURL?.pathExtension.lowercased() == "xml" { return .html }
        return fileURL.flatMap { DocumentFormat(fileExtension: $0.pathExtension) } ?? format ?? .plainText
    }

    nonisolated init(configuration: ReadConfiguration) throws {
        try self.init(file: configuration.file, contentType: configuration.contentType)
    }

    nonisolated init(file: FileWrapper, contentType: UTType) throws {
        // regularFileContents raises an Objective-C exception for directory wrappers, so check the kind first.
        guard file.isRegularFile, let data = file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // The router turns a video under `.ts` away before its contents are loaded. This entry obtains the whole
        // content before deciding, so for the Recent menu and a restored window, which do not pass the router,
        // this check on the bytes that would be shown is all there is. It is also what holds when a file changes
        // between the router's look and this read.
        //
        // Plain text is the type the router asks for when it opens a file with no type of its own (`Dockerfile`)
        // as text. It says nothing about the file, and taking it for the file's own would end the look here.
        let name = file.preferredFilename ?? file.filename ?? ""
        let decision = TextFileGate.verdict(
            fileName: name, type: contentType == .plainText ? nil : contentType, data: data)
        guard decision != .binary else { throw SourceFileError.notText }
        if case .text = decision { isGatedText = true } else { isGatedText = false }
        self.data = data
        // Some systems have only the JSON association installed; the file name distinguishes notebooks from ordinary JSON.
        let suffix = ((file.preferredFilename ?? file.filename ?? "") as NSString).pathExtension
        // Text that came under a video's type, or under none, is plain text from here on.
        if isGatedText {
            self.contentType = .plainText
            return
        }
        self.contentType =
            switch DocumentFormat(fileExtension: suffix) {
            case .quarto: .surimonoQuarto
            case .rMarkdown: .surimonoRMarkdown
            case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? contentType
            case .djot: .surimonoDjot
            case .textile: .surimonoTextile
            case .mediawiki: .surimonoMediaWiki
            case .rst: .surimonoRST
            case .asciidoc: .surimonoAsciiDoc
            case .notebook: .surimonoNotebook
            case .plainText where DocumentFormat(contentType: contentType) == nil: .plainText
            case .graphviz: .surimonoGraphviz
            case .plantuml: .surimonoPlantUML
            default: contentType
            }
    }

    nonisolated func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // A viewer must reject writes even if a caller bypasses DocumentGroup(viewing:).
        throw CocoaError(.fileWriteNoPermission)
    }
}

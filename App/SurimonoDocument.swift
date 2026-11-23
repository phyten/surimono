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
        // The router turns a video under `.ts` away before its contents are loaded. This is the second check, on
        // the bytes that would be shown, for the ways that do not pass the router (the Recent menu, a restored
        // window). A video under another extension is held to the same test as a `.ts`.
        let name = file.preferredFilename ?? file.filename ?? ""
        let gated = contentType.conforms(to: .mpeg2TransportStream) ? "video.ts" : name
        let decision = TextFileGate.decide(fileName: gated, head: data.prefix(TextFileGate.headLength))
        guard decision != .refused else { throw SourceFileError.notText }
        self.data = data
        // Some systems have only the JSON association installed; the file name distinguishes notebooks from ordinary JSON.
        let suffix = ((file.preferredFilename ?? file.filename ?? "") as NSString).pathExtension
        // Text that came under a video's type, or under none, is plain text from here on.
        if case .text = decision {
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

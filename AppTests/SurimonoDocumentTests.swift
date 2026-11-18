import Foundation
import SurimonoCore
import Testing
import UniformTypeIdentifiers

@testable import Surimono

struct SurimonoDocumentTests {
    @Test("図の拡張子で汎用テキスト型を補い原文を保持する", arguments: ["dot", "gv", "puml", "plantuml", "pu", "iuml", "wsd"])
    func diagramFiles(suffix: String) throws {
        let bytes = Data("図の原文".utf8)
        let file = FileWrapper(regularFileWithContents: bytes)
        file.preferredFilename = "sample." + suffix
        let document = try SurimonoDocument(file: file, contentType: .plainText)
        #expect(document.format == (["dot", "gv"].contains(suffix) ? .graphviz : .plantuml))
        #expect(document.data == bytes)
    }

    @Test("Wordテンプレートの型で届いたdotをGraphvizとして開く")
    func dotAsWordTemplate() throws {
        // macOS declares `.dot` as a Word template; machines without that declaration have nothing to check.
        guard let word = UTType("com.microsoft.word.dot") else { return }
        #expect(SurimonoDocument.readableContentTypes.contains(word))
        let file = FileWrapper(regularFileWithContents: Data("digraph { a -> b }".utf8))
        file.preferredFilename = "sample.dot"
        #expect(try SurimonoDocument(file: file, contentType: word).format == .graphviz)
        let types = try #require(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(types.contains { ($0["LSItemContentTypes"] as? [String])?.contains("com.microsoft.word.dot") == true })
    }

    @Test("DjotとTextileは拡張子を登録して原文を保持する", arguments: ["dj", "djot", "textile"])
    func opensPrintMarkup(suffix: String) throws {
        let expected: UTType = suffix == "textile" ? .surimonoTextile : .surimonoDjot
        let declared = try #require(UTType(filenameExtension: suffix))
        #expect(declared == expected)
        #expect(declared.conforms(to: .plainText))
        let bytes = Data("紙".utf8)
        let file = FileWrapper(regularFileWithContents: bytes)
        file.preferredFilename = "sample." + suffix
        let document = try SurimonoDocument(file: file, contentType: .plainText)
        #expect(document.contentType == expected)
        #expect(document.data == bytes)
    }

    @Test("QuartoとR Markdownは拡張子を登録して原文を保持する", arguments: ["qmd", "Rmd", "rmarkdown"])
    func opensComputationalMarkdown(suffix: String) throws {
        let expected: UTType = suffix == "qmd" ? .surimonoQuarto : .surimonoRMarkdown
        let declared = try #require(UTType(filenameExtension: suffix))
        #expect(declared == expected)
        #expect(declared.conforms(to: .plainText))
        let bytes = Data("紙".utf8)
        let file = FileWrapper(regularFileWithContents: bytes)
        file.preferredFilename = "sample." + suffix
        let document = try SurimonoDocument(file: file, contentType: .plainText)
        #expect(document.contentType == expected)
        #expect(document.data == bytes)
    }

    @Test("AsciiDocの拡張子と宣言型を照合し元のバイト列を保持する", arguments: ["adoc", "asciidoc"])
    func asciiDocFiles(suffix: String) throws {
        let type = try #require(UTType(filenameExtension: suffix))
        let bytes = Data("= Paper".utf8)
        let file = FileWrapper(regularFileWithContents: bytes)
        file.preferredFilename = "example." + suffix
        let document = try SurimonoDocument(file: file, contentType: type)
        #expect(document.format == .asciidoc)
        #expect(document.data == bytes)
        #expect(type.conforms(to: .plainText))
        #expect(SurimonoDocument.readableContentTypes.contains(.surimonoAsciiDoc))
        let imported = try #require(Bundle.main.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try #require(imported.first { $0["UTTypeIdentifier"] as? String == "org.asciidoc.asciidoc" })
        #expect(declaration["UTTypeConformsTo"] as? [String] == ["public.plain-text"])
        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == ["adoc", "asciidoc"])
    }

    @Test("JSONの型で渡されたipynbだけをNotebookとして開く")
    func notebookJSON() throws {
        let file = FileWrapper(regularFileWithContents: Data(#"{"nbformat":4,"cells":[]}"#.utf8))
        file.preferredFilename = "sample.ipynb"
        let notebook = try SurimonoDocument(file: file, contentType: .json)
        #expect(notebook.format == .notebook)
        file.preferredFilename = "sample.json"
        #expect(try SurimonoDocument(file: file, contentType: .json).format != .notebook)
        #expect(SurimonoDocument.readableContentTypes.contains(.surimonoNotebook))
    }

    @Test("Notebookの取り込み型はJSONに準拠し拡張子を宣言する")
    func notebookRegistration() throws {
        let imported = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]])
        let notebook = try #require(imported.first { $0["UTTypeIdentifier"] as? String == "org.jupyter.ipynb" })
        #expect(notebook["UTTypeConformsTo"] as? [String] == ["public.json"])
        let tags = try #require(notebook["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == ["ipynb"])
    }

    @Test("読み込んだ文書のバイト列と形式を保持する")
    func preservesDocumentData() throws {
        let data = Data("# 摺物\n".utf8)
        let document = try SurimonoDocument(
            file: FileWrapper(regularFileWithContents: data), contentType: .surimonoMarkdown)
        #expect(document.data == data)
        #expect(document.contentType == .surimonoMarkdown)
        #expect(document.format == .markdown)
    }

    @Test("TSV を読み取り可能な形式として受け付け、表として描画する形式になる")
    func acceptsTabSeparatedValues() throws {
        #expect(SurimonoDocument.readableContentTypes.contains(.tabSeparatedText))
        let document = try SurimonoDocument(
            file: FileWrapper(regularFileWithContents: Data("a\tb\n1\t2\n".utf8)), contentType: .tabSeparatedText)
        #expect(document.format == .csv)
    }

    @Test("ディレクトリを文書として読み込まない")
    func rejectsDirectory() {
        #expect(throws: CocoaError.self) {
            try SurimonoDocument(file: FileWrapper(directoryWithFileWrappers: [:]), contentType: .plainText)
        }
    }

    @Test("保存可能な形式を公開しない")
    func supportsViewingOnly() {
        #expect(SurimonoDocument.writableContentTypes.isEmpty)
    }

    @Test("Info plist の文書形式とコードの読み取り形式が一致する")
    func matchesDocumentRegistration() throws {
        let declarations = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let identifiers = declarations.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        #expect(Set(identifiers) == Set(SurimonoDocument.readableContentTypes.map(\.identifier)))
        #expect(declarations.allSatisfy { $0["CFBundleTypeRole"] as? String == "Viewer" })
        #expect(declarations.allSatisfy { $0["LSHandlerRank"] as? String == "Alternate" })
        let imported = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]])
        #expect(
            Set(imported.compactMap { $0["UTTypeIdentifier"] as? String })
                == Set([
                    UTType.surimonoMarkdown.identifier, UTType.surimonoOrg.identifier,
                    UTType.surimonoQuarto.identifier, UTType.surimonoRMarkdown.identifier,
                    UTType.surimonoDjot.identifier, UTType.surimonoTextile.identifier,
                    UTType.surimonoAsciiDoc.identifier, UTType.surimonoLaTeX.identifier,
                    UTType.surimonoNotebook.identifier,
                    UTType.surimonoGraphviz.identifier, UTType.surimonoPlantUML.identifier,
                ]))
    }
}

import Foundation
import SurimonoCore
import Testing
import UniformTypeIdentifiers

@testable import Surimono

struct SurimonoDocumentTests {
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
                    UTType.surimonoLaTeX.identifier, UTType.surimonoNotebook.identifier,
                ]))
    }
}

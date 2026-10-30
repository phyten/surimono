import Foundation
import SurimonoCore
import Testing
import UniformTypeIdentifiers

@testable import Surimono

struct SurimonoDocumentTests {
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
                    UTType.surimonoLaTeX.identifier,
                ]))
    }
}

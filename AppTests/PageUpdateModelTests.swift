import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct PageUpdateModelTests {
    @Test("組み方・スタイル・文字サイズ・原稿の更新を論理ページの公開まで追跡し、失敗で止める", .timeLimit(.minutes(1)))
    func publishedPages() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = #"\documentclass{article}\begin{document}Text.\end{document}"#
        let page = TestFixtures.pdf("Text.", pages: 1)
        let model = DocumentViewModel(
            data: Data(source.utf8), fileURL: nil, format: .latex,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: DocumentRenderer(paginate: { request in
                if case .html(let html, _) = request.source, html.contains("paginationFailure") {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return try #require(PDFDocument(data: page))
            }))
        defer { model.stop() }

        func settle() async throws {
            for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(10)) }
            try #require(!model.isRendering)
        }
        model.start()
        #expect(model.pageUpdateState == .inactive)
        try await settle()
        try #require(model.offersLaTeXComposition)
        for change in [
            { model.selectComposition(.proof) }, { model.selectTheme("standard") }, { model.increaseTextSize() },
            { model.reload() },
        ] {
            change()
            #expect(model.pageUpdateState == .behind)
            model.renderForChangedSettings()
            try await settle()
            #expect(model.pageUpdateState == .current)
        }
        model.replaceContent(Data("paginationFailure".utf8), format: .markdown)
        #expect(model.pageUpdateState == .behind)
        try await settle()
        #expect(model.error != nil)
        #expect(model.pageUpdateState == .inactive)
        #expect(model.pageUpdateDisplay == .hidden)
    }

    @Test("更新の表示と読み上げを全八言語に収録する")
    func localizations() throws {
        for language in ["ja", "en", "de", "fr", "es", "ko", "zh-Hans", "zh-Hant"] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in ["Updating pages", "Updating pages…", "Pages updated"] {
                #expect(bundle.localizedString(forKey: key, value: "MISSING", table: nil) != "MISSING")
            }
        }
    }
}

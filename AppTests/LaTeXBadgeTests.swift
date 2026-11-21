import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct LaTeXBadgeTests {
    @Test("学会・標準・代替の札と詳細は表示言語に従う")
    func badgeText() throws {
        let examples = [
            (#"\documentclass{article}\usepackage{neurips_2026}"#, "NeurIPS 2026（投稿用）", "NeurIPS 2026 (submission)"),
            (#"\documentclass{ipsj}"#, "情報処理学会", "IPSJ"),
            (#"\documentclass{article}"#, "article", "article"),
            (#"\documentclass{myjournal}"#, "標準で代替", "standard layout"),
        ]
        for (source, japanese, english) in examples {
            let recognition = try #require(LaTeXConverter.documentClassInfo(source + #"\begin{document}"#).recognition)
            #expect(LaTeXBadgeText(recognition, language: "ja").label == japanese)
            #expect(LaTeXBadgeText(recognition, language: "en").label == english)
        }
        let longClass = String(repeating: "x", count: 70) + "end"
        let text = LaTeXBadgeText(.substituted(requestedClass: longClass), language: "en")
        #expect(text.explanation.contains("…"))
        #expect(text.explanation.hasSuffix("end” is not supported, so the standard layout is used."))
    }

    @Test("変換した原稿の認識名を帯とメニューに表示し、一般のスタイルに替えると形式だけを表示する", .timeLimit(.minutes(1)))
    func modelBadge() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = #"\documentclass{article}\begin{document}Text.\end{document}"#
        let page = TestFixtures.pdf("Text.", pages: 1)
        let model = DocumentViewModel(
            data: Data(source.utf8), fileURL: nil, format: .latex,
            preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory),
            renderer: DocumentRenderer(paginate: { _ in try #require(PDFDocument(data: page)) }))
        defer { model.stop() }
        model.start()
        for _ in 0..<500 where model.result == nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.result != nil)
        #expect(model.formatBadge == "TEX · article")
        #expect(BandMenuContent(model: model).header.contains(" · TEX · article"))
        model.selectTheme("standard")
        #expect(model.formatBadge == "TEX")
        #expect(model.latexBadge == nil)
    }
}

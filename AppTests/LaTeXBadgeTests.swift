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

    @Test("スライドの札は指定テーマと該当する枚数だけを説明する")
    func beamerNotices() throws {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{beamer}\usetheme{Madrid}\begin{document}\frame{Net}\end{document}"#)
        var facts = DocumentFacts(fragment: fragment)
        let recognition = try #require(facts.latexRecognition)
        let badge = LaTeXBadgeText(recognition, language: "ja", facts: facts)
        #expect(badge.label == "beamer")
        #expect(badge.explanation == "原稿のテーマ『Madrid』には対応していないため、beamer の標準の体裁で表示しています。")
        #expect(badge.slideNotes.isEmpty)
        facts.continuedBeamerFrames = 2
        facts.unreadableBeamerFrames = 1
        let details = LaTeXBadgeText(recognition, language: "en", facts: facts)
        #expect(details.explanation == "The theme “Madrid” is not supported, so beamer's default look is used.")
        #expect(
            details.slideNotes == [
                "2 slides did not fit and continue on a following page.",
                "1 slide shows all its steps at once because its overlay commands could not be read.",
            ])
    }

    @Test("刷り台の今の一枚は読み取り中のスライドを指し、読むための設定には残らない", .timeLimit(.minutes(1)))
    func beamerCurrentSlide() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = #"""
            \documentclass{beamer}
            \begin{document}\section{Gauges}\frame{North gauge}\frame{South gauge}\end{document}
            """#
        let model = DocumentViewModel(
            data: Data(source.utf8), fileURL: nil, format: .latex,
            preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory))
        defer { model.stop() }
        model.start()
        for _ in 0..<500 where model.result == nil { try await Task.sleep(for: .milliseconds(20)) }
        let deck = try #require(model.slideDeck)
        #expect(deck.count == 2)
        #expect(model.formatBadge == "TEX · beamer")
        #expect(!model.offersLaTeXComposition)
        let size = try #require(model.paperUnitSize)
        #expect(abs(size.width / size.height - 4.0 / 3.0) < 0.001)
        #expect(model.outlineEntries.first?.title == "Gauges")
        #expect(model.outlineEntries.first?.pageIndex == 0)
        model.currentPageIndex = 1
        model.setPrintsCurrentSlideOnly(true)
        #expect(model.renderSettings(in: .print)?.slides?.onlyIndex == 1)
        #expect(model.renderSettings(in: .view)?.slides == nil)
        model.selectTheme("standard")
        #expect(model.formatBadge == "TEX · beamer")
        #expect(!model.offersLaTeXComposition)
    }

    @Test("幅を縮めると組み方、認識名、形式バッジの順に畳む")
    func collapse() {
        let widths: [BandLayout.Item: BandLayout.Widths] = [
            .formatBadge: .init(full: 140, compact: 27, withoutSuffix: 85)
        ]
        func form(_ available: CGFloat) -> BandLayout.Form? {
            BandLayout.plan(widths: widths, fixed: 0, separator: 0, name: 0, available: available).forms[.formatBadge]
        }
        #expect(form(140) == .full)
        #expect(form(85) == .withoutSuffix)
        #expect(form(27) == .compact)
        #expect(form(26) == nil)
    }

    @Test("組み方の項目と説明と短い札を全八言語に収録する")
    func localizedChoices() throws {
        let keys =
            ["LaTeX Layout"] + LaTeXComposition.allCases.flatMap { [$0.titleKey, $0.detailKey] }
            + LaTeXComposition.allCases.compactMap(\.suffixKey)
        for language in ["ja", "en", "de", "fr", "es", "ko", "zh-Hans", "zh-Hant"] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                #expect(bundle.localizedString(forKey: key, value: "MISSING", table: nil) != "MISSING")
            }
        }
        #expect(PrintModeText.string("LaTeX Layout", language: "ja") == "組み方")
        #expect(PrintModeText.string("LaTeX Layout", language: "en") == "Layout")
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
        #expect(model.offersLaTeXComposition)
        for choice in [LaTeXComposition.twoColumn, .proof] {
            model.selectComposition(choice)
            #expect(model.renderSettings?.latexComposition == choice)
            let suffix = try #require(choice.suffixKey)
            #expect(model.formatBadge == "TEX · article · " + PrintModeText.string(suffix, language: model.language))
            #expect(model.formatBadge(in: .withoutSuffix) == "TEX · article")
            #expect(model.formatBadge(in: .compact) == "TEX")
            let group = BandMenuContent(model: model).groups.flatMap(\.entries).filter { $0.id == .composition }
            #expect(group.count == 1)
            let rows = DocumentMenuDescriptor.rows(for: .view, in: .init(version: 1, content: .init(model: model)))
            let menus = rows.filter { $0.id == .menu("LaTeX Layout") }
            try #require(menus.count == 1)
            #expect(menus[0].children.map(\.id) == LaTeXComposition.allCases.map { .action(.composition($0)) })
            #expect(menus[0].children.filter { $0.checked == true }.map(\.id) == [.action(.composition(choice))])
        }
        model.selectTheme("standard")
        #expect(model.formatBadge == "TEX")
        #expect(!model.offersLaTeXComposition)
        #expect(model.renderSettings?.latexComposition == .document)
        model.selectComposition(.twoColumn)
        #expect(model.latexComposition == .proof)
        let rows = DocumentMenuDescriptor.rows(for: .view, in: .init(version: 2, content: .init(model: model)))
        #expect(!rows.contains { $0.id == .menu("LaTeX Layout") })
        #expect(model.latexBadge == nil)
    }
}

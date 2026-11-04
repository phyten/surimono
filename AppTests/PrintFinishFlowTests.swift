import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct PrintFinishFlowTests {
    @MainActor private struct Environment {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var preferences: AppPreferences { AppPreferences(defaults: suite.defaults) }
        var store: DocumentSettingsStore {
            DocumentSettingsStore(directory: directory.appendingPathComponent("Settings"))
        }

        func model(
            _ label: String = "本文", format: DocumentFormat = .markdown, preferences: AppPreferences? = nil
        ) -> DocumentViewModel {
            DocumentViewModel(
                data: Data(label.utf8), fileURL: nil, format: format, preferences: preferences ?? self.preferences,
                library: UserLibrary(root: directory.appendingPathComponent("Library")),
                renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: TestFixtures.pdf("Finish", pages: 1))! }),
                settingsStore: store)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out")
    }

    @Test("何も選ばない文書の仕上げは既定のままで、余白も番号も今と同じ")
    func defaults() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let settings = try #require(environment.model().renderSettings)
        #expect(settings.finish == PrintFinish())
        #expect(settings.options.margins == .uniform(15))
        #expect(settings.options.furniture == PageFurniture())
    }

    @Test("テキストの仕上げは組版の設定に載り、PDF には載らず、ヘッダーはどちらにも載る")
    func finishByFormat() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let text = environment.model()
        text.printFinish.breaks.h1 = .page
        text.printOptions.furniture = .name
        #expect(try #require(text.renderSettings).finish.breaks.h1 == .page)
        #expect(text.finishAppliesToText)
        let pdf = environment.model(format: .pdf)
        pdf.printFinish.breaks.h1 = .page
        pdf.printOptions.furniture = .name
        #expect(try #require(pdf.renderSettings).finish == PrintFinish())
        #expect(try #require(pdf.renderSettings).options.furniture == .name)
        #expect(!pdf.finishAppliesToText)
        #expect(pdf.rememberedSettings.printFinish == nil)
    }

    @Test("仕上げは文書の設定に残り、同じ文書を開くと戻る")
    func remembered() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let first = environment.model("同じ文書")
        first.start()
        try await waitUntil { first.contentHash != nil }
        first.printFinish.toc.mode = .front
        first.printOptions.margins = PageMargins(top: 10, left: 20, bottom: 30, right: 40)
        first.printOptions.furniture = .nameAndDate
        first.rememberedSettingsDidChange()
        let key = try #require(first.contentHash).hex
        try await waitUntil { environment.store.record(for: key) != nil }
        let second = environment.model("同じ文書")
        second.start()
        try await waitUntil { second.contentHash != nil }
        #expect(second.printFinish.toc.mode == .front)
        #expect(second.printOptions.margins == PageMargins(top: 10, left: 20, bottom: 30, right: 40))
        #expect(second.printOptions.furniture == .nameAndDate)
    }

    @Test("既定にした仕上げで新しい文書が始まり、余白の設定を変えると余白だけ追う")
    func finishDefaults() {
        let environment = Environment()
        defer { environment.cleanUp() }
        var options = PrintOptions()
        options.furniture = .name
        options.rotatesBackSides = true
        var finish = PrintFinish()
        finish.toc.mode = .hidden
        environment.preferences.setFinishDefaults(options: options, finish: finish)
        let preferences = environment.preferences
        #expect(preferences.printOptions.furniture == .name)
        #expect(!preferences.printOptions.rotatesBackSides)
        #expect(preferences.printFinish.toc.mode == .hidden)
        #expect(environment.model(preferences: preferences).printFinish.toc.mode == .hidden)
        preferences.margin = 20
        #expect(preferences.printOptions.margins == .uniform(20))
        #expect(preferences.printOptions.furniture == .name)
    }

    @Test("判の切替は同じ刷り方の用紙へ移り、切替を覚える")
    func series() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let model = environment.model(preferences: preferences)
        model.layoutID = PrintLayout.a4BookletA5.id
        #expect(model.trayPaperSeries == .a)
        model.choosePaperSeries(.b)
        #expect(model.layoutID == PrintLayout.b5BookletB6.id)
        #expect(model.trayPaperSeries == .b)
        #expect(AppPreferences(defaults: environment.suite.defaults).paperSeries == .b)
        model.choosePaperSeries(.a)
        #expect(model.layoutID == PrintLayout.a4BookletA5.id)
    }

    @Test("判の初期値は文書の用紙から決まり、既定のレイアウトの文書では覚えた判を出す")
    func initialSeries() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        preferences.paperSeries = .b
        let fresh = environment.model(preferences: preferences)
        #expect(fresh.trayPaperSeries == .b)
        #expect(fresh.layoutID == PrintLayout.a4Single.id)
        fresh.layoutID = PrintLayout.a3BookletA4.id
        #expect(fresh.trayPaperSeries == .a)
    }

    @Test("⌘1〜⌘6 は表示中の判のカードの順に当たる")
    func cards() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        model.chooseCard(at: 2)
        #expect(model.layoutID == PrintLayout.a3BookletA4.id)
        model.choosePaperSeries(.b)
        model.chooseCard(at: 3)
        #expect(model.layoutID == PrintLayout.b5BookletB6.id)
        model.chooseCard(at: 5)
        #expect(model.layoutID == PrintLayout.a4Handout3.id)
        #expect(model.trayPaperSeries == .a)
    }

    @Test("組み込みのセットを選ぶと名前が出て、変えると変更ありになり、戻すと消える")
    func builtInSet() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        let set = try #require(PrintSettingSet.builtIns(language: model.language).first)
        model.applyPrintSettingSet(set)
        #expect(model.activeSettingSet?.id == set.id)
        #expect(model.layoutID == "a4Duplex")
        #expect(model.printOptions.furniture == .nameAndDate)
        #expect(model.printFinish.toc.mode == .hidden)
        #expect(!model.isSettingSetChanged)
        model.printFinish.breaks.h1 = .page
        #expect(model.isSettingSetChanged)
        model.overwriteActiveSettingSet()
        #expect(model.preferences.printSettingSets.isEmpty)
        model.printFinish.breaks.h1 = .none
        #expect(!model.isSettingSetChanged)
    }

    @Test("自分のセットは上書きでき、新しく保存すると新しいセットが今のセットになる")
    func ownSet() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let model = environment.model(preferences: preferences)
        model.printOptions.margins = PageMargins(top: 10, left: 20, bottom: 30, right: 40)
        model.savePrintSettingSet(named: "自分")
        #expect(model.activeSettingSet?.name == "自分")
        model.printOptions.furniture = .name
        #expect(model.isSettingSetChanged)
        model.overwriteActiveSettingSet()
        #expect(!model.isSettingSetChanged)
        #expect(preferences.printSettingSets.count == 1)
        #expect(preferences.printSettingSets.first?.furniture == .name)
        #expect(preferences.printSettingSets.first?.margins == model.printOptions.margins)
        model.savePrintSettingSet(named: "別")
        #expect(model.activeSettingSet?.name == "別")
    }

    @Test("古い設定セットを当てても 4 辺の余白とヘッダーになる")
    func oldSet() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let json =
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"Old","marginsInMillimeters":12,"showsPageNumbers":true}"#
        let set = try JSONDecoder().decode(PrintSettingSet.self, from: Data(json.utf8))
        let model = environment.model()
        model.applyPrintSettingSet(set)
        #expect(model.printOptions.margins == .uniform(12))
        #expect(model.printOptions.furniture == .pageNumber)
    }

    @Test("要約の行に文字数と読む時間を出す")
    func statistics() {
        let text = PrintModeText.statistics(DocumentStatistics(characters: 1784), language: "ja")
        #expect(text == "1,784 字・読む時間 約 4 分")
    }

    @Test("足したページは数えて知らせ、何も足さないときは言わない")
    func additions() {
        #expect(PrintModeText.additions(contents: 0, blanks: 0, language: "ja") == nil)
        #expect(PrintModeText.additions(contents: 1, blanks: 0, language: "ja") == "目次 1 ページを足しました")
        #expect(PrintModeText.additions(contents: 1, blanks: 2, language: "ja") == "目次 1 ページ・白紙 2 ページを足しました")
    }

    @Test("ヘッダーのある印刷オプションは番号と別の言葉で知らせる")
    func reminder() {
        var options = PrintOptions()
        #expect(PrintModeText.options(options, layout: .a4Single, language: "ja") == nil)
        options.furniture = .pageNumber
        #expect(PrintModeText.options(options, layout: .a4Single, language: "ja") == "ページ番号あり")
        options.furniture = .name
        #expect(PrintModeText.options(options, layout: .a4Single, language: "ja") == "ヘッダー・フッター")
    }

    @Test("文書の設定を消すと仕上げも既定に戻る")
    func reset() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        model.printFinish.breaks.h1 = .page
        model.printOptions.furniture = .name
        model.resetDocumentSettings()
        #expect(model.printFinish == PrintFinish())
        #expect(model.printOptions.furniture == PageFurniture())
    }
}

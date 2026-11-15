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
        // The default layout was A4 single-sided; it is now its B counterpart, for the next documents.
        #expect(AppPreferences(defaults: environment.suite.defaults).layoutID == "b5Single")
        model.choosePaperSeries(.a)
        #expect(model.layoutID == PrintLayout.a4BookletA5.id)
    }

    @Test("旧版が判だけを覚えていた設定でも、次の文書はその判の片面で始まり、カードも同じ判になる")
    func seriesRememberedByAnEarlierVersion() {
        let environment = Environment()
        defer { environment.cleanUp() }
        // What an earlier version stored after a series was chosen on a tray: the series, and no default layout.
        environment.suite.defaults.set("b", forKey: "paperSeries")
        let preferences = environment.preferences
        #expect(preferences.layoutID == "b5Single")
        let fresh = environment.model(preferences: preferences)
        #expect(fresh.layoutID == "b5Single")
        #expect(fresh.trayPaperSeries == .b)
        // Reading the old setting does not store a default layout.
        #expect(environment.suite.defaults.object(forKey: "layout") == nil)
    }

    @Test(
        "旧版が既定のレイアウトと別の判を覚えていた設定では、既定のレイアウトが残り、カードもその紙の判になる",
        arguments: ["ja_JP", "en_US"])
    func layoutAndAnotherSeriesStoredByAnEarlierVersion(region: String) {
        let environment = Environment()
        defer { environment.cleanUp() }
        let defaults = environment.suite.defaults
        defaults.set("a4Duplex", forKey: "layout")
        defaults.set("b", forKey: "paperSeries")
        let preferences = AppPreferences(defaults: defaults, locale: Locale(identifier: region))
        #expect(preferences.layoutID == "a4Duplex")
        let fresh = environment.model(preferences: preferences)
        #expect(fresh.layoutID == "a4Duplex")
        #expect(fresh.trayPaperSeries == .a)
        // Reading leaves what was stored as it was.
        #expect(defaults.string(forKey: "layout") == "a4Duplex")
        #expect(defaults.string(forKey: "paperSeries") == "b")
    }

    @Test("既定でないレイアウトの文書のカードは、覚えた判ではなくその文書の用紙の判になる")
    func cardsFollowTheDocumentsOwnPaper() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        preferences.choosePaperSeries(.b)
        let fresh = environment.model(preferences: preferences)
        #expect(fresh.trayPaperSeries == .b)
        fresh.layoutID = "a3BookletA4"
        #expect(fresh.trayPaperSeries == .a)
    }

    @Test("判を変えると、次に開く文書も同じ刷り方のままその判で始まる")
    func chosenSeriesStartsTheNextDocument() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        preferences.layoutID = "a4Duplex"
        let model = environment.model(preferences: preferences)
        model.layoutID = "a3BookletA4"
        model.choosePaperSeries(.letter)
        #expect(model.layoutID == "tabloidBookletLetter")
        #expect(preferences.layoutID == "letterDuplex")
        let next = environment.model("次の文書", preferences: preferences)
        #expect(next.layoutID == "letterDuplex")
        #expect(next.trayPaperSeries == .letter)
        #expect(AppPreferences(defaults: environment.suite.defaults).layoutID == "letterDuplex")
    }

    @Test("設定で既定のレイアウトを選ぶと、刷り台のカードもその紙の判になる")
    func cardsFollowTheDefaultLayoutChosenInSettings() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        preferences.choosePaperSeries(.letter)
        preferences.layoutID = "b5Duplex"
        let model = environment.model(preferences: preferences)
        #expect(model.layoutID == "b5Duplex")
        #expect(model.trayPaperSeries == .b)
    }

    @Test("見せるだけの判の切り替えは、覚えた判と既定のレイアウトを変えない")
    func shownSeriesIsNotRemembered() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let model = environment.model(preferences: preferences)
        model.choosePaperSeries(.b, remembers: false)
        #expect(model.layoutID == "b5Single")
        #expect(model.trayPaperSeries == .b)
        #expect(preferences.layoutID == "a4Single")
        #expect(environment.suite.defaults.object(forKey: "layout") == nil)
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

    @Test("ヘッダーは刷り台の行で見えるので、要約の下には裏面の回転だけを知らせる")
    func reminder() {
        var options = PrintOptions()
        options.furniture = .name
        #expect(PrintModeText.options(options, layout: .a4Duplex, language: "ja") == nil)
        options.rotatesBackSides = true
        #expect(PrintModeText.options(options, layout: .a4Single, language: "ja") == nil)
        #expect(PrintModeText.options(options, layout: .a4Duplex, language: "ja") == "裏面 180° 回転")
    }

    @Test("ヘッダーの「自分で入れる」は入力欄が空でも選んだままで、ほかを選ぶと戻る")
    func writingFurniture() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        #expect(model.furnitureChoice == .none)
        model.chooseFurniture(.custom)
        #expect(model.furnitureChoice == .custom)
        #expect(model.isPrintFinishPresented)
        #expect(model.finishSection == .furniture)
        #expect(model.printOptions.furniture == PageFurniture())
        model.chooseFurniture(.number)
        #expect(model.furnitureChoice == .number)
        #expect(model.printOptions.furniture == .pageNumber)
    }

    @Test("表示モードで開いた印刷の設定は、スタイルのパレットを閉じ、刷り台に入ると閉じる")
    func printSettingsInViewMode() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        model.openThemePalette()
        model.presentPrintSettings()
        #expect(model.mode == .view)
        #expect(model.isPrintFinishPresented)
        #expect(!model.isThemePalettePresented)
        model.enterPrintMode()
        #expect(model.mode == .print)
        #expect(!model.isPrintFinishPresented)
    }

    @Test("表示モードでスタイルのパレットを開くと印刷の設定は閉じる")
    func paletteClosesPrintSettings() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        model.presentPrintSettings()
        model.openThemePalette()
        #expect(model.isThemePalettePresented)
        #expect(!model.isPrintFinishPresented)
    }

    @Test("刷り台で開いた印刷の設定は、表示モードへ戻ると閉じる")
    func printSettingsOnTray() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        model.enterPrintMode()
        model.presentPrintSettings()
        #expect(model.isPrintFinishPresented)
        model.exitPrintMode()
        #expect(model.mode == .view)
        #expect(!model.isPrintFinishPresented)
    }

    @Test("表示で組んだページが刷り台と同じなら、刷り台に入ったときから文書の情報に今の設定の枚数を出す")
    func trayFiguresWithoutRender() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        model.layoutID = PrintLayout.a4BookletA5.id
        model.start()
        try await waitUntil { model.printResult != nil && !model.isRendering }
        #expect(model.currentTrayFigures == nil)
        model.enterPrintMode()
        #expect(model.isUpToDate)
        #expect(model.currentTrayFigures?.sheetCount == 1)
        #expect(model.currentTrayFigures?.paper == "A4")
    }

    @Test("文書の情報は、印刷画面を開いて組んだあとだけ今の設定の枚数を出す")
    func trayFigures() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        model.start()
        try await waitUntil { model.printResult != nil && !model.isRendering }
        #expect(model.currentTrayFigures == nil)
        model.chooseLayout("a4BookletA5")
        model.render()
        try await waitUntil { model.printResult?.layout.id == "a4BookletA5" && !model.isRendering }
        #expect(model.currentTrayFigures?.sheetCount == 1)
        #expect(model.currentTrayFigures?.paper == "A4")
        model.layoutID = "a4Duplex"
        #expect(model.currentTrayFigures == nil)
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

    @Test("設定の既定のヘッダーは PageFurniture で覚え、ページ番号の古い記録は読むときに移す")
    func defaultFurniture() {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.suite.defaults.set(true, forKey: "pageNumbers")
        #expect(environment.preferences.defaultFurniture == .pageNumber)
        var custom = PageFurniture()
        custom.topLeft = "{題名}"
        let preferences = environment.preferences
        preferences.defaultFurniture = custom
        #expect(environment.preferences.defaultFurniture == custom)
        #expect(environment.preferences.printOptions.furniture == custom)
    }

    @Test("既定にしたヘッダーは、設定で別の物を選ぶまで消えない")
    func customFurnitureStays() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        var options = PrintOptions()
        options.furniture.topLeft = "{題名}"
        preferences.setFinishDefaults(options: options, finish: PrintFinish())
        preferences.margin = 12
        #expect(environment.preferences.printOptions.furniture.topLeft == "{題名}")
        preferences.defaultFurniture = .pageNumber
        #expect(environment.preferences.printOptions.furniture == .pageNumber)
    }
}

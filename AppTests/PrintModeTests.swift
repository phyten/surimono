import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct PrintTrayTests {
    private func tray(_ layout: PrintLayout, pages: Int, rotatesBackSides: Bool = false) -> PrintTray {
        PrintTray(
            plan: Imposition.plan(pageCount: pages, layout: layout), layout: layout,
            rotatesBackSides: rotatesBackSides)
    }

    @Test("混在用紙のラベルと枚数を日本語と英語で示す")
    func mixedOrientations() {
        let orientations: [PaperOrientation] = [.portrait, .portrait, .landscape, .landscape, .landscape, .landscape]
        let tray = PrintTray(
            plan: Imposition.plan(pageCount: 6, layout: .a4Single), layout: .a4Single,
            rotatesBackSides: false, sheetOrientations: orientations)
        #expect(PrintModeText.sheetSubtitle(tray.sheets[0], layout: .a4Single, language: "ja") == "A4 縦")
        #expect(PrintModeText.sheetSubtitle(tray.sheets[2], layout: .a4Single, language: "ja") == "A4 横")
        #expect(PrintModeText.sheetSubtitle(tray.sheets[2], layout: .a4Single, language: "en") == "A4 landscape")
        #expect(PrintModeText.mixedNote(orientations, language: "ja") == "縦 2 枚・横 4 枚")
        #expect(PrintModeText.mixedNote(orientations, language: "en") == "2 portrait · 4 landscape")
        #expect(PrintModeText.mixedNote([.portrait], language: "ja") == nil)
        #expect(PrintModeText.string("Auto (Mixed)", language: "ja") == "自動（混在）")
    }

    @Test("3枚＋メモは縦の片面3枚とページ範囲を示す")
    func handout() {
        let sheets = tray(.a4Handout3, pages: 7).sheets
        #expect(sheets.count == 3)
        #expect(sheets[2].sides[0].pages == [7, nil, nil])
        #expect(PrintModeText.cardTitle(.a4Handout3, language: "ja") == "A4 3枚＋メモ")
        #expect(PrintModeText.cardTitle(.a4Handout3, language: "en") == "A4 3-up + Notes")
        #expect(PrintModeText.handoutCaption([1, 2, 3], language: "ja") == "1–3 ページ")
        #expect(PrintModeText.handoutCaption([7, nil, nil], language: "ja") == "7 ページ")
        #expect(PrintModeText.handoutCaption([4, 5, nil], language: "en") == "Pages 4–5")
        #expect(PrintModeText.sheetSubtitle(sheets[0], layout: .a4Handout3, language: "ja") == "A4 縦")
        #expect(PrintModeText.note(.a4Handout3, pageCount: 7, language: "ja") == "左に3ページ・右にメモ欄・最後の空き枠は白紙")
        #expect(
            PrintModeText.note(.a4Handout3, pageCount: 6, language: "en")
                == "Three pages on the left · notes on the right")
    }

    @Test("横向き通常印刷の説明は解決済み用紙の向きを示す")
    func landscapeNote() {
        #expect(
            PrintModeText.note(PrintLayout.a4Single.oriented(true), pageCount: 4, language: "ja") == "A4 横・1ページを1枚に")
        #expect(PrintModeText.note(.a4Single, pageCount: 4, language: "en") == "A4 portrait · one page per sheet")
        #expect(
            PrintModeText.note(PrintLayout.a4Single.oriented(true), pageCount: 4, language: "en")
                == "A4 landscape · one page per sheet")
    }

    @Test("上下2アップの説明とラベルは奇数ページの下半分の白紙を示す")
    func stackedNotesAndCaptions() {
        let layout = PrintLayout.a3TwoUp.oriented(true)
        #expect(PrintModeText.note(layout, pageCount: 4, language: "ja") == "2ページを上下に配置・折らずに使う")
        #expect(PrintModeText.note(layout, pageCount: 3, language: "ja") == "2ページを上下に配置・折らずに使う・最後の下半分は白紙")
        #expect(
            PrintModeText.note(layout, pageCount: 3, language: "en")
                == "Two pages stacked, no folding · the last bottom half is blank")
        #expect(
            PrintModeText.note(.a3TwoUp, pageCount: 3, language: "en")
                == "Two pages side by side, no folding · the last right half is blank")
        let sheets = tray(layout, pages: 3).sheets
        #expect(sheets[1].sides[0].visiblePages == [3, nil])
        #expect(PrintModeText.stackedCaption(sheets[0].sides[0].visiblePages, language: "ja") == "1–2 ページ")
        #expect(PrintModeText.stackedCaption(sheets[1].sides[0].visiblePages, language: "ja") == "3 ページ・下半分は白紙")
        #expect(PrintModeText.stackedCaption([1, 2], language: "en") == "Pages 1–2")
    }

    @Test("12ページのA3中綴じは3枚の用紙になり、1枚目の表は[12|1]、裏は[2|11]になる")
    func a3Booklet() {
        let tray = tray(.a3BookletA4, pages: 12)
        #expect(tray.sheets.count == 3)
        #expect(tray.sheets[0].sides.map(\.pages) == [[12, 1], [2, 11]])
        #expect(tray.sheets[0].sides.map(\.face) == [.front, .back])
        #expect(tray.sheets[1].sides.map(\.pages) == [[10, 3], [4, 9]])
        #expect(tray.sheets[2].sides.map(\.pages) == [[8, 5], [6, 7]])
    }

    @Test("用紙の表裏は面付けしたPDFの1面ずつに順に対応する")
    func documentIndices() {
        let tray = tray(.a3BookletA4, pages: 12)
        #expect(tray.sheets.map { $0.sides.map(\.documentIndex) } == [[0, 1], [2, 3], [4, 5]])
    }

    @Test("冊子の用紙は外側から順に、いちばん外側・中間・いちばん内側になる")
    func bookletPositions() {
        #expect(tray(.a3BookletA4, pages: 12).sheets.map(\.position) == [.outermost, .middle, .innermost])
        #expect(tray(.a4BookletA5, pages: 3).sheets.map(\.position) == [.only])
    }

    @Test("5ページのA4中綴じは8ページに揃え、足りないページは白紙にする")
    func a4BookletBlanks() {
        let tray = tray(.a4BookletA5, pages: 5)
        #expect(tray.sheets.count == 2)
        #expect(tray.sheets[0].sides.map(\.pages) == [[nil, 1], [2, nil]])
        #expect(tray.sheets[1].sides.map(\.pages) == [[nil, 3], [4, 5]])
    }

    @Test("A4片面は1ページを1枚に置き、表裏も重ねる位置も持たない")
    func a4Single() {
        let tray = tray(.a4Single, pages: 3)
        #expect(tray.sheets.map { $0.sides.map(\.pages) } == [[[1]], [[2]], [[3]]])
        #expect(tray.sheets.allSatisfy { $0.sides.map(\.face) == [.single] })
        #expect(tray.sheets.allSatisfy { $0.position == .unstacked })
    }

    @Test("3ページのA4両面は2枚になり、最後の用紙の裏は白紙になる")
    func a4Duplex() {
        let tray = tray(.a4Duplex, pages: 3)
        #expect(tray.sheets.map { $0.sides.map(\.pages) } == [[[1], [2]], [[3], [nil]]])
        #expect(tray.sheets.allSatisfy { $0.sides.map(\.face) == [.front, .back] })
    }

    @Test("3ページのA3 2アップは2枚になり、最後の右側は白紙で、刷り台には2枚ずつ並ぶ")
    func a3TwoUp() {
        let tray = tray(.a3TwoUp, pages: 3)
        #expect(tray.sheets.map { $0.sides.map(\.pages) } == [[[1, 2]], [[3, nil]]])
        #expect(tray.sheets.allSatisfy { $0.sides.map(\.face) == [.single] })
        #expect(tray.rows.map { $0.sheets.map(\.number) } == [[1, 2]])
    }

    @Test("2アップ以外のレイアウトは刷り台に1枚ずつ並ぶ")
    func oneSheetPerRow() {
        #expect(tray(.a3BookletA4, pages: 12).rows.map { $0.sheets.map(\.number) } == [[1], [2], [3]])
    }

    @Test("裏面を180°回すと、回した裏面だけ左右のページが入れ替わって見える")
    func rotatedBackSides() {
        let sheet = tray(.a3BookletA4, pages: 12, rotatesBackSides: true).sheets[0]
        #expect(sheet.sides.map(\.isRotated) == [false, true])
        #expect(sheet.sides.map(\.visiblePages) == [[12, 1], [11, 2]])
    }

    @Test("片面のレイアウトは裏面の回転を選んでいても回さない")
    func singleSidedNeverRotates() {
        #expect(tray(.a3TwoUp, pages: 4, rotatesBackSides: true).sheets.allSatisfy { !$0.sides[0].isRotated })
    }

    @Test("用紙の見出しは何枚目かと、冊子では重ねる位置を日本語で示す")
    func japaneseHeadings() {
        let tray = tray(.a3BookletA4, pages: 12)
        #expect(PrintModeText.sheetTitle(tray.sheets[0], language: "ja") == "1 枚目")
        #expect(
            PrintModeText.sheetSubtitle(tray.sheets[0], layout: .a3BookletA4, language: "ja") == "A3 横・いちばん外側")
        #expect(PrintModeText.sheetSubtitle(tray.sheets[1], layout: .a3BookletA4, language: "ja") == "A3 横")
        #expect(
            PrintModeText.sheetSubtitle(tray.sheets[2], layout: .a3BookletA4, language: "ja")
                == "A3 横・いちばん内側（中央の見開き）")
    }

    @Test("用紙の見出しは英語でも番号と向きを示す")
    func englishHeadings() {
        let sheet = tray(.a4Single, pages: 1).sheets[0]
        #expect(PrintModeText.sheetTitle(sheet, language: "en") == "Sheet 1")
        #expect(PrintModeText.sheetSubtitle(sheet, layout: .a4Single, language: "en") == "A4 portrait")
        let twoUp = tray(.a3TwoUp, pages: 2).sheets[0]
        #expect(PrintModeText.sheetSubtitle(twoUp, layout: .a3TwoUp, language: "en") == "A3 landscape")
    }

    @Test("表裏のラベルは表と裏、回した裏面には180°を付け、片面には付けない")
    func faceLabels() {
        let booklet = tray(.a4BookletA5, pages: 8, rotatesBackSides: true).sheets[0]
        #expect(booklet.sides.map { PrintModeText.faceLabel($0, language: "ja") } == ["表", "裏 180°"])
        #expect(PrintModeText.faceLabel(tray(.a4Single, pages: 1).sheets[0].sides[0], language: "ja") == nil)
    }

    @Test("冊子の要約の2行目は、折ってできる冊子と白紙の数を示す")
    func bookletNote() {
        #expect(PrintModeText.note(.a3BookletA4, pageCount: 12, language: "ja") == "重ねて中央で折ると A4 冊子・白紙なし")
        #expect(
            PrintModeText.note(.a4BookletA5, pageCount: 5, language: "ja")
                == "重ねて中央で折ると A5 冊子・白紙 3 ページ（裏表紙の手前）")
    }

    @Test("レイアウトのカードは用紙と刷り方を短く示す")
    func cardTitles() {
        #expect(
            PrintLayout.presets.map { PrintModeText.cardTitle($0, language: "ja") } == [
                "A4 片面", "A4 両面", "A3 中綴じ", "A4 中綴じ", "A3 2アップ", "A4 3枚＋メモ",
            ])
    }

    @Test("ページ数は英語では単数と複数を使い分け、日本語ではページと数える")
    func pageCount() {
        #expect(PrintModeText.pageCount(1, language: "en") == "1 page")
        #expect(PrintModeText.pageCount(12, language: "en") == "12 pages")
        #expect(PrintModeText.pageCount(12, language: "ja") == "12 ページ")
    }

    @Test("幅1000の窓のA3中綴じの刷り台は、A4を約33%で並べる")
    func trayZoom() {
        let metrics = TrayMetrics(layout: .a3BookletA4, viewportWidth: 1000, zoom: 1)
        #expect(metrics.zoomPercent == 33)
        #expect(abs(metrics.rowWidth - 812) < 0.01)
    }

    @Test("A4片面の刷り台は、窓の高さに1枚が収まる大きさで始まる")
    func trayFitsSheetHeight() {
        let metrics = TrayMetrics(layout: .a4Single, viewportWidth: 1000, viewportHeight: 500, zoom: 1)
        // 500 minus the heading and captions leaves 436 for the A4 sheet, 841.89 pt tall.
        #expect(abs(metrics.sideSize.height - 436) < 0.01)
        #expect(metrics.zoomPercent == 52)
    }

    @Test("最小の刷り台でも倍率1なら用紙とラベルが幅と高さに収まる", arguments: PrintLayout.presets)
    func minimumTrayFitsSheet(layout: PrintLayout) {
        let metrics = TrayMetrics(layout: layout, viewportWidth: 760, viewportHeight: 300, zoom: 1)
        #expect(metrics.rowWidth + 88 <= 760)
        #expect(metrics.sideSize.height + 64 <= 300.01)
    }

    @Test("高さに余裕のある窓では、刷り台は今までどおり幅で大きさが決まる")
    func trayKeepsWidthWhenTall() {
        let tall = TrayMetrics(layout: .a3BookletA4, viewportWidth: 1000, viewportHeight: 2000, zoom: 1)
        #expect(tall.zoomPercent == 33)
    }

    @Test("縦と横が混ざる刷り台は、背の高い縦の紙が収まる大きさにする")
    func trayFitsPortraitWhenMixed() {
        let metrics = TrayMetrics(
            layout: PrintLayout.a4Single.oriented(true), viewportWidth: 1000, viewportHeight: 500,
            mixedOrientations: true, zoom: 1)
        #expect(abs(metrics.scale * 841.89 - 436) < 0.01)
    }

    @Test("折ってみるでは表紙、見開き、中央の見開き、裏表紙の順にめくる")
    func foldSpreads() {
        #expect(FoldBook.spread(row: 0, pageCount: 12) == .cover(1))
        #expect(FoldBook.spread(row: 1, pageCount: 12) == .pages(2, 3, isCenter: false))
        #expect(FoldBook.spread(row: 3, pageCount: 12) == .pages(6, 7, isCenter: true))
        #expect(FoldBook.spread(row: 6, pageCount: 12) == .backCover(12))
    }
}

@MainActor
struct PrintModeTests {
    @MainActor private final class Fixture {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences: AppPreferences
        let library: UserLibrary

        init() {
            preferences = AppPreferences(defaults: suite.defaults)
            library = UserLibrary(root: root)
        }

        func model(format: DocumentFormat = .pdf) -> DocumentViewModel {
            DocumentViewModel(data: Data(), fileURL: nil, format: format, preferences: preferences, library: library)
        }

        deinit {
            suite.remove()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("新しいウィンドウは表示モードで開く")
    func startsInViewMode() {
        let fixture = Fixture()
        #expect(fixture.model().mode == .view)
    }

    @Test("印刷モードに入り、表示モードに戻れる")
    func enterAndExit() {
        let fixture = Fixture()
        let model = fixture.model()
        model.enterPrintMode()
        #expect(model.mode == .print)
        model.exitPrintMode()
        #expect(model.mode == .view)
    }

    @Test("表示モードの⌘Pは印刷モードに入り、印刷モードの⌘Pは選んだプリンターですぐ印刷する")
    func printCommand() {
        let fixture = Fixture()
        let model = fixture.model()
        #expect(model.printCommand == .enterPrintMode)
        #expect(model.canPerformPrintCommand)
        model.performPrintCommand()
        #expect(model.mode == .print)
        #expect(model.printCommand == .printNow)
    }

    @Test("選んだプリンターはアプリ全体の設定として覚える")
    func selectedPrinterIsRemembered() throws {
        let fixture = Fixture()
        let model = fixture.model()
        model.selectPrinter("Office Laser")
        #expect(fixture.preferences.printerName == "Office Laser")
        let defaults = try #require(UserDefaults(suiteName: fixture.suite.name))
        #expect(AppPreferences(defaults: defaults).printerName == "Office Laser")
    }

    @Test("印刷の順番は既定で後ろの紙からで、選んだ順番をアプリ全体の設定として覚える")
    func pageOrderIsRemembered() throws {
        let fixture = Fixture()
        #expect(fixture.preferences.printPageOrder == .lastSheetFirst)
        fixture.preferences.printPageOrder = .firstSheetFirst
        let defaults = try #require(UserDefaults(suiteName: fixture.suite.name))
        #expect(AppPreferences(defaults: defaults).printPageOrder == .firstSheetFirst)
    }

    @Test("印刷モードの⌘Pは、用紙ができるまで使えない")
    func printPanelNeedsOutput() {
        let fixture = Fixture()
        let model = fixture.model()
        model.enterPrintMode()
        #expect(!model.canPerformPrintCommand)
        model.performPrintCommand()
        #expect(model.mode == .print)
    }

    @Test("自動の向き表示は読み飛ばした画像を含めず残った用紙の向きに従う")
    func automaticOrientationControl() {
        #expect(PaperOrientationControl.automaticValue(for: [.portrait]) == "Auto (Portrait)")
        #expect(PaperOrientationControl.automaticValue(for: [.landscape]) == "Auto (Landscape)")
        #expect(PaperOrientationControl.automaticValue(for: [.portrait, .landscape]) == "Auto (Mixed)")
        #expect(PaperOrientationControl.automaticValue(for: []) == "Auto")
    }

    @Test("固定向きのレイアウトは向き操作を無効化して用紙の向きを表示し保存値を変えない")
    func fixedOrientationControl() {
        let fixture = Fixture()
        let model = fixture.model()
        model.paperOrientation = .landscape
        model.chooseLayout(PrintLayout.a4Handout3.id)
        let control = PaperOrientationControl(model: model)
        #expect(control.isFixed)
        #expect(control.value == "Portrait")
        #expect(model.paperOrientation == .landscape)
        model.chooseLayout(PrintLayout.a3BookletA4.id)
        #expect(PaperOrientationControl(model: model).value == "Landscape")
        model.chooseLayout(PrintLayout.a4Single.id)
        #expect(!PaperOrientationControl(model: model).isFixed)
        #expect(model.paperOrientation == .landscape)
    }

    @Test("⌘1〜⌘6のレイアウト選択はレイアウトを変えて印刷モードに入る")
    func chooseLayout() {
        let fixture = Fixture()
        let model = fixture.model()
        model.chooseLayout(PrintLayout.a3BookletA4.id)
        #expect(model.layoutID == "a3BookletA4")
        #expect(model.mode == .print)
    }

    @Test("知らないレイアウトは選ばず、モードも変えない")
    func unknownLayout() {
        let fixture = Fixture()
        let model = fixture.model()
        model.chooseLayout("a2Poster")
        #expect(model.layoutID == "a4Single")
        #expect(model.mode == .view)
    }

    @Test("印刷オプションは既定値から始まり、描画設定はウィンドウの印刷オプションを使う")
    func renderSettingsUsePrintOptions() throws {
        let fixture = Fixture()
        fixture.preferences.margin = 12
        fixture.preferences.pageNumbers = true
        let model = fixture.model()
        #expect(
            model.printOptions
                == PrintOptions(marginsInMillimeters: 12, showsPageNumbers: true, rotatesBackSides: false))
        model.printOptions.marginsInMillimeters = 20
        model.printOptions.rotatesBackSides = true
        let options = try #require(model.renderSettings).options
        #expect(options == PrintOptions(marginsInMillimeters: 20, showsPageNumbers: true, rotatesBackSides: true))
    }

    @Test("ウィンドウの印刷オプションを変えても既定値と別のウィンドウは変わらない")
    func printOptionsArePerWindow() {
        let fixture = Fixture()
        let first = fixture.model()
        let second = fixture.model()
        first.printOptions.showsPageNumbers = true
        first.printOptions.marginsInMillimeters = 5
        #expect(!fixture.preferences.pageNumbers)
        #expect(fixture.preferences.margin == 15)
        #expect(second.printOptions == PrintOptions())
    }

    @Test("初回調整済みの文書は刷り台で変えた高さを保ち幅を紙の比に戻す", .timeLimit(.minutes(1)))
    func returnFitsRenderedPaperKeepingHeight() async throws {
        let fixture = Fixture()
        let model = DocumentViewModel(
            data: try PrintWindowFixtures.pdf(size: CGSize(width: 600, height: 400)),
            fileURL: nil, format: .pdf, preferences: fixture.preferences, library: fixture.library)
        defer { model.stop() }
        model.setLayout(.single)
        try await render(model)
        #expect(model.paperUnitSize == CGSize(width: 600, height: 400))
        let window = PrintWindowFixtures.window(width: 900, height: 600)
        model.window = window
        model.sizeWindowToPaper()
        ViewerWindow.setPaperSize(CGSize(width: 900, height: 600), band: 0, of: window, animate: false)
        let original = window.frame
        model.enterPrintMode()
        #expect(window.frame == original)
        window.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 640), display: false)
        model.exitPrintMode()
        try await waitUntil { model.mode == .view && window.frame.size == CGSize(width: 960, height: 640) }
        #expect(window.frame.height == 640)
        #expect(window.frame.width == 960)
    }

    @Test("刷り台でレイアウトを変えると復帰時の幅は新しい紙の形に合う", .timeLimit(.minutes(1)))
    func returnFitsNewlyRenderedLayout() async throws {
        let fixture = Fixture()
        // Only pagination is substituted; the renderer still rebuilds the logical pages for the selected layout.
        let renderer = DocumentRenderer(paginate: { request in
            try #require(PDFDocument(data: PrintWindowFixtures.pdf(size: request.pageSize)))
        })
        let model = DocumentViewModel(
            data: Data("# Window fixture".utf8), fileURL: nil, format: .markdown,
            preferences: fixture.preferences, library: fixture.library, renderer: renderer)
        defer { model.stop() }
        model.setLayout(.single)
        model.paperOrientation = .landscape
        try await render(model)
        let firstPaper = try #require(model.paperUnitSize)
        #expect(firstPaper.width > firstPaper.height)
        let window = PrintWindowFixtures.window(width: 849, height: 600)
        model.window = window
        model.sizeWindowToPaper()
        ViewerWindow.setPaperSize(CGSize(width: 849, height: 600), band: 0, of: window, animate: false)
        let original = window.frame
        model.enterPrintMode()
        #expect(window.frame == original)
        model.chooseLayout(PrintLayout.a4BookletA5.id)
        try await render(model)
        let newPaper = try #require(model.paperUnitSize)
        #expect(abs(newPaper.width - 419.52756) < 0.01)
        #expect(abs(newPaper.height - 595.27559) < 0.01)
        #expect(newPaper != firstPaper)
        #expect(renderer.logicalRenderCount == 2)
        model.exitPrintMode()
        try await waitUntil { model.mode == .view && window.frame.size == CGSize(width: 423, height: 600) }
        #expect(window.frame.height == 600)
        #expect(window.frame.width == 423)
    }

    @Test("復帰後の初回限定のサイズ調整は枠を変えない", .timeLimit(.minutes(1)))
    func initialOnlyDoesNotRefitAfterReturning() async throws {
        let fixture = Fixture()
        let model = DocumentViewModel(
            data: try PrintWindowFixtures.pdf(size: CGSize(width: 600, height: 400)),
            fileURL: nil, format: .pdf, preferences: fixture.preferences, library: fixture.library)
        defer { model.stop() }
        model.setLayout(.single)
        try await render(model)
        _ = try #require(model.paperUnitSize)
        let window = PrintWindowFixtures.window(width: 900, height: 600)
        model.window = window
        model.sizeWindowToPaper()
        ViewerWindow.setPaperSize(CGSize(width: 900, height: 600), band: 0, of: window, animate: false)
        model.enterPrintMode()
        model.exitPrintMode()
        try await waitUntil { model.mode == .view && window.frame.size == CGSize(width: 900, height: 600) }
        // A deliberately non-paper frame makes an accidental second fit observable.
        ViewerWindow.unlockAspectRatio(of: window)
        let chosen = NSRect(x: 100, y: 100, width: 1000, height: 650)
        window.setFrame(chosen, display: false)
        #expect(window.frame == chosen)
        model.sizeWindowToPaper(initialOnly: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.frame == chosen)
    }

    private func render(_ model: DocumentViewModel) async throws {
        model.render()
        try await waitUntil { !model.isRendering }
        #expect(model.error == nil)
        try #require(model.result != nil)
        try #require(model.isUpToDate)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }
}

@MainActor
struct PrintModeWindowTests {
    @Test("自動拡大しなければ紙の形へ合わせる前の枠は利用者の選んだまま残す")
    func unchangedEntryKeepsUserFrame() {
        let window = makeWindow(width: 1000, height: 700)
        let original = window.frame
        PrintModeWindow.enter(window)
        #expect(window.frame == original)
        let chosen = NSRect(x: 100, y: 100, width: 1050, height: 720)
        window.setFrame(chosen, display: false)
        var completed = false
        PrintModeWindow.exit(window) { completed = true }
        #expect(completed)
        #expect(window.frame == chosen)
    }

    @Test("小さい窓を刷り台の最小まで広げたときだけ元の枠に戻す")
    func enlargedTrayRestoresFrame() {
        let window = makeWindow(width: 500, height: 400)
        let original = window.frame
        PrintModeWindow.enter(window)
        #expect(window.frame.size == NSSize(width: 760, height: 560))
        var completed = false
        PrintModeWindow.exit(window) { completed = true }
        #expect(completed)
        #expect(window.frame == original)
    }

    @Test("見比べ台から刷り台へ移っても縮めず最初の表示枠へ戻す")
    func comparisonToTrayKeepsOriginalFrame() {
        let window = makeWindow(width: 800, height: 600)
        let original = window.frame
        PrintModeWindow.enter(window, size: PrintModeWindow.compareSize)
        #expect(window.frame.size == NSSize(width: 900, height: 620))
        let comparison = window.frame
        PrintModeWindow.enter(window)
        #expect(window.frame == comparison)
        PrintModeWindow.exit(window) {}
        #expect(window.frame == original)
    }

    @Test("十分な窓は見比べ台と刷り台を経ても紙の形へ合わせる前の枠を変えない")
    func largeWindowSurvivesBothStages() {
        let window = makeWindow(width: 1000, height: 700)
        let original = window.frame
        PrintModeWindow.enter(window, size: PrintModeWindow.compareSize)
        #expect(window.frame == original)
        PrintModeWindow.enter(window)
        #expect(window.frame == original)
        PrintModeWindow.exit(window) {}
        #expect(window.frame == original)
    }

    private func makeWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        PrintWindowFixtures.window(width: width, height: height)
    }

    @Test("十分な窓は刷り台へ入っても位置と大きさを変えない")
    func trayFrame() {
        let frame = NSRect(x: 300, y: 100, width: 800, height: 600)
        #expect(
            PrintModeWindow.trayFrame(around: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))
                == frame)
    }

    @Test("刷り台は不足する寸法だけ760×560まで広げる")
    func growsOnlyMissingDimension() {
        #expect(
            PrintModeWindow.trayFrame(
                around: NSRect(x: 300, y: 100, width: 600, height: 800),
                visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 1000))
                == NSRect(x: 220, y: 100, width: 760, height: 800))
    }

    @Test("見比べ台は900×620まで広げ画面内に収める")
    func compareFrame() {
        #expect(
            PrintModeWindow.trayFrame(
                around: NSRect(x: 1200, y: 500, width: 600, height: 400),
                visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
                size: PrintModeWindow.compareSize)
                == NSRect(x: 540, y: 255, width: 900, height: 620))
    }

    @Test("小さな画面では画面内まで広げるが既存の大きい寸法は縮めない")
    func trayFrameOnSmallScreen() {
        #expect(
            PrintModeWindow.trayFrame(
                around: NSRect(x: 100, y: 100, width: 600, height: 800),
                visibleFrame: NSRect(x: 0, y: 25, width: 700, height: 675))
                == NSRect(x: 0, y: 100, width: 700, height: 800))
    }
}

@MainActor
private enum PrintWindowFixtures {
    static func window(width: CGFloat, height: CGFloat) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: width, height: height),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
    }

    static func pdf(size: CGSize) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

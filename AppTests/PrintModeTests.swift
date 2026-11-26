import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct PrintTrayTests {
    private func tray(_ layout: PrintLayout, pages: Int, rotatesBackSides: Bool = false) -> PrintTray {
        PrintTray(
            plan: Imposition.plan(pageCount: pages, layout: layout), layout: layout,
            rotatesBackSides: rotatesBackSides)
    }

    @Test("論理ページを含む最初の用紙の行を返す")
    func rowContainingPage() {
        #expect(tray(.a4Single, pages: 8).rowID(containing: 3) == 2)
        #expect(tray(.a4Duplex, pages: 8).rowID(containing: 4) == 1)
        #expect(tray(.a4BookletA5, pages: 8).rowID(containing: 8) == 0)
        #expect(tray(.a4BookletA5, pages: 8).rowID(containing: 3) == 1)
        #expect(tray(.a3TwoUp, pages: 8).rowID(containing: 4) == 0)
        #expect(tray(.a3TwoUp, pages: 8).rowID(containing: 5) == 2)
        #expect(tray(.a4Single, pages: 8).rowID(containing: 0) == nil)
        #expect(tray(.a4Single, pages: 8).rowID(containing: 9) == nil)
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
        #expect(PrintModeText.cardTitle(.a4Handout3, language: "ja") == "3 ページ＋\nメモ欄")
        #expect(PrintModeText.cardTitle(.a4Handout3, language: "en") == "3 Pages + Notes")
        #expect(PrintModeText.handoutCaption([1, 2, 3], language: "ja") == "1–3 ページ")
        #expect(PrintModeText.handoutCaption([7, nil, nil], language: "ja") == "7 ページ")
        #expect(PrintModeText.handoutCaption([4, 5, nil], language: "en") == "Pages 4–5")
        #expect(PrintModeText.sheetSubtitle(sheets[0], layout: .a4Handout3, language: "ja") == "A4 縦")
    }

    @Test("上下2アップのラベルは奇数ページの下半分の白紙を示す")
    func stackedCaptions() {
        let layout = PrintLayout.a3TwoUp.oriented(true)
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

    @Test("レイアウトのカードは上に結果、下に用紙を示す")
    func cardTitles() {
        #expect(
            (PrintLayout.presets(in: .a) + PrintLayout.presets(in: .b).prefix(5)).map {
                PrintModeText.cardTitle($0, language: "ja")
            } == [
                "A4 片面", "A4 両面", "A4 冊子", "A5 冊子", "2 ページを\n1 枚に", "3 ページ＋\nメモ欄",
                "B5 片面", "B5 両面", "B5 冊子", "B6 冊子", "2 ページを\n1 枚に",
            ])
        #expect(
            (PrintLayout.presets(in: .a) + PrintLayout.presets(in: .b).prefix(5)).map {
                PrintModeText.cardPaper($0, language: "ja")
            } == [
                nil, nil, "用紙：A3・両面", "用紙：A4・両面", "用紙：A3", "用紙：A4",
                nil, nil, "用紙：B4・両面", "用紙：B5・両面", "用紙：B4",
            ])
    }

    @Test("カードの右上の札は、仕上がりと違う用紙を使うカードにだけ判の名前を出す")
    func cardSheets() {
        #expect(
            PrintLayout.presets(in: .a).map(PrintModeText.cardSheet) == [nil, nil, "A3", "A4", "A3", "A4"])
        #expect(PrintModeText.cardSheet(.tabloidBookletLetter) == "Tabloid")
        #expect(PrintModeText.cardSheet(.b4TwoUp) == "B4")
        #expect(PrintModeText.cardSheet(.a4FourUp) == "A4")
    }

    @Test("カードの読み上げは、名前と使う用紙をひとまとまりで読み、題の改行を空白か詰めにする")
    func cardLabels() {
        #expect(PrintModeText.cardLabel(.a3BookletA4, issue: nil, language: "ja") == "A4 冊子・用紙：A3・両面")
        #expect(PrintModeText.cardLabel(.a3BookletA4, issue: nil, language: "en") == "A4 Booklet, Paper: A3, Two-Sided")
        #expect(PrintModeText.cardLabel(.a3TwoUp, issue: nil, language: "ja") == "2 ページを 1 枚に・用紙：A3")
        #expect(PrintModeText.cardLabel(.a4Handout3, issue: nil, language: "ja") == "3 ページ＋メモ欄・用紙：A4")
        #expect(PrintModeText.cardLabel(.a4Single, issue: nil, language: "ja") == "A4 片面")
    }

    @Test("どの言語でもカードの題は2行に収まる")
    func cardTitlesFitTwoLines() {
        // The card leaves 72 points for its title in 12-point semibold; a third line would be cut.
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let layouts = PaperSeries.allCases.flatMap { PrintLayout.presets(in: $0) + PrintLayout.compactPresets(in: $0) }
        for language in ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"] {
            for layout in layouts {
                let title = PrintModeText.cardTitle(layout, language: language)
                let storage = NSTextStorage(string: title, attributes: [.font: font])
                let manager = NSLayoutManager()
                let container = NSTextContainer(size: CGSize(width: 72, height: CGFloat.greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                manager.addTextContainer(container)
                storage.addLayoutManager(manager)
                var lines = 0
                manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
                    _, _, _, _, _ in lines += 1
                }
                #expect(lines <= 2, "\(language) \(layout.id): \(title) (\(width(title)))")
            }
        }
    }

    @Test("上の説明は1行目に何を何に刷るか、2行目に綴じ方を書き、折り方の手順は含めない")
    func instructionsAreTwoLines() {
        func lines(_ layout: PrintLayout, sheets: Int, pages: Int, _ language: String) -> [String] {
            PrintModeText.instructions(layout, sheets: sheets, pages: pages, language: language)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
        }
        #expect(
            lines(.a4BookletA5, sheets: 2, pages: 8, "ja") == ["**A4 2 枚から A5 の冊子 8 ページ**", "両面・短辺とじ · 左とじ"])
        #expect(
            lines(.a4BookletA5, sheets: 2, pages: 8, "en")
                == ["**A5 booklet, 8 pages, from 2 sheets of A4**", "Duplex, short edge · Left Binding"])
        #expect(lines(.a3BookletA4, sheets: 3, pages: 12, "ja") == ["**A3 3 枚から A4 の冊子 12 ページ**", "両面・短辺とじ · 左とじ"])
        #expect(lines(.a4Duplex, sheets: 2, pages: 4, "ja") == ["**A4 縦 2 枚に 4 ページ**", "両面・長辺とじ"])
        #expect(lines(.a4Single, sheets: 3, pages: 3, "ja") == ["**A4 縦 3 枚に 3 ページ**", "片面"])
        #expect(lines(PrintLayout.a4Single.oriented(true), sheets: 3, pages: 3, "ja")[0] == "**A4 横 3 枚に 3 ページ**")
        #expect(lines(.a3TwoUp, sheets: 2, pages: 4, "ja") == ["**A3 横 2 枚に 4 ページ**", "片面"])
        #expect(lines(.a3TwoUp.oriented(true), sheets: 2, pages: 4, "ja")[0] == "**A3 縦 2 枚に 4 ページ**")
        #expect(lines(.a4Handout3, sheets: 3, pages: 9, "ja") == ["**A4 縦 3 枚に 9 ページ**", "片面"])
        #expect(
            lines(.a4Single, sheets: 1, pages: 1, "en") == ["**1 page on 1 sheet of A4 portrait**", "Single-sided"])
    }

    @Test("上の説明は、数と単位の間で行が折れないように、その間を行末で分けない空白にする")
    func instructionsKeepNumbersWithUnits() {
        let text = PrintModeText.instructions(.a4Single, sheets: 1, pages: 12, language: "ja")
        #expect(text.contains("1\u{00A0}枚"))
        #expect(text.contains("12\u{00A0}ページ"))
        #expect(text.contains("A4\u{00A0}縦"))
    }

    @Test("折り方や重ね方の手順は、どのレイアウトの上の説明にも出さない")
    func instructionsLeaveFoldingToTheFoldView() {
        for layout in PrintLayout.presets {
            for language in ["ja", "en"] {
                let text = PrintModeText.instructions(layout, sheets: 2, pages: 8, language: language)
                for word in ["ホチキス", "重ねて", "折り", "staple", "fold", "Stack"] {
                    #expect(!text.contains(word), "\(layout.id) \(language): \(word)")
                }
            }
        }
    }

    @Test("刷り台の頁数は白紙の半面も数え、要約の「仕上がり」と同じになる")
    func trayCountsBlankHalves() {
        #expect(tray(.a4BookletA5, pages: 5).pageCount == 8)
        #expect(tray(.a4Duplex, pages: 3).pageCount == 4)
        #expect(tray(.a3TwoUp, pages: 3).pageCount == 4)
        #expect(tray(.a4Single, pages: 3).pageCount == 3)
        #expect(tray(.a4Handout3, pages: 7).pageCount == 9)
    }

    @Test("上の帯のメニューは、設定が既定のままなら値を出さず、変えたときだけ値を出す")
    func stripShowsValuesOnlyWhenSet() {
        #expect(PrintFurnitureChoice.stripTitle(.none) == nil)
        #expect(PrintFurnitureChoice.stripTitle(.number) != nil)
        #expect(PrintFurnitureChoice.stripTitle(.nameAndDate) != nil)
        #expect(PrintChapterBreakChoice.stripTitle(.none) == nil)
        #expect(PrintChapterBreakChoice.stripTitle(.page) != nil)
        #expect(PrintChapterBreakChoice.stripTitle(.rightPage) != nil)
        #expect(PrintContentsChoice.stripTitle(.inline) == nil)
        #expect(PrintContentsChoice.stripTitle(.page) != nil)
        #expect(PrintNoteChoice.stripTitle(false) == nil)
        #expect(PrintNoteChoice.stripTitle(true) != nil)
    }

    @Test("刷り台はノートのページを 1 始まりの番号で覚える")
    func trayKnowsNotes() {
        let plan = Imposition.plan(pageCount: 4, layout: .a4BookletA5)
        let tray = PrintTray(plan: plan, layout: .a4BookletA5, rotatesBackSides: false, notePages: [0, 2])
        #expect(tray.notePages == [1, 3])
    }

    @Test("ノートのあるページ数は本文とノートの内訳を出す")
    func pageCountWithNotes() {
        #expect(PrintModeText.pageCount(3, notes: 2, language: "ja") == "3 ページ（本文 1＋ノート 2）")
        #expect(PrintModeText.pageCount(3, notes: 0, language: "ja") == "3 ページ")
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

    @Test("とじ方を選ぶまでは冊子は読む向きに従い、文書の設定には入らず、選んだあとは保つ")
    func bindingFollowsReadingOnce() throws {
        let fixture = Fixture()
        let model = fixture.model()
        model.updateViewOptions { $0.direction = .rightToLeft }
        model.chooseLayout(PrintLayout.a4BookletA5.id)
        #expect(model.layout.isRightBound)
        // Not the reader's choice yet, so nothing of it goes into the document's settings.
        #expect(model.rememberedSettings.bookletBinding == nil)
        model.updateViewOptions { $0.direction = .leftToRight }
        #expect(!model.layout.isRightBound)
        model.updateViewOptions { $0.direction = .rightToLeft }
        model.bookletBinding = .left
        model.chooseLayout(PrintLayout.letterBookletHalfLetter.id)
        #expect(!model.layout.isRightBound)
        let record = try JSONDecoder().decode(
            DocumentSettings.self, from: JSONEncoder().encode(model.rememberedSettings))
        #expect(record.bookletBinding == .left)
        #expect(FoldBook.spread(row: 1, pageCount: 8, rightBound: true) == .pages(3, 2, isCenter: false))
        #expect(FoldBook.spread(row: 2, pageCount: 8, rightBound: true) == .pages(5, 4, isCenter: true))
    }

    @Test("各系列のカードは最小幅の窓でも収まり追加レイアウトへ切り替わる", arguments: PaperSeries.allCases)
    func compactCardsInWindow(series: PaperSeries) async throws {
        let fixture = Fixture()
        let model = fixture.model()
        model.choosePaperSeries(series)
        let controller = NSHostingController(rootView: PrintPressBar(model: model))
        let host = controller.view
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.alphaValue = 0
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        #expect(controller.sizeThatFits(in: CGSize(width: 600, height: 300)).width <= 603)
        #expect(controller.sizeThatFits(in: CGSize(width: 600, height: 300)).height < 300)
        model.chooseLayout(PrintLayout.compactPresets(in: series)[1].id)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(model.layout.kind == .fourUp)
        #expect(controller.sizeThatFits(in: CGSize(width: 600, height: 300)).width <= 603)
        model.chooseCard(at: 4)
        #expect(model.layout.id == PrintLayout.presets(in: series)[4].id)
        #expect(model.layout.kind == .twoUp)
    }

    @Test("地域の初回既定はLetterを選び保存済みレイアウトを変えない")
    func regionalPreferences() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let first = AppPreferences(defaults: suite.defaults, locale: Locale(identifier: "en_US"), defaultPaperSize: nil)
        #expect(first.layoutID == "letterSingle")
        first.layoutID = "b5Duplex"
        let restored = AppPreferences(
            defaults: suite.defaults, locale: Locale(identifier: "en_US"), defaultPaperSize: nil)
        #expect(restored.layoutID == "b5Duplex")
    }

    @Test("初回の既定は地域で決まり、単位がメートル法のカナダでもLetterになる")
    func regionalPreferencesFollowTheRegion() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let canada = AppPreferences(defaults: suite.defaults, locale: Locale(identifier: "en_CA"))
        #expect(canada.layoutID == "letterSingle")
        let japan = AppPreferences(defaults: suite.defaults, locale: Locale(identifier: "ja_JP"))
        #expect(japan.layoutID == "a4Single")
        // The Mac's own default paper comes before the region.
        let abroad = AppPreferences(
            defaults: suite.defaults, locale: Locale(identifier: "en_US"),
            defaultPaperSize: CGSize(width: 595, height: 842))
        #expect(abroad.layoutID == "a4Single")
        // Looking at the first default does not store it.
        #expect(suite.defaults.object(forKey: "layout") == nil)
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

    @Test("用紙の PDF ボタンは各言語で文字が入るときだけ名前を出す", arguments: UILanguage.supported)
    func sheetPDFButtonFits(language: String) {
        let fixture = Fixture()
        let button = PrintPressBar(model: fixture.model()).pdfButton.environment(\.locale, Locale(identifier: language))
        let ideal = NSHostingView(rootView: button.fixedSize()).fittingSize
        let controller = NSHostingController(rootView: button)
        func width(_ proposed: CGFloat) -> CGFloat {
            controller.sizeThatFits(in: CGSize(width: proposed, height: ideal.height)).width
        }
        let compact = width(0)
        #expect(compact >= 35 && compact < ideal.width)
        #expect(width(ideal.width - 2) == compact)
        #expect(width(ideal.width + 2) >= ideal.width)
    }

    #if DEBUG
        @MainActor private final class FinishLayout {
            private(set) var frames: [PrintFinishFrame] = []

            func host(_ content: some View) -> NSView {
                let panel =
                    content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .coordinateSpace(name: "printFinishPanel")
                    .onPreferenceChange(PrintFinishFrames.self) { self.frames = $0 }
                return NSHostingView(rootView: panel)
            }

            func checkNativeControls(in host: NSView) {
                func visit(_ view: NSView) {
                    guard !view.isHidden else { return }
                    if view is NSControl, !view.bounds.isEmpty {
                        let rect = view.convert(view.bounds, to: host)
                        #expect(
                            rect.minX >= host.bounds.minX && rect.maxX <= host.bounds.maxX,
                            "control=\(type(of: view)) frame=\(rect) panel=\(host.bounds)")
                    }
                    for child in view.subviews { visit(child) }
                }
                visit(host)
            }

            func checkBounds(in host: NSView) {
                for frame in frames {
                    let rect = frame.rect
                    #expect(
                        !rect.isEmpty && rect.minX >= host.bounds.minX && rect.maxX <= host.bounds.maxX,
                        "item=\(frame.element) frame=\(rect) panel=\(host.bounds)")
                }
            }
        }

        @Test("改ページと目次は収まる幅で横一列になり、狭くするとメニューに同じ選択値が出る", arguments: ["en", "de", "ja"])
        func finishSegmentsFit(language: String) {
            func check<Value>(
                _ label: LocalizedStringKey, _ choices: [PrintChoice<Value>], selected: Value, title: LocalizedStringKey
            ) {
                let segments = PrintSegments(label: label, options: choices, selection: selected) { _ in
                    Issue.record("幅の変更で選択が書き換わった")
                }
                .environment(\.locale, Locale(identifier: language))
                let controller = NSHostingController(rootView: segments)
                let layout = FinishLayout()
                let host = layout.host(segments)
                let rowWidth = controller.sizeThatFits(in: CGSize(width: 1200, height: 100)).width
                for width: CGFloat in [1200, 428, 411, 160, 1200] {
                    let available = CGSize(width: width, height: 100)
                    #expect(controller.sizeThatFits(in: available).width <= width)
                    host.setFrameSize(available)
                    host.layoutSubtreeIfNeeded()
                    let placed = layout.frames.filter { $0.element == .row(label) || $0.element == .menu(label) }
                    let expected: PrintFinishFrame.Element = rowWidth <= width ? .row(label) : .menu(label)
                    #expect(placed.map(\.element) == [expected], "language=\(language) width=\(width)")
                    #expect(placed.first?.selected == title)
                    layout.checkBounds(in: host)
                }
            }
            check("Page Breaks", PrintChapterBreakChoice.choices, selected: .page, title: "New Page for Each Chapter")
            check("Placement", PrintContentsChoice.choices, selected: .page, title: "Separate Page")
        }

        // The sheet normally rebuilds levelRow from its body when the document's rules change.
        private struct HeadingBreakTestRow: View {
            let model: DocumentViewModel

            var body: some View {
                PrintFinishSheet(model: model).levelRow(level: 2, rule: model.controlBinding(\.printFinish.breaks.h2))
            }
        }

        @Test("切り替わる幅の前後では、三択を変えても形を保ち、読み上げの名前と値がモデルに合う", arguments: ["en", "de", "fr", "ja"])
        func finishSelectionAtBoundary(language: String) throws {
            let fixture = Fixture()
            let model = fixture.model(format: .markdown)
            let locale = Locale(identifier: language)
            let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let strings = try #require(Bundle(url: url))

            // SwiftUI's virtual children can expose the public AX selectors without NSAccessibilityProtocol conformance.
            func containsChoice(in children: [Any], name: String, value: String) -> Bool {
                for child in children {
                    let node = child as AnyObject
                    let rawValue: Any? = node.accessibilityValue?()
                    if [node.accessibilityLabel?(), node.accessibilityTitle?()].contains(name),
                        node.accessibilityValueDescription?() == value || rawValue as? String == value
                    {
                        return true
                    }
                    if containsChoice(in: node.accessibilityChildren?() ?? [], name: name, value: value) { return true }
                }
                return false
            }

            func check<Value: Equatable>(
                _ control: some View, label: String, selection: Binding<Value>, choices: [(Value, String)]
            ) throws {
                let layout = FinishLayout()
                let localized = control.environment(\.locale, locale).environment(\.accessibilityEnabled, true)
                let boundary = NSHostingView(rootView: localized.fixedSize()).fittingSize.width
                let host = layout.host(localized)
                let key = LocalizedStringKey(label)
                host.setFrameSize(CGSize(width: 1200, height: 100))
                host.layoutSubtreeIfNeeded()
                let row = try #require(layout.frames.first { $0.element == .row(key) })
                let name = strings.localizedString(forKey: label, value: nil, table: nil)
                for delta: CGFloat in [-1, 1] {
                    host.setFrameSize(CGSize(width: boundary + delta, height: 100))
                    for (value, title) in choices {
                        selection.wrappedValue = value
                        host.layoutSubtreeIfNeeded()
                        let placed = layout.frames.filter { $0.element == .menu(key) || $0.element == .row(key) }
                        #expect(selection.wrappedValue == value)
                        #expect(placed.map(\.element) == [delta < 0 ? .menu(key) : .row(key)])
                        #expect(placed.first?.selected == LocalizedStringKey(title))
                        if delta > 0 { #expect(placed.first?.rect.width == row.rect.width) }
                        let spoken = strings.localizedString(forKey: title, value: nil, table: nil)
                        #expect(
                            containsChoice(in: host.accessibilityChildren() ?? [], name: name, value: spoken),
                            "language=\(language) name=\(name) value=\(spoken) delta=\(delta)")
                    }
                }
            }
            try check(
                PrintChapterBreakChoice(model: model), label: "Page Breaks",
                selection: model.controlBinding(\.printFinish.breaks.h1),
                choices: [
                    (.none, "Do Not Break at Headings"), (.page, "New Page for Each Chapter"),
                    (.rightPage, "Chapters from Right Page"),
                ])
            try check(
                PrintContentsChoice(model: model), label: "Placement",
                selection: model.controlBinding(\.printFinish.contents.placement),
                choices: [
                    (.inline, "Same Page as Text"), (.page, "Separate Page"),
                ])
            let rule = model.controlBinding(\.printFinish.breaks.h2)
            try check(
                HeadingBreakTestRow(model: model), label: "Page Breaks", selection: rule,
                choices: [(.none, "None"), (.page, "Page Break"), (.rightPage, "From Right Page")])
        }

        @Test("幅428ptの印刷設定では英独の改ページと目次がメニューになり、日本語は横一列を保つ", arguments: ["en", "de", "ja"])
        func finishChoicesInPanel(language: String) {
            let fixture = Fixture()
            let model = fixture.model(format: .markdown)
            model.printFinish.breaks.h1 = .page
            model.printFinish.legacyPresetContents.mode = .front
            let layout = FinishLayout()
            let host = layout.host(PrintFinishSheet(model: model).environment(\.locale, Locale(identifier: language)))
            host.setFrameSize(CGSize(width: 428, height: 720))
            host.layoutSubtreeIfNeeded()
            func check(_ label: LocalizedStringKey, selected: LocalizedStringKey) {
                let choices = layout.frames.filter { $0.selected == selected }
                #expect(choices.map(\.element) == [language == "ja" ? .row(label) : .menu(label)])
            }
            check("Page Breaks", selected: "New Page for Each Chapter")
            #expect(layout.frames.contains { $0.selected == "Separate Page" })
        }

        @Test(
            "幅460ptの印刷設定は八言語・左右両方向で各見出し・区切り線・選択欄が両端に収まる", arguments: [DocumentFormat.markdown, .latex], [true, false])
        func finishPanelFrames(format: DocumentFormat, hasContents: Bool) async throws {
            let fixture = Fixture()
            fixture.preferences.layoutID = PrintLayout.a4Single.id
            let source: String
            if format == .markdown {
                source = hasContents ? "---\ntoc: true\n---\n# Alpha\n\n[TOC]\n\n## Bravo" : "# Alpha"
            } else {
                let lists = hasContents ? #"\tableofcontents\listoffigures\listoftables"# : ""
                source = #"\documentclass{article}\begin{document}\section{Alpha}\#(lists)\end{document}"#
            }
            let model = DocumentViewModel(
                data: Data(source.utf8), fileURL: nil, format: format, preferences: fixture.preferences,
                library: fixture.library,
                renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: TestFixtures.pdf("Alpha", pages: 1))! }))
            model.printFinish.breaks.h1 = .page
            model.printFinish.contents.placement = .page
            model.start()
            try await waitUntil { model.contentsFacts != nil }
            let hasSection = format == .markdown || hasContents
            #expect(PrintFinishStrip(model: model).applicableItems.contains(.contents) == hasSection)
            var sections: [LocalizedStringKey] = ["Paper & Margins", "Header & Footer", "Page Breaks"]
            if hasSection { sections.append("Contents") }
            if format == .markdown { sections.append("Proof Marks") }
            sections += ["Footnotes", "Links on Paper", "Note Pages", "Printer Adjustments"]

            for language in UILanguage.supported {
                for direction: LayoutDirection in [.leftToRight, .rightToLeft] {
                    let layout = FinishLayout()
                    let panel = PrintFinishSheet(model: model)
                        .environment(\.locale, Locale(identifier: language))
                        .environment(\.layoutDirection, direction)
                    let host = layout.host(panel)
                    host.setFrameSize(CGSize(width: 460, height: 720))
                    host.layoutSubtreeIfNeeded()
                    #expect(host.bounds.width == 460)
                    let elements = layout.frames.map(\.element)
                    #expect(elements.contains(.content))
                    #expect(elements.contains(.heading("Contents")) == hasSection)
                    #expect(elements.contains(.divider("Contents")) == hasSection)
                    for (index, title) in sections.enumerated() {
                        #expect(elements.contains(.heading(title)))
                        if index > 0 { #expect(elements.contains(.divider(title))) }
                    }
                    func choice(
                        _ name: LocalizedStringKey, selected: LocalizedStringKey, options: [LocalizedStringKey] = []
                    ) {
                        if elements.contains(.row(name)) {
                            for option in options { #expect(elements.contains(.segment(option))) }
                        }
                        let frames = layout.frames.filter { $0.element == .menu(name) || $0.element == .row(name) }
                        #expect(
                            frames.contains { $0.selected == selected }, "\(format) \(language) \(direction) \(name)")
                    }
                    choice("Page Breaks", selected: "New Page for Each Chapter")
                    if ["en", "fr"].contains(language) { #expect(elements.contains(.menu("Page Breaks"))) }
                    if format == .markdown {
                        #expect(elements.contains(.label("Lead Contents")))
                        #expect(elements.contains(.picker("Lead Contents")))
                        #expect(elements.contains(.picker("Proof Marks")))
                        for label: LocalizedStringKey in ["Placement", "Look", "Contents in Text"] {
                            #expect(elements.contains(.label(label)) == hasContents)
                            #expect((elements.contains(.row(label)) || elements.contains(.menu(label))) == hasContents)
                        }
                        if hasContents {
                            #expect(elements.contains(.row("Placement")), "\(language) \(direction)")
                            choice(
                                "Placement", selected: "Separate Page", options: ["Same Page as Text", "Separate Page"])
                            choice("Look", selected: "Dotted", options: ["Dotted", "No Lines", "Chapter Lines"])
                            choice("Contents in Text", selected: "As Written", options: ["As Written", "Don't Print"])
                        }
                    } else {
                        for label: LocalizedStringKey in [
                            "Print Contents", "Print List of Figures", "Print List of Tables",
                        ] {
                            #expect(elements.contains(.label(label)) == hasContents)
                            #expect(elements.contains(.toggle(label)) == hasContents)
                        }
                        #expect(!elements.contains(.picker("Lead Contents")))
                    }
                    for picker: LocalizedStringKey in ["Footnotes", "Links on Paper"] {
                        #expect(elements.contains(.picker(picker)))
                    }
                    #expect(elements.contains(.menu("Output Order")) || elements.contains(.row("Output Order")))
                    layout.checkBounds(in: host)
                    layout.checkNativeControls(in: host)
                }
            }
        }

        @Test("英語の見出し別の三択はスクロールバーのある設定行でも一列に収まる", arguments: HeadingBreak.allCases)
        func englishHeadingChoicesFit(rule: HeadingBreak) {
            let fixture = Fixture()
            let sheet = PrintFinishSheet(model: fixture.model(format: .markdown))
            let row = sheet.levelRow(level: 1, rule: .constant(rule)).environment(\.locale, Locale(identifier: "en"))
            // The captured 460 pt panel leaves 411 pt for this row and 256 pt after its label and gap.
            let available = CGSize(width: 411, height: 200)
            let size = NSHostingController(rootView: row).sizeThatFits(in: available)
            #expect(size.width <= available.width)
            let layout = FinishLayout()
            let host = layout.host(row)
            host.setFrameSize(available)
            host.layoutSubtreeIfNeeded()
            #expect(layout.frames.contains { $0.element == .row("Page Breaks") })
            layout.checkBounds(in: host)
        }

        @Test("フランス語の出力順はプリンターの有無にかかわらず右列に収まる", arguments: PrintPageOrder.allCases, [false, true])
        func frenchPrinterOrderFits(order: PrintPageOrder, hasPrinter: Bool) {
            let fixture = Fixture()
            fixture.preferences.printPageOrder = order
            let model = fixture.model()
            model.printerListSource = {
                hasPrinter ? PrinterList(names: ["Test Printer"], defaultName: "Test Printer") : .empty
            }
            model.printerCapabilitiesSource = { _ in nil }
            model.refreshPrinters()
            #expect(model.selectedPrinterName == (hasPrinter ? "Test Printer" : nil))
            let picker = PrintPrinterOptions(model: model).outputOrderPicker.environment(
                \.locale, Locale(identifier: "fr"))
            let controller = NSHostingController(rootView: picker)
            let layout = FinishLayout()
            let host = layout.host(picker)
            for width: CGFloat in [256, 273] {
                let size = CGSize(width: width, height: 100)
                #expect(controller.sizeThatFits(in: size).width <= width)
                host.setFrameSize(size)
                host.layoutSubtreeIfNeeded()
                #expect(layout.frames.map(\.element) == [.menu("Output Order")])
                #expect(layout.frames.first?.isEnabled == hasPrinter)
                layout.checkBounds(in: host)
            }
        }

    #endif

    @Test("印刷の帯は幅0で大きさを聞かれても低いままで、刷り台の窓を縦に縮められる")
    func pressBarStaysLowAtZeroWidth() {
        let fixture = Fixture()
        // SwiftUI sets the window's smallest size from this answer. Measured at zero width, every card and word took a
        // row of its own and the window could not be made shorter than 900.
        let size = NSHostingController(rootView: PrintPressBar(model: fixture.model())).sizeThatFits(in: .zero)
        #expect(size.height < 300)
    }

    @Test("刷り台の窓の最小の高さは、上下の帯と刷り台の操作が収まる高さで、画面より高くならない")
    func printModeMinimumHeight() {
        let fixture = Fixture()
        let model = fixture.model()
        model.enterPrintMode()
        let size = NSHostingController(rootView: PrintModeView(model: model)).sizeThatFits(in: .zero)
        // The stage keeps 200 for the tray's navigator, so the window stops before the tray is gone (it went down to
        // 302); the press bar answers for the width of its cards, so the window is not stuck at 800 high.
        #expect(size.height > 450)
        #expect(size.height < 640)
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

    @Test("描画設定は文書の余白と番号を使い、文書の裏面回転は無視する")
    func renderSettingsUsePrintOptions() throws {
        let fixture = Fixture()
        fixture.preferences.margin = 12
        fixture.preferences.defaultFurniture = .pageNumber
        let model = fixture.model()
        #expect(
            model.printOptions
                == PrintOptions(marginsInMillimeters: 12, showsPageNumbers: true, rotatesBackSides: false))
        model.printOptions.marginsInMillimeters = 20
        model.printOptions.rotatesBackSides = true
        let options = try #require(model.renderSettings).options
        #expect(options == PrintOptions(marginsInMillimeters: 20, showsPageNumbers: true, rotatesBackSides: false))
    }

    @Test("ウィンドウの印刷オプションを変えても既定値と別のウィンドウは変わらない")
    func printOptionsArePerWindow() {
        let fixture = Fixture()
        let first = fixture.model()
        let second = fixture.model()
        first.printOptions.furniture = .pageNumber
        first.printOptions.marginsInMillimeters = 5
        #expect(fixture.preferences.defaultFurniture.isEmpty)
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
        // The bands keep their room of the 640 (70pt on macOS 26: the title band and the bottom band), and the paper
        // of the rest is half as wide again as high.
        let width = ((640 - BandRoom.full(for: .split).total) * 1.5).rounded()
        try await waitUntil { model.mode == .view && window.frame.size == CGSize(width: width, height: 640) }
        #expect(window.frame.height == 640)
        #expect(window.frame.width == width)
    }

    @Test("刷り台で横長の紙から Letter 冊子へ変えると復帰時の幅は新しい紙の形に合う", .timeLimit(.minutes(1)))
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
        model.chooseLayout(PrintLayout.letterBookletHalfLetter.id)
        try await render(model)
        let newPaper = try #require(model.paperUnitSize)
        #expect(abs(newPaper.width - 396) < 0.01)
        #expect(abs(newPaper.height - 612) < 0.01)
        #expect(newPaper != firstPaper)
        #expect(renderer.logicalRenderCount == 2)
        model.exitPrintMode()
        // The bands keep their room of the 600 (70pt on macOS 26); the paper is the rest high.
        let paperHeight = 600 - BandRoom.full(for: .split).total
        let letterWidth = (paperHeight * 396 / 612).rounded()
        try await waitUntil { model.mode == .view && window.frame.size == CGSize(width: letterWidth, height: 600) }
        #expect(window.frame.height == 600)
        #expect(window.frame.width == letterWidth)
        // Completing the view render must not restore the old page shape.
        try await render(model)
        model.sizeWindowToPaper()
        #expect(model.paperUnitSize == CGSize(width: 396, height: 612))
        #expect(window.frame.size == CGSize(width: letterWidth, height: 600))

        model.choosePaperSeries(.b)
        try await render(model)
        model.sizeWindowToPaper()
        #expect(model.mode == .view)
        #expect(model.layoutID == PrintLayout.b5BookletB6.id)
        // B6 (JIS) is 128 × 182 mm.
        #expect(window.frame.size == CGSize(width: (paperHeight * 128 / 182).rounded(), height: 600))
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
        let width = ((600 - BandRoom.full(for: .split).total) * 1.5).rounded()
        try await waitUntil { model.mode == .view && window.frame.size == CGSize(width: width, height: 600) }
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
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        #expect(window.frame.size == NSSize(width: 900, height: min(800, screenHeight)))
        let comparison = window.frame
        PrintModeWindow.enter(window)
        #expect(window.frame == comparison)
        PrintModeWindow.exit(window) {}
        #expect(window.frame == original)
    }

    @Test("十分な窓は見比べ台と刷り台を経ても紙の形へ合わせる前の枠を変えない")
    func largeWindowSurvivesBothStages() {
        let window = makeWindow(width: 1000, height: 800)
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

    @Test("見比べ台は900×800まで広げ画面内に収める")
    func compareFrame() {
        #expect(
            PrintModeWindow.trayFrame(
                around: NSRect(x: 1200, y: 500, width: 600, height: 400),
                visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
                size: PrintModeWindow.compareSize)
                == NSRect(x: 540, y: 75, width: 900, height: 800))
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

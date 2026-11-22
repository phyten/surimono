import AppKit
import CoreGraphics
import Foundation
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

/// The zoom of the tray: how far it goes, and that a zoom keeps the spot under the pointer in place.
@MainActor
struct TrayZoomLimitTests {
    @Test("小さな窓のA3中綴じでも、刷り台は実物の2倍まで拡大できる")
    func smallWindowReachesTwiceTheRealSize() {
        // 760 wide: each A4 page of the booklet is 136 points wide, under a quarter of its real 595.
        #expect(TrayMetrics(layout: .a3BookletA4, viewportWidth: 760, zoom: 1).zoomPercent == 23)
        #expect(TrayMetrics(layout: .a3BookletA4, viewportWidth: 760, zoom: 100).zoomPercent == 200)
    }

    @Test("窓に収まる大きさが実物に近いときは、その2.5倍まで拡大できる")
    func largeFitZoomsTwoAndAHalfTimes() {
        // A4 single in a 1000-wide window fits at 600 points, about its real size.
        #expect(TrayMetrics(layout: .a4Single, viewportWidth: 1000, zoom: 1).zoomPercent == 101)
        #expect(TrayMetrics(layout: .a4Single, viewportWidth: 1000, zoom: 100).zoomPercent == 252)
    }

    @Test("刷り台は窓に収まる大きさの半分まで縮小できる")
    func zoomsOutToHalf() {
        #expect(TrayMetrics(layout: .a3BookletA4, viewportWidth: 1000, zoom: 1).zoomPercent == 33)
        #expect(TrayMetrics(layout: .a3BookletA4, viewportWidth: 1000, zoom: 0.1).zoomPercent == 16)
    }
}

@MainActor
struct TrayGeometryTests {
    /// A4 single in a window 1000 wide and 700 high, with instructions 80 high and sheet headings 18 high: at zoom 1
    /// the sheets are 488 high (700 less the margins, the instructions and the heading and captions' room).
    private func context(rows: Int = 3) -> TrayGeometry.Context {
        TrayGeometry.Context(
            layout: .a4Single, mixedOrientations: false,
            rows: Array(repeating: .init(sheets: 1, sides: 1, paper: PaperSize.a4.size), count: rows),
            showsCaptions: false,
            width: 1000, height: 700, headerHeight: 80, headingHeight: 18)
    }

    @Test("固定した見出しの下だけをスクロールし、用紙は上の余白から順に並ぶ")
    func rowTops() {
        let geometry = TrayGeometry(context: context(), zoom: 1)
        // The stage reserves 22 + 80 for the heading. Rows are 516 high, with 34 between them and 40 below.
        #expect(geometry.viewportSize.height == 598)
        #expect(geometry.rowTops.map { $0.rounded() } == [30, 580, 1130])
        #expect(geometry.contentSize.height.rounded() == 1686)
    }

    @Test("A4片面の刷り台を2倍にしても、ポインタの下の点は同じ場所に残る")
    func zoomKeepsTheSpot() {
        let old = TrayGeometry(context: context(), zoom: 1)
        let new = TrayGeometry(context: context(), zoom: 2)
        // At 248 of a tray scrolled down 400, the spot is 40 into the second sheet's paper, which becomes 80.
        let offset = new.offset(
            keeping: CGPoint(x: 500, y: 248), scrolledTo: CGPoint(x: 0, y: 400), in: old, topInset: 0)
        #expect(abs(offset.x) < 0.01)
        #expect(abs(offset.y - 928) < 0.01)
    }

    @Test("上の帯の下に入り込んだスクロールビューでも、ポインタの下の点は同じ場所に残る")
    func zoomKeepsTheSpotUnderTheBar() {
        let old = TrayGeometry(context: context(), zoom: 1)
        let new = TrayGeometry(context: context(), zoom: 2)
        // The same spot as above, counted from a scroll view that reaches 52 up under the bar.
        let offset = new.offset(
            keeping: CGPoint(x: 500, y: 300), scrolledTo: CGPoint(x: 0, y: 348), in: old, topInset: 52)
        #expect(abs(offset.y - 876) < 0.01)
    }

    @Test("用紙が窓より広くなると、横の位置もポインタの下に合わせる")
    func zoomKeepsTheSpotSideways() {
        let old = TrayGeometry(context: context(), zoom: 1)
        let new = TrayGeometry(context: context(), zoom: 3)
        #expect(!old.scrollsSideways)
        #expect(new.scrollsSideways)
        // The spot is the middle of the 345-wide sheet; at 3 times, the sheet starts at 44 and is 1035 wide.
        let offset = new.offset(
            keeping: CGPoint(x: 500, y: 248), scrolledTo: CGPoint(x: 0, y: 400), in: old, topInset: 0)
        #expect(abs(offset.x - 61.58) < 0.05)
        #expect(abs(offset.y - 1456) < 0.05)
    }

    @Test("用紙の見出しの上で拡大しても、見出しはポインタの下に残る")
    func headingStays() {
        let old = TrayGeometry(context: context(), zoom: 1)
        let new = TrayGeometry(context: context(), zoom: 2)
        // 588 is 8 below the second row's top (580), in its heading: the first sheet's paper grows by 488 above it.
        let offset = new.offset(
            keeping: CGPoint(x: 500, y: 248), scrolledTo: CGPoint(x: 0, y: 340), in: old, topInset: 0)
        #expect(abs(offset.y - 828) < 0.01)
    }

    @Test("冊子の表と裏の間で拡大しても、その隙間は広がらず、ポインタの下に残る")
    func bookletGapStays() {
        // A3 booklet sheets 392 wide on each side, 28 apart, in a window 1000 wide and high enough not to bind.
        let context = TrayGeometry.Context(
            layout: .a3BookletA4, mixedOrientations: false,
            rows: [.init(sheets: 1, sides: 2, paper: PrintLayout.a3BookletA4.sheetSize)], showsCaptions: true,
            width: 1000, height: 2000, headerHeight: 80, headingHeight: 18)
        let old = TrayGeometry(context: context, zoom: 1)
        let new = TrayGeometry(context: context, zoom: 2)
        // The row is 812 wide and starts at 94; 493 is 7 into the gap after the front. At twice the size the row
        // starts at 44 and the front ends at 828, so the spot is at 835.
        let offset = new.offset(keeping: CGPoint(x: 493, y: 300), scrolledTo: .zero, in: old, topInset: 0)
        #expect(abs(offset.x - 342) < 0.01)
    }

    @Test("2アップの左の紙の真ん中で拡大しても、その点はポインタの下に残る")
    func twoUpCenterStays() {
        // A3 2-up sheets 388 wide and 36 apart, in a row 812 wide that starts at 94; the left sheet's middle is 288.
        let context = TrayGeometry.Context(
            layout: .a3TwoUp, mixedOrientations: false,
            rows: [.init(sheets: 2, sides: 1, paper: PrintLayout.a3TwoUp.sheetSize)], showsCaptions: true,
            width: 1000, height: 2000, headerHeight: 80, headingHeight: 18)
        let old = TrayGeometry(context: context, zoom: 1)
        let new = TrayGeometry(context: context, zoom: 2)
        // Twice the size: the row starts at 44 and the left sheet's middle is 44 + 388.
        let offset = new.offset(keeping: CGPoint(x: 288, y: 300), scrolledTo: .zero, in: old, topInset: 0)
        #expect(abs(offset.x - 144) < 0.01)
    }

    @Test("用紙の下の札の上で拡大しても、札はポインタの下に残る")
    func captionStays() {
        // The 277.2-high sheet starts at 58. Its captions start 9 below it, and 350.2 is 15 below the paper.
        let context = TrayGeometry.Context(
            layout: .a3BookletA4, mixedOrientations: false,
            rows: [.init(sheets: 1, sides: 2, paper: PrintLayout.a3BookletA4.sheetSize)], showsCaptions: true,
            width: 1000, height: 500, headerHeight: 80, headingHeight: 18)
        let old = TrayGeometry(context: context, zoom: 1)
        let new = TrayGeometry(context: context, zoom: 2)
        // At twice the size the paper ends at 58 + 554.4, and the spot stays 15 below it.
        let offset = new.offset(
            keeping: CGPoint(x: 500, y: 348), scrolledTo: CGPoint(x: 0, y: 2.2), in: old, topInset: 0)
        #expect(abs(offset.y - 279.4) < 0.05)
    }

    @Test("用紙を拡大・縮小しても、固定した見出しは窓に収まる幅を保つ")
    func pinnedHeaderFitsNarrowStage() {
        let context = TrayGeometry.Context(
            layout: .a3BookletA4, mixedOrientations: false,
            rows: [.init(sheets: 1, sides: 2, paper: PrintLayout.a3BookletA4.sheetSize)], showsCaptions: true,
            width: 400, height: 2000, headerHeight: 80, headingHeight: 18)
        let small = TrayGeometry(context: context, zoom: 0.5)
        let large = TrayGeometry(context: context, zoom: 2)
        #expect(small.headerWidth == 312)
        #expect(large.headerWidth == small.headerWidth)
        #expect(!small.scrollsSideways)
        #expect(large.scrollsSideways)
        #expect(small.viewportSize.height == large.viewportSize.height)
    }

    @Test("スライドやウェブページの印刷項目は固定見出しの下で用紙と一緒にスクロールする")
    func sourceControlsScrollWithSheets() {
        var context = context()
        let ordinary = TrayGeometry(context: context, zoom: 1)
        context.sourceNotesHeight = 58
        let web = TrayGeometry(context: context, zoom: 1)
        #expect(web.viewportSize == ordinary.viewportSize)
        #expect(web.rowTops[0] == ordinary.rowTops[0] + 58)
        let offset = web.offset(showingRow: 1, topInset: 0, x: 0)
        #expect(offset.y == web.rowTops[1])
        #expect(web.rowIndex(atTop: offset.y) == 1)
    }

    @Test("常に表示のスクロールバーは、刷り台が窓より高いときだけ幅を取り、用紙はその残りの真ん中に並ぶ")
    func legacyScrollBar() {
        // A3 booklet sheets fitted to 1000 less a 17-wide bar make a row 795 wide.
        func context(rows: Int, height: CGFloat) -> TrayGeometry.Context {
            TrayGeometry.Context(
                layout: .a3BookletA4, mixedOrientations: false,
                rows: Array(
                    repeating: .init(sheets: 1, sides: 2, paper: PrintLayout.a3BookletA4.sheetSize), count: rows),
                showsCaptions: true, width: 1000, height: height, scroller: 17, headerHeight: 80, headingHeight: 18)
        }
        let short = TrayGeometry(context: context(rows: 1, height: 2000), zoom: 1)
        #expect(abs(short.viewportSize.width - 1000) < 0.01)
        #expect(abs((short.sides(ofRow: 0).first?.start ?? 0) - 102.5) < 0.01)
        let tall = TrayGeometry(context: context(rows: 10, height: 600), zoom: 1)
        #expect(abs(tall.viewportSize.width - 983) < 0.01)
        #expect(abs((tall.sides(ofRow: 0).first?.start ?? 0) - 94) < 0.01)
    }

    @Test("常に表示のスクロールバーで、横のバーが高さを取ると縦のバーも出る")
    func legacyScrollBarsBringEachOther() {
        // Twice the fitted size: a row 1590 wide and a tray 771.38 high, under the 780 of the window until the
        // horizontal bar takes 17 of it.
        let context = TrayGeometry.Context(
            layout: .a3BookletA4, mixedOrientations: false,
            rows: [.init(sheets: 1, sides: 2, paper: PrintLayout.a3BookletA4.sheetSize)], showsCaptions: true,
            width: 1000, height: 780, scroller: 17, headerHeight: 80, headingHeight: 18)
        let geometry = TrayGeometry(context: context, zoom: 2)
        #expect(abs(geometry.viewportSize.width - 983) < 0.01)
        #expect(abs(geometry.viewportSize.height - 661) < 0.01)
    }

    @Test("縮小して下の端を越えるときは、下の端に止まる")
    func zoomOutStopsAtTheEnd() {
        let old = TrayGeometry(context: context(), zoom: 1)
        let new = TrayGeometry(context: context(), zoom: 0.5)
        // At half the size the scroll content is 954 high. Its last 598 points show at offset 356.
        let offset = new.offset(
            keeping: CGPoint(x: 500, y: 548), scrolledTo: CGPoint(x: 0, y: 1088), in: old, topInset: 0)
        #expect(abs(offset.y - 356) < 0.01)
    }

    @Test("用紙の番号は、上端に少しでも見えている一番上の用紙")
    func currentRow() {
        let geometry = TrayGeometry(context: context(), zoom: 1)
        #expect(geometry.rowIndex(atTop: 0) == 0)
        // The first row ends at 546.
        #expect(geometry.rowIndex(atTop: 538) == 0)
        #expect(geometry.rowIndex(atTop: 548) == 1)
        #expect(geometry.rowIndex(atTop: 5000) == 2)
    }

    @Test("用紙を送ると固定した見出しの下にその用紙が来て、1枚目へ戻すと上の余白も見える")
    func showRow() {
        let geometry = TrayGeometry(context: context(), zoom: 1)
        #expect(geometry.offset(showingRow: 1, topInset: 52, x: 0) == CGPoint(x: 0, y: 528))
        #expect(geometry.offset(showingRow: 0, topInset: 52, x: 0) == CGPoint(x: 0, y: -52))
    }
}

@MainActor
struct TrayZoomerTests {
    private func zoomer() -> TrayZoomer {
        let zoomer = TrayZoomer()
        zoomer.context = TrayGeometry.Context(
            layout: .a4Single, mixedOrientations: false,
            rows: Array(repeating: .init(sheets: 1, sides: 1, paper: PaperSize.a4.size), count: 3),
            showsCaptions: false,
            width: 1000, height: 700, headerHeight: 80, headingHeight: 18)
        return zoomer
    }

    @Test("拡大と縮小のボタンは1.25倍ずつ変え、上限と下限で止まる")
    func steps() {
        let zoomer = zoomer()
        zoomer.zoomIn()
        #expect(abs(zoomer.zoom - 1.25) < 0.0001)
        zoomer.zoomOut()
        #expect(abs(zoomer.zoom - 1) < 0.0001)
        for _ in 0..<20 { zoomer.zoomIn() }
        // Twice the real size: the sheet fits at 0.57965 of it.
        #expect(abs(zoomer.zoom - 3.4504) < 0.001)
        #expect(!zoomer.canZoomIn)
        for _ in 0..<20 { zoomer.zoomOut() }
        #expect(abs(zoomer.zoom - 0.5) < 0.0001)
        #expect(!zoomer.canZoomOut)
    }

    @Test("ダブルクリックで窓に収まる大きさの2倍になり、もう一度で戻る")
    func doubleClick() {
        let zoomer = zoomer()
        zoomer.toggleZoom(keeping: CGPoint(x: 500, y: 350))
        #expect(abs(zoomer.zoom - 2) < 0.0001)
        zoomer.toggleZoom(keeping: CGPoint(x: 500, y: 350))
        #expect(abs(zoomer.zoom - 1) < 0.0001)
    }

    @Test("拡大は見える範囲の真ん中を保つ位置へ、新しい大きさと同時にスクロールする")
    func zoomScrollsWithTheSize() {
        let zoomer = zoomer()
        zoomer.scroll = TrayScrollState(offset: CGPoint(x: 0, y: 400), topInset: 0)
        zoomer.zoomIn()
        // The viewport centre is 299 down. At offset 400 that is 91 into the second sheet (from 608).
        // At 1.25 times, the second sheet starts at 730, and the same spot is at 843.75.
        #expect(abs(zoomer.scroll.offset.y - 544.75) < 0.01)
        #expect(zoomer.position.point.map { abs($0.y - 544.75) < 0.01 } == true)
    }

    @Test("用紙を作り直すあいだ刷り台が外れても、次の刷り台が倍率と見ていた用紙を引き継ぐ", .timeLimit(.minutes(1)))
    func remakingKeepsZoomAndSheet() async throws {
        let zoomer = zoomer()
        let context = try #require(zoomer.context)
        zoomer.zoomIn()
        zoomer.scroll(to: CGPoint(x: 0, y: 900))
        let offset = zoomer.scroll.offset
        let next = TrayZoomer()
        next.adopt(try #require(zoomer.leave()))
        next.context = context
        #expect(abs(next.zoom - 1.25) < 0.0001)
        #expect(next.scroll.offset == offset)
        // The new scroll view is told a turn later, once it is up.
        #expect(next.position.point == nil)
        for _ in 0..<200 where next.position.point == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(next.position.point == offset)
    }

    @Test("作り直しのあいだに頼まれた用紙への移動は、前の位置に戻されない", .timeLimit(.minutes(1)))
    func remakingYieldsToARequestedRow() async throws {
        let zoomer = zoomer()
        let context = try #require(zoomer.context)
        zoomer.scroll(to: CGPoint(x: 0, y: 900))
        let next = TrayZoomer()
        next.adopt(try #require(zoomer.leave()))
        // The third sheet is asked for before the new tray is laid out, as when another document of a binder is
        // chosen.
        next.show(row: 2, animated: false)
        next.context = context
        let asked = next.scroll.offset
        #expect(asked.y > 900)
        try await Task.sleep(for: .milliseconds(100))
        #expect(next.scroll.offset == asked)
        #expect(next.position.point == asked)
    }

    @Test("作り直した直後に見出しの高さが測り直されても、外れなかった刷り台と同じ位置になる", .timeLimit(.minutes(1)))
    func remakingSurvivesAMeasuredHeader() async throws {
        let stayed = zoomer()
        let zoomer = zoomer()
        var context = try #require(zoomer.context)
        stayed.scroll(to: CGPoint(x: 0, y: 900))
        zoomer.scroll(to: CGPoint(x: 0, y: 900))
        let next = TrayZoomer()
        next.adopt(try #require(zoomer.leave()))
        next.context = context
        // The fresh scroll view tells of its start at the top, and the header is measured 20 points taller.
        next.scroll.offset = .zero
        context.headerHeight += 20
        next.context = context
        stayed.context = context
        #expect(stayed.scroll.offset.y != 900)
        try await Task.sleep(for: .milliseconds(100))
        #expect(next.scroll.offset == stayed.scroll.offset)
        #expect(next.position.point == stayed.scroll.offset)
    }

    @Test("作り直した用紙が別のレイアウトなら、上から窓に収めて始める")
    func remakingInAnotherLayoutStartsOver() throws {
        let zoomer = zoomer()
        var context = try #require(zoomer.context)
        zoomer.zoomIn()
        zoomer.scroll(to: CGPoint(x: 0, y: 900))
        let next = TrayZoomer()
        next.adopt(try #require(zoomer.leave()))
        context.layout = .a4Duplex
        next.context = context
        #expect(next.zoom == 1)
        #expect(next.scroll.offset == .zero)
        #expect(next.position.point == nil)
    }

    @Test("窓の刷り台で文字の大きさを変えて用紙を作り直しても、倍率と見ていた用紙が残り、窓は固まらない", .timeLimit(.minutes(2)))
    func remakingInAWindow() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = ClipboardWindows(
            openFiles: { _, _, _ in Issue.record("ファイルは開かない") }, warn: { _ in Issue.record("警告しない") }, closeWelcome: {})
        let presentation = ClipboardWindowFixture(windows, ordered: true)
        defer { presentation.close() }
        windows.preferences = AppPreferences(defaults: suite.defaults)
        windows.library = UserLibrary(root: directory)
        let text = (1...400).map { "行 \($0) の本文です。" }.joined(separator: "\n")
        let controller = windows.open(Data(text.utf8), format: .plainText, title: "Long Text", printing: true)
        defer { controller.window?.close() }
        let model = controller.model
        func settle() async throws {
            for _ in 0..<1500 where model.mode != .print || model.isRendering || model.trayZoomer?.context == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        // Where the scroll view itself is, not where it was asked to go.
        func scrolled() -> CGFloat? {
            controller.window?.contentView.flatMap { Self.find(TrayGestureMonitorView.self, in: $0) }?
                .enclosingScrollView?.contentView.bounds.minY
        }
        func waitUntilScrolled(past limit: CGFloat) async throws -> CGFloat {
            for _ in 0..<300 where (scrolled() ?? 0) <= limit { try await Task.sleep(for: .milliseconds(20)) }
            return try #require(scrolled())
        }
        try await settle()
        let zoomer = try #require(model.trayZoomer)
        #expect((model.printTray?.rows.count ?? 0) >= 4)
        zoomer.zoomIn()
        // As a reader does: the next sheet is asked for once the larger sheets are laid out.
        try await Task.sleep(for: .milliseconds(300))
        zoomer.show(row: 2, animated: false)
        let before = try await waitUntilScrolled(past: 500)
        #expect(before > 500)
        let composed = model.printResult?.id
        model.increaseTextSize()
        // The view starts the render a turn later. The tray keeps its sheets meanwhile and shows the new ones once
        // they are made, so the same tray, with its zoom, stays on screen.
        for _ in 0..<1500 where model.printResult?.id == composed || !model.canOutput {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle()
        let next = try #require(model.trayZoomer)
        #expect(next === zoomer)
        #expect(abs(next.zoom - 1.25) < 0.0001)
        let after = try await waitUntilScrolled(past: 500)
        #expect(abs(after - before) < 60)
        #expect(model.canOutput)
    }

    private static func find<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    @Test("窓の幅を変えても、見ていた用紙が見える範囲の上端に残る")
    func resizeKeepsTheSheet() {
        let zoomer = zoomer()
        // The second sheet's row starts at 580.
        zoomer.scroll = TrayScrollState(offset: CGPoint(x: 0, y: 580), topInset: 0)
        // 560 wide, the sheets fit the width at 396 high, so the second row starts at 30 + 424 + 34.
        zoomer.context?.width = 560
        #expect(abs(zoomer.scroll.offset.y - 488) < 0.01)
    }

    @Test("窓を広げて拡大の上限が下がると、倍率も上限まで下がり、次の縮小で小さくなる")
    func resizeLowersTheZoom() {
        let zoomer = zoomer()
        // 300 high, the sheets fit at 120 high (the least), so twice the real size is about 14 times that.
        zoomer.context?.height = 300
        for _ in 0..<30 { zoomer.zoomIn() }
        #expect(zoomer.zoom > 14)
        // Back to 700 high, the sheets fit at 488 high and twice the real size is 3.45 times that.
        zoomer.context?.height = 700
        #expect(abs(zoomer.zoom - 3.4504) < 0.001)
        zoomer.zoomOut()
        #expect(abs(zoomer.zoom - 3.4504 / 1.25) < 0.001)
    }

    @Test("印刷モードの⌘＋・⌘−・⌘0は刷り台の倍率を変え、表示モードでは変えない")
    func menuCommands() {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: root))
        let zoomer = zoomer()
        model.trayZoomer = zoomer
        model.zoomIn()
        #expect(abs(zoomer.zoom - 1) < 0.0001)
        model.enterPrintMode()
        model.zoomIn()
        #expect(abs(zoomer.zoom - 1.25) < 0.0001)
        model.zoomOut()
        model.zoomOut()
        #expect(abs(zoomer.zoom - 0.8) < 0.0001)
        model.zoomToFit()
        #expect(abs(zoomer.zoom - 1) < 0.0001)
    }

}

@MainActor
struct TrayGestureMonitorTests {
    @Test("刷り台の受け口は、刷り台のスクロールビューの上の点だけを受け取り、重ねた部品の上の点は受け取らない")
    func hitTesting() throws {
        let zoomer = TrayZoomer()
        let root = ZStack(alignment: .topLeading) {
            ScrollView {
                Color.white.frame(width: 300, height: 2000)
                    .background { TrayGestureMonitor(zoomer: zoomer) }
            }
            // Stands for the navigator or a panel laid over the tray.
            Color.red.frame(width: 60, height: 60)
        }
        .frame(width: 400, height: 300)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: root)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let monitor = try #require(Self.find(TrayGestureMonitorView.self, in: host))
        #expect(monitor.enclosingScrollView != nil)
        // Window coordinates start at the bottom left; the red square is at the top left.
        #expect(monitor.isOverTray(windowPoint: NSPoint(x: 200, y: 150)))
        #expect(!monitor.isOverTray(windowPoint: NSPoint(x: 20, y: 280)))
    }

    private static func find<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}

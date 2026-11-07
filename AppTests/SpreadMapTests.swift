import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct SpreadMapTests {
    /// The view options popover is 560 pt wide with 16 pt of padding on either side.
    private let popoverWidth: CGFloat = 528

    private func units(_ pageCount: Int, _ layout: ViewOptions.Layout, cover: Bool) -> [DisplayUnit] {
        SpreadLayout.units(pageCount: pageCount, layout: layout, showsCoverAlone: cover, direction: .leftToRight)
    }

    @Test("組み地図のタイルは、単ページだけなら紙 1 枚、見開きがあれば紙 2 枚の幅で、ページ数では変わらない", arguments: [9, 99, 999, 9999])
    func tileWidthFollowsTheSheets(pageCount: Int) {
        for cover in [false, true] {
            #expect(SpreadMap.tileWidth(for: units(pageCount, .single, cover: cover)) == 22, "single, cover \(cover)")
            #expect(SpreadMap.tileWidth(for: units(pageCount, .spread, cover: cover)) == 44, "spread, cover \(cover)")
        }
    }

    @Test("1 ページだけの文書は、見開きの設定でも紙 1 枚の幅になる")
    func onePageDocumentIsOneSheetWide() {
        #expect(SpreadMap.tileWidth(for: units(1, .spread, cover: false)) == 22)
        #expect(SpreadMap.tileWidth(for: units(1, .spread, cover: true)) == 22)
    }

    @Test("単独の表紙も最後に余った 1 ページも紙 1 枚で描き、向かい合う 2 ページは紙 2 枚で描く")
    func sheetsFollowThePagesOnScreen() {
        #expect(DisplayUnit.spread(left: nil, right: 1).visualPages == [1])
        #expect(DisplayUnit.spread(left: 5, right: nil).visualPages == [5])
        #expect(DisplayUnit.spread(left: 2, right: 3).visualPages == [2, 3])
        #expect(DisplayUnit.single(7).visualPages == [7])
    }

    @Test("右綴じの見開きは、画面の左から番号の大きい方を先に並べる")
    func rightToLeftSpreadKeepsTheOrderOnScreen() {
        let units = SpreadLayout.units(pageCount: 4, layout: .spread, showsCoverAlone: false, direction: .rightToLeft)
        #expect(units.map(\.visualPages) == [[2, 1], [4, 3]])
    }

    @Test("読み上げる名前は、1 ページなら番号、見開きなら番号の範囲")
    func pageRangeIsReadAsOneName() {
        #expect(DisplayUnit.single(3).pageRangeText == "3")
        #expect(DisplayUnit.spread(left: nil, right: 1).pageRangeText == "1")
        #expect(DisplayUnit.spread(left: 2, right: 3).pageRangeText == "2–3")
        #expect(DisplayUnit.spread(left: 3, right: 2).pageRangeText == "2–3")
    }

    @Test("紙の絵は、ページ番号が 4 桁でも 1 枚あたり 幅 22・高さ 31pt のまま")
    func glyphKeepsItsSizeForLongNumbers() {
        for unit in [DisplayUnit.single(9999), .spread(left: 9998, right: 9999), .spread(left: nil, right: 1)] {
            let size = NSHostingView(rootView: SpreadGlyph(unit: unit)).fittingSize
            #expect(size == CGSize(width: 22 * CGFloat(unit.visualPages.count), height: 31), "\(unit)")
        }
    }

    @Test("ページが 10・100・1000 を超えても、組み地図は吹き出しの幅に収まる", arguments: [12, 120, 1500])
    func stripFitsThePopover(pageCount: Int) {
        for layout in [ViewOptions.Layout.single, .spread] {
            let units = units(pageCount, layout, cover: true)
            let tileWidth = SpreadMap.tileWidth(for: units)
            let capacity = SpreadMap.capacity(unitCount: units.count, width: popoverWidth, tileWidth: tileWidth)
            let tiles = CGFloat(capacity) * tileWidth + CGFloat(max(capacity - 1, 0)) * SpreadMap.spacing
            let ellipses = capacity < units.count ? 2 * (SpreadMap.ellipsisWidth + SpreadMap.spacing) : 0
            #expect(tiles + ellipses <= popoverWidth, "\(pageCount) pages, \(layout)")
            // Even four-digit spreads leave the current unit some neighbours on either side.
            #expect(capacity >= 4, "\(pageCount) pages, \(layout)")
        }
    }

    @Test("ページの多い文書でも、組み地図には今の組が入る")
    func stripShowsTheCurrentUnit() throws {
        let units = units(1500, .spread, cover: true)
        let capacity = SpreadMap.capacity(
            unitCount: units.count, width: popoverWidth, tileWidth: SpreadMap.tileWidth(for: units))
        let current = try #require(SpreadLayout.unitIndex(containing: 1001, in: units))
        let range = SpreadLayout.visibleRange(unitCount: units.count, current: current, capacity: capacity)
        #expect(range.contains(current))
        #expect(range.count == capacity)
    }

    @Test("すべての組が入るときは、省略の印の場所を取らない")
    func shortDocumentsUseTheWholeStrip() {
        let units = units(12, .spread, cover: true)
        #expect(SpreadMap.capacity(unitCount: units.count, width: popoverWidth, tileWidth: 44) == units.count)
    }
}

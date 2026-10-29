import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct SpreadMapTests {
    /// The view options popover is 460 pt wide with 16 pt of padding on either side.
    private let popoverWidth: CGFloat = 428

    private func units(_ pageCount: Int, _ layout: ViewOptions.Layout, cover: Bool) -> [DisplayUnit] {
        SpreadLayout.units(pageCount: pageCount, layout: layout, showsCoverAlone: cover, direction: .leftToRight)
    }

    @Test("組み地図のタイルは、その文書でいちばん長い番号も折り返さずに収める", arguments: [9, 99, 999, 9999])
    func tilesHoldTheLongestLabel(pageCount: Int) {
        for layout in [ViewOptions.Layout.single, .spread] {
            for cover in [false, true] {
                let units = units(pageCount, layout, cover: cover)
                let tileWidth = SpreadMap.tileWidth(for: units)
                let widest =
                    units.map { unit in
                        (unit.compactText as NSString).size(withAttributes: [.font: SpreadMap.font]).width
                    }.max() ?? 0
                #expect(widest <= tileWidth, "\(pageCount) pages, \(layout), cover \(cover)")
            }
        }
    }

    @Test("描画したタイルの番号は、ページが 10・100・1000 を超えてもタイルの幅に収まる", arguments: [12, 120, 1500])
    func renderedLabelsFitTheTiles(pageCount: Int) throws {
        for layout in [ViewOptions.Layout.single, .spread] {
            let units = units(pageCount, layout, cover: false)
            let widest = try #require(units.last?.compactText)
            let label = NSHostingView(rootView: SpreadMapLabel(text: widest))
            // The tile keeps 4 pt on either side of its label.
            #expect(label.fittingSize.width + 8 <= SpreadMap.tileWidth(for: units), "\(widest)")
            #expect(label.fittingSize.height < SpreadMap.tileHeight, "\(widest)")
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
        #expect(SpreadMap.capacity(unitCount: units.count, width: popoverWidth, tileWidth: 40) == units.count)
    }
}

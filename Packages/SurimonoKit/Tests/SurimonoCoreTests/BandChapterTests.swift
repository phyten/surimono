import CoreGraphics
import SurimonoCore
import Testing

struct BandChapterTests {
    @Test("今の章は上下配置の下右でページ表示の直前に置く")
    func splitPlacement() {
        #expect(
            BandArrangement.standard(for: .split).bottomRight == [
                .part(.chapter), .part(.pageIndicator), .part(.pageTurn),
            ])
    }

    @Test("今の章は上だけ配置でページ表示の直後に置く")
    func topPlacement() {
        #expect(
            BandArrangement.standard(for: .top).topLeft == [
                .part(.formatBadge), .part(.pageIndicator), .part(.chapter),
            ])
    }

    @Test("今の章は上下どちらでも既存のすべての部品より先に外れる", arguments: [false, true])
    func removal(bottom: Bool) throws {
        let items = BandLayout.Item.allCases
        let layout = BandArrangement(topRight: bottom ? [] : items, bottomRight: bottom ? items : [])
        let measurements = BandMeasurementsValue(
            items: Dictionary(uniqueKeysWithValues: items.map { ($0, BandLayout.Widths(full: 20)) }), name: 0)
        let result = BandLayout.resolve(
            arrangement: layout, mode: .split, availableItems: Set(items), measurements: measurements,
            metrics: .init(topFixed: 0, bottomFixed: 0, separator: 0, titleGap: 0, toolGap: 0, outerGap: 0),
            availableWidth: CGFloat(items.count * 20 - 1))
        #expect(result.overflow == [.chapter])
        let row = try #require(bottom ? result.bottom : result.top)
        #expect(row.forms.count == items.count - 1)
    }

    @Test("旧配置に今の章がなくても配置を変えず追加できる部品へ入れる", arguments: MenuArrangement.allCases)
    func upgrade(mode: MenuArrangement) {
        let old = BandArrangement.standard(for: mode, knownItems: BandLayout.Item.allCases.filter { $0 != .chapter })
        let result = BandArrangementRepair.repair(StoredBandArrangement(old), for: mode)
        #expect(result.arrangement.topLeft == old.topLeft)
        #expect(result.arrangement.topRight == old.topRight)
        #expect(result.arrangement.bottomLeft == old.bottomLeft)
        #expect(result.arrangement.bottomRight == old.bottomRight)
        #expect(result.arrangement.unused == old.unused + [.chapter])
        #expect(result.notices == [.addedToUnused(.chapter)])
    }

    @Test("旧設定で目次を外した配置には今の章も置かない")
    func previous() {
        let layouts = BandArrangementStore.previousArrangement(named: "Previous").activeLayouts
        #expect(layouts.top.location(of: .chapter) == .unused)
        #expect(layouts.split.location(of: .chapter) == .unused)
    }
}

import Foundation
import SurimonoCore
import Testing

struct PageTrackTests {
    @Test("二千ページも全幅で等間隔に対応し、両端を越えたら止まる")
    func linear() {
        let track = PageTrack(count: 2000, rightToLeft: false)
        #expect(track.page(at: -1) == 0)
        #expect(track.page(at: 0.5) == 1000)
        #expect(track.page(at: 2) == 1999)
        for page in 0..<track.count { #expect(track.page(at: track.fraction(for: page)) == page) }
        #expect(PageTrack(count: 0, rightToLeft: true).page(at: 0) == nil)
        #expect(PageTrack(count: 1, rightToLeft: false).page(at: 1) == 0)
    }

    @Test("右から読むときは章の目盛りも反転し、8pt未満の隣接する章を省く")
    func ticks() {
        let track = PageTrack(count: 101, rightToLeft: true)
        #expect(track.page(at: 1) == 0)
        #expect(track.page(at: 0) == 100)
        #expect(track.ticks(chapters: [100, 1, 8, 0, 0, -1, 101], width: 100) == [100, 92, 0])
        #expect(track.ticks(chapters: [], width: 100).isEmpty)
    }

    @Test("見本は左右に12ptを残し、横長の紙と低い窓でも縦横比を保つ")
    func preview() {
        #expect(PageTrack.previewCenter(pointer: 15, width: 160, window: 400) == 92)
        #expect(PageTrack.previewCenter(pointer: 395, width: 160, window: 400) == 308)
        #expect(PageTrack.previewCenter(pointer: 214, width: 160, window: 400) == 214)
        #expect(
            PageTrack.previewPaper(aspect: 2, available: CGSize(width: 400, height: 400))
                == CGSize(width: 210, height: 105))
        #expect(
            PageTrack.previewPaper(aspect: 0.5, available: CGSize(width: 400, height: 100))
                == CGSize(width: 50, height: 100))
    }

    @Test("余り幅120ptで下の帯に現れ、それ未満では既存の配置も省略メニューも変わらない")
    func fitsBeforeAnyCollapse() throws {
        let layout = BandArrangement.standard(for: .split)
        let items = Set(BandLayout.Item.allCases)
        let measurements = BandMeasurementsValue(
            items: Dictionary(uniqueKeysWithValues: items.map { ($0, .init(full: 32, compact: 16)) }), name: 80)
        func plan(_ width: CGFloat, _ scrubber: CGFloat?) -> BandResolvedPlan {
            var measured = measurements
            measured.scrubber = scrubber
            return BandLayout.resolve(
                arrangement: layout, mode: .split, availableItems: items, measurements: measured,
                metrics: .init(topFixed: 80, bottomFixed: 28, separator: 9), availableWidth: width)
        }
        let full = try #require(plan(2000, nil).bottom)
        let width = full.requiredWidth + 120
        let wide = plan(width, 120)
        #expect(wide.bottom?.showsScrubber == true)
        #expect(wide.top.showsScrubber == false)
        #expect(wide.bottom?.forms == full.forms)
        for smaller in [width - 1, full.requiredWidth, full.requiredWidth - 1, 120] {
            #expect(plan(smaller, 120) == plan(smaller, nil))
        }
    }
}

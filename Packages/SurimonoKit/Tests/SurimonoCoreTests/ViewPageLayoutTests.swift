import Foundation
import SurimonoCore
import Testing

struct ViewPageLayoutTests {
    @Test("見開きは表紙と端数を白紙で補い論理ページとの対応を保つ", arguments: [false, true], [0, 1, 2, 3, 4, 5])
    func mapping(cover: Bool, count: Int) {
        let options = ViewOptions(layout: .spread, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: cover)
        let plan = ViewPageLayout(pageCount: count, options: options, hasLogicalMargins: true, showsNumbers: true)
        #expect(plan.logicalIndices.count.isMultiple(of: 2))
        #expect(plan.logicalIndices.compactMap { $0 } == Array(0..<count))
        for index in 0..<count {
            #expect(plan.viewIndex(for: index) == index + (cover ? 1 : 0))
        }
        for index in plan.logicalIndices.indices {
            #expect(plan.readingIndex(at: index) != nil)
            if plan.logicalIndex(at: index) == nil { #expect(plan.number(at: index) == nil) }
        }
        #expect(plan.readingIndex(at: -1) == nil)
        #expect(plan.readingIndex(at: plan.logicalIndices.count) == nil)
    }

    @Test("表紙と末尾の白紙は左右の向きによらず読む順序を保つ", arguments: ViewOptions.Direction.allCases)
    func sides(direction: ViewOptions.Direction) {
        var options = ViewOptions(
            layout: .spread, direction: direction, scrollAxis: .horizontal, transition: .instant, showsCoverAlone: false
        )
        #expect(
            ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: false, showsNumbers: true)
                .logicalIndices == [0, 1, 2, nil])
        options.showsCoverAlone = true
        let plan = ViewPageLayout(pageCount: 4, options: options, hasLogicalMargins: false, showsNumbers: true)
        #expect(plan.logicalIndices == [nil, 0, 1, 2, 3, nil])
        #expect(plan.readingIndex(at: 0) == 0)
        #expect(plan.readingIndex(at: 5) == 3)
        #expect(plan.number(at: 1) == 1)
        #expect(plan.number(at: 4) == 4)
    }

    @Test("見開きのどちらを現在ページとしても読む順の先頭と隣の見開きを返す", arguments: ViewOptions.Direction.allCases, [false, true])
    func readingPosition(direction: ViewOptions.Direction, cover: Bool) {
        let options = ViewOptions(
            layout: .spread, direction: direction, scrollAxis: .horizontal, transition: .instant,
            showsCoverAlone: cover)
        let plan = ViewPageLayout(
            pageCount: cover ? 4 : 5, options: options, hasLogicalMargins: false, showsNumbers: false)
        let current: [Int?] = cover ? [0, 0, 1, 1, 3, 3] : [0, 0, 2, 2, 4, 4]
        let next: [Int?] = cover ? [1, 1, 3, 3, nil, nil] : [2, 2, 4, 4, nil, nil]
        let previous: [Int?] = cover ? [nil, nil, 0, 0, 1, 1] : [nil, nil, 0, 0, 2, 2]
        for index in 0..<6 {
            #expect(plan.readingIndex(at: index) == current[index])
            #expect(plan.adjacentReadingIndex(at: index, forward: true) == next[index])
            #expect(plan.adjacentReadingIndex(at: index, forward: false) == previous[index])
        }
        // Exact page lookup is still used for links and numbering, not normalized to the spread.
        #expect(plan.logicalIndex(at: 3) == (cover ? 2 : 3))
        #expect(plan.viewIndex(for: 2) == (cover ? 3 : 2))
        #expect(plan.adjacentReadingIndex(at: -1, forward: true) == nil)
        #expect(plan.adjacentReadingIndex(at: 6, forward: false) == nil)
    }

    @Test("単ページでは奇数インデックスもそのまま報告して一ページずつ移動する")
    func singleReadingPosition() {
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: true)
        let plan = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false)
        #expect(plan.readingIndex(at: 1) == 1)
        #expect(plan.adjacentReadingIndex(at: 1, forward: true) == 2)
        #expect(plan.adjacentReadingIndex(at: 1, forward: false) == 0)
        #expect(plan.adjacentReadingIndex(at: 0, forward: false) == nil)
        #expect(plan.adjacentReadingIndex(at: 2, forward: true) == nil)
    }

    @Test("連続単ページの境界だけを詰め最初と最後の余白は残す")
    func crops() {
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: true)
        #expect(!plan.crops(at: 0).top && plan.crops(at: 0).bottom)
        #expect(plan.crops(at: 1).top && plan.crops(at: 1).bottom)
        #expect(plan.crops(at: 2).top && !plan.crops(at: 2).bottom)
        #expect(plan.number(at: 0) == nil)
        let single = ViewPageLayout(pageCount: 1, options: options, hasLogicalMargins: true, showsNumbers: true)
        #expect(!single.crops(at: 0).top && !single.crops(at: 0).bottom)
    }

    @Test("単ページ連続送りは結合を切っても番号を隠しPDFと画像は切り取らない", arguments: [false, true])
    func eligibility(join: Bool) {
        let options = ViewOptions(
            layout: .single, scrollAxis: .horizontal, transition: .scroll, showsCoverAlone: false, joinsPages: join)
        let pdf = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: false, showsNumbers: true)
        #expect(!pdf.cropsMargins)
        #expect(!pdf.showsNumbers)
        let text = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: true)
        #expect(text.cropsMargins == join)
        #expect(!text.showsNumbers)
    }

    @Test("表示用PDFのキーは送り方や切り取らない方向変更では変わらない")
    func documentKeys() {
        var options = ViewOptions(layout: .spread, scrollAxis: .vertical, transition: .slide, showsCoverAlone: true)
        func key(_ options: ViewOptions, margin: Double = 42, numbers: Bool = true) -> ViewPageLayout.DocumentKey {
            ViewPageLayout(pageCount: 4, options: options, hasLogicalMargins: true, showsNumbers: numbers)
                .documentKey(margin: margin)
        }
        let original = key(options)
        options.transition = .fade
        options.direction = .rightToLeft
        options.scrollAxis = .horizontal
        #expect(key(options) == original)
        #expect(key(options, margin: 20) != original)
        #expect(key(options, numbers: false) != original)
        options.showsCoverAlone = false
        #expect(key(options) != original)
        options.layout = .single
        options.transition = .scroll
        options.scrollAxis = .vertical
        let vertical = key(options)
        options.direction = .leftToRight
        #expect(key(options) == vertical)
        options.scrollAxis = .horizontal
        #expect(key(options) != vertical)
        let horizontal = key(options)
        options.direction = .rightToLeft
        #expect(key(options) != horizontal)
        options.joinsPages = false
        let unjoined = key(options)
        options.scrollAxis = .vertical
        #expect(key(options) == unjoined)
        #expect(key(options, margin: 20) == unjoined)
    }

    @Test("古い設定はページ結合を有効として読み込み無効の設定も往復できる")
    func decoding() throws {
        let data = Data(
            #"{"layout":"single","direction":"leftToRight","scrollAxis":"vertical","transition":"scroll","showsCoverAlone":false}"#
                .utf8)
        var options = try JSONDecoder().decode(ViewOptions.self, from: data)
        #expect(options.joinsPages)
        options.joinsPages = false
        #expect(try JSONDecoder().decode(ViewOptions.self, from: JSONEncoder().encode(options)) == options)
    }
}

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

    @Test("つないだページは、刷るヘッダーやフッターの文字がある側の余白だけを残し、ない側は今までどおり詰める")
    func keepsMarginsWithFurniture() {
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        typealias Edges = ViewPageLayout.CropEdges
        // Page numbers only: the bottom margins stay, the top ones are cut at the seams.
        let numbers = ViewPageLayout(
            pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false,
            keptEdges: [0: Edges(bottom: true), 1: Edges(bottom: true), 2: Edges(bottom: true)])
        #expect(numbers.crops(at: 0) == Edges(top: false, bottom: false))
        #expect(numbers.crops(at: 1) == Edges(top: true, bottom: false))
        #expect(numbers.crops(at: 2) == Edges(top: true, bottom: false))
        // A header and a footer keep both; a page without them is cut as before.
        let mixed = ViewPageLayout(
            pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false,
            keptEdges: [1: Edges(top: true, bottom: true)])
        #expect(mixed.crops(at: 0) == Edges(top: false, bottom: true))
        #expect(mixed.crops(at: 1) == Edges(top: false, bottom: false))
        #expect(mixed.crops(at: 2) == Edges(top: true, bottom: false))
        // Without a header or footer the plan, and so the copy of the pages, is the one it was.
        let none = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false)
        let empty = ViewPageLayout(
            pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false, keptEdges: [:])
        #expect(none.documentKey(margin: 42) == empty.documentKey(margin: 42))
        #expect(none.documentKey(margin: 42) != numbers.documentKey(margin: 42))
    }

    @Test("単ページ連続送りは結合を切っても番号を隠しPDFと画像は切り取らない", arguments: [false, true])
    func eligibility(join: Bool) {
        let options = ViewOptions(
            layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false, joinsPages: join)
        let pdf = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: false, showsNumbers: true)
        #expect(!pdf.cropsMargins)
        #expect(!pdf.showsNumbers)
        let text = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: true)
        #expect(text.cropsMargins == join)
        #expect(!text.showsNumbers)
    }

    @Test("横スクロールは結合の設定によらず左右の余白を残す", arguments: ViewOptions.Direction.allCases)
    func horizontalKeepsMargins(direction: ViewOptions.Direction) {
        let options = ViewOptions(
            layout: .single, direction: direction, scrollAxis: .horizontal, transition: .scroll,
            showsCoverAlone: false, joinsPages: true)
        let plan = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false)
        #expect(!plan.cropsMargins)
        #expect(!plan.crops(at: 1).top && !plan.crops(at: 1).bottom)
        #expect(!options.canJoinPages)
    }

    @Test("ページの結合を選べるのは単ページの縦スクロールだけ")
    func joinablePages() {
        var options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        #expect(options.canJoinPages)
        options.transition = .slide
        #expect(!options.canJoinPages)
        options.transition = .scroll
        options.layout = .spread
        #expect(!options.canJoinPages)
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
        #expect(key(options) == horizontal)
        options.joinsPages = false
        let unjoined = key(options)
        #expect(unjoined == horizontal)
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

    @Test("縦スクロールの結合では途中のページの未使用の下端を詰め、満杯のページと最終ページは維持する")
    func trimsUnusedBottomOnNonFinalPages() {
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        // Page 0 ends early at y = 300; page 1 is full down to y = 45; page 2 is the last page ending at y = 500.
        let plan = ViewPageLayout(
            pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false,
            contentBottoms: [0: 300, 1: 45, 2: 500])
        #expect(plan.trimmableBottomPages == [0, 1])
        // 300 - 10 (seamTrailingPadding) = 290
        #expect(plan.cropInsets(at: 0, pageHeight: 842, margin: 42) == ViewPageLayout.CropInsets(top: 0, bottom: 290))
        // 45 - 10 = 35 <= 42, so the full page keeps the regular 42 pt bottom margin crop.
        #expect(plan.cropInsets(at: 1, pageHeight: 842, margin: 42) == ViewPageLayout.CropInsets(top: 42, bottom: 42))
        // The last page keeps its full bottom untouched.
        #expect(plan.cropInsets(at: 2, pageHeight: 842, margin: 42) == ViewPageLayout.CropInsets(top: 42, bottom: 0))
    }

    @Test("フッターがあるページは下端の未使用領域を詰めない")
    func footerPreventsBottomTrimming() {
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        typealias Edges = ViewPageLayout.CropEdges
        let plan = ViewPageLayout(
            pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false,
            keptEdges: [0: Edges(bottom: true), 1: Edges(top: true)],
            contentBottoms: [0: 400, 1: 400])
        #expect(plan.trimmableBottomPages == [1])
        #expect(plan.cropInsets(at: 0, pageHeight: 842, margin: 42) == ViewPageLayout.CropInsets(top: 0, bottom: 0))
        #expect(plan.cropInsets(at: 1, pageHeight: 842, margin: 42) == ViewPageLayout.CropInsets(top: 0, bottom: 390))
    }

    @Test("見開きや横スクロールや結合オフや余白なし文書は下端を詰めない")
    func bottomTrimAppliesOnlyToJoinedVerticalScroll() {
        let cases: [(ViewOptions, Bool)] = [
            (ViewOptions(layout: .spread, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false), true),
            (ViewOptions(layout: .single, scrollAxis: .horizontal, transition: .scroll, showsCoverAlone: false), true),
            (ViewOptions(layout: .single, scrollAxis: .vertical, transition: .slide, showsCoverAlone: false), true),
            (
                ViewOptions(
                    layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false,
                    joinsPages: false),
                true
            ),
            (ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false), false),
        ]
        for (options, hasMargins) in cases {
            let plan = ViewPageLayout(
                pageCount: 3, options: options, hasLogicalMargins: hasMargins, showsNumbers: false,
                contentBottoms: [0: 400, 1: 400])
            #expect(plan.trimmableBottomPages.isEmpty)
            #expect(plan.cropInsets(at: 0, pageHeight: 842, margin: 42) == ViewPageLayout.CropInsets())
            #expect(plan.cropInsets(at: 1, pageHeight: 842, margin: 42) == ViewPageLayout.CropInsets())
        }
    }

    @Test("白紙ページは通常の余白切り取りを保ち上端付近の本文は可視高さを1pt以上残す")
    func blankAndNearTopBottomTrimBounds() {
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        // Page 0 is blank (omitted from contentBottoms); page 1 has content at the very top edge.
        let plan = ViewPageLayout(
            pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false,
            contentBottoms: [1: 840])
        #expect(plan.cropInsets(at: 0, pageHeight: 842, margin: 42) == ViewPageLayout.CropInsets(top: 0, bottom: 42))
        // Maximum bottom inset on page 1 is 842 - 42 (top) - 1 = 799.
        #expect(plan.cropInsets(at: 1, pageHeight: 842, margin: 42) == ViewPageLayout.CropInsets(top: 42, bottom: 799))
    }

    @Test("余白0でも縦スクロール結合の未使用下端を切り取り表示用PDFキーに反映する")
    func zeroMarginTrimsUnusedBottomAndUpdatesDocumentKey() {
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        let plain = ViewPageLayout(pageCount: 2, options: options, hasLogicalMargins: true, showsNumbers: false)
        let full = ViewPageLayout(
            pageCount: 2, options: options, hasLogicalMargins: true, showsNumbers: false,
            contentBottoms: [0: 45])
        let short = ViewPageLayout(
            pageCount: 2, options: options, hasLogicalMargins: true, showsNumbers: false,
            contentBottoms: [0: 300])
        // Full page produces the exact same key as no contentBottoms at margin 42.
        #expect(full.documentKey(margin: 42) == plain.documentKey(margin: 42))
        #expect(short.documentKey(margin: 42) != plain.documentKey(margin: 42))
        // Even with margin 0, the short page requires a cropped copy and trims 290 pt.
        #expect(!plain.documentKey(margin: 0).requiresCopy)
        #expect(short.documentKey(margin: 0).requiresCopy)
        #expect(short.cropInsets(at: 0, pageHeight: 842, margin: 0) == ViewPageLayout.CropInsets(top: 0, bottom: 290))
    }
}

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

    // MARK: - Sharing the bottom band with the slider

    @Test("スライダーの最小幅に 1 足りなければ、スライダーも今の章も出さない")
    func roomShortOfSlider() {
        #expect(BandLayout.shareChapterRoom(room: 141, scrubber: 142, title: 200, gap: 10) == .init())
    }

    @Test("スライダーの最小幅ちょうどならスライダーだけを出す")
    func roomHoldsSliderOnly() {
        #expect(
            BandLayout.shareChapterRoom(room: 142, scrubber: 142, title: 200, gap: 10)
                == .init(titleWidth: nil, scrubberWidth: 142))
    }

    @Test("スライダーの横に使える幅が 71 なら今の章を出さず、スライダーが全部を使う")
    func titleRoom71() {
        #expect(
            BandLayout.shareChapterRoom(room: 223, scrubber: 142, title: 200, gap: 10)
                == .init(titleWidth: nil, scrubberWidth: 223))
    }

    @Test("スライダーの横に使える幅が 72 なら今の章をその幅で出す")
    func titleRoom72() {
        #expect(
            BandLayout.shareChapterRoom(room: 224, scrubber: 142, title: 200, gap: 10)
                == .init(titleWidth: 72, scrubberWidth: 142))
    }

    @Test("スライダーの横に使える幅が 73 なら今の章を 73 で出す")
    func titleRoom73() {
        #expect(
            BandLayout.shareChapterRoom(room: 225, scrubber: 142, title: 200, gap: 10)
                == .init(titleWidth: 73, scrubberWidth: 142))
    }

    @Test("使える幅が 72 以上なら、名前が短くても長くても出すかどうかは変わらない")
    func decisionIgnoresTitleLength() {
        for title: CGFloat in [20, 72, 300] {
            #expect(BandLayout.shareChapterRoom(room: 224, scrubber: 142, title: title, gap: 10).titleWidth != nil)
            #expect(BandLayout.shareChapterRoom(room: 223, scrubber: 142, title: title, gap: 10).titleWidth == nil)
        }
    }

    @Test("160 を超える名前は 160 の枠に収め、残りはスライダーが使う")
    func longTitleCapped() {
        #expect(
            BandLayout.shareChapterRoom(room: 600, scrubber: 142, title: 161, gap: 10)
                == .init(titleWidth: 160, scrubberWidth: 430))
    }

    @Test("160 に収まる名前は実際の幅で出し、そのぶんスライダーが広い")
    func shortTitleActualWidth() {
        #expect(
            BandLayout.shareChapterRoom(room: 600, scrubber: 142, title: 160, gap: 10)
                == .init(titleWidth: 160, scrubberWidth: 430))
        #expect(
            BandLayout.shareChapterRoom(room: 600, scrubber: 142, title: 50, gap: 10)
                == .init(titleWidth: 50, scrubberWidth: 540))
    }

    @Test("章の部品の縁の幅は今の章の枠から引く")
    func chromeComesOffTheFrame() {
        #expect(
            BandLayout.shareChapterRoom(room: 240, scrubber: 142, title: 200, chrome: 16, gap: 10)
                == .init(titleWidth: 72, scrubberWidth: 142))
        #expect(
            BandLayout.shareChapterRoom(room: 239, scrubber: 142, title: 200, chrome: 16, gap: 10)
                == .init(titleWidth: nil, scrubberWidth: 239))
    }

    @Test("1 ページの文書ではスライダーなしで同じ規則に従う")
    func withoutSlider() {
        #expect(BandLayout.shareChapterRoom(room: 81, scrubber: nil, title: 200, gap: 10) == .init())
        #expect(BandLayout.shareChapterRoom(room: 82, scrubber: nil, title: 200, gap: 10) == .init(titleWidth: 72))
        #expect(BandLayout.shareChapterRoom(room: 500, scrubber: nil, title: 300, gap: 10) == .init(titleWidth: 160))
        #expect(BandLayout.shareChapterRoom(room: 500, scrubber: nil, title: 90, gap: 10) == .init(titleWidth: 90))
    }

    @Test("最初の章より前で名前が空なら、場所をスライダーに渡す")
    func emptyTitle() {
        #expect(
            BandLayout.shareChapterRoom(room: 600, scrubber: 142, title: 0, gap: 10)
                == .init(titleWidth: nil, scrubberWidth: 600))
    }

    private func bottomRow(available: CGFloat, title: CGFloat, scrubber: CGFloat? = 142) throws -> BandRowPlan {
        // An order of its own, so that the row spaces by neighbours: the chapter brings the 10 before the pages.
        let layout = BandArrangement(bottomLeft: [.margins], bottomRight: [.chapter, .pageIndicator])
        let plan = BandLayout.resolve(
            arrangement: layout, mode: .split, availableItems: [.margins, .chapter, .pageIndicator],
            measurements: .init(
                items: [
                    .margins: .init(full: 90, compact: 40), .chapter: .init(full: 196),
                    .pageIndicator: .init(full: 50),
                ], name: 0, scrubber: scrubber, chapterTitle: title, chapterChrome: 16),
            metrics: .init(topFixed: 0, bottomFixed: 28, separator: 9, titleGap: 6, toolGap: 8, outerGap: 10),
            availableWidth: available)
        return try #require(plan.bottom)
    }

    @Test("下の帯の長い章はスライダーを残したまま 160 の枠で省き、短い章ではスライダーが広い")
    func bottomBandLongAndShortTitles() throws {
        // The row without the chapter: 28 fixed, 90 margins, 50 pages. The chapter brings 16 of chrome and a 10 gap.
        let long = try bottomRow(available: 700, title: 400)
        #expect(long.showsScrubber && long.chapterTitleWidth == 160)
        #expect(long.forms == [.margins: .full, .chapter: .full, .pageIndicator: .full])
        #expect(long.requiredWidth == 496)  // 28 + 90 + 50 + 16 + 160 + 10 + 142
        let short = try bottomRow(available: 700, title: 40)
        #expect(short.showsScrubber && short.chapterTitleWidth == 40)
        #expect(short.requiredWidth == 376)  // 28 + 90 + 50 + 16 + 40 + 10 + 142
    }

    @Test("下の帯が狭まると今の章を縮め、外し、スライダーを外してから、ほかの部品を畳む")
    func bottomBandFoldingOrder() throws {
        // 168 for the other parts, 142 for the slider, 26 around the title.
        let narrowTitle = try bottomRow(available: 168 + 142 + 26 + 100, title: 400)
        #expect(narrowTitle.showsScrubber && narrowTitle.chapterTitleWidth == 100)
        let noTitle = try bottomRow(available: 168 + 142 + 26 + 71, title: 400)
        #expect(noTitle.showsScrubber && noTitle.chapterTitleWidth == nil && noTitle.forms[.chapter] == nil)
        let noSlider = try bottomRow(available: 168 + 141, title: 400)
        #expect(!noSlider.showsScrubber && noSlider.forms == [.margins: .full, .pageIndicator: .full])
        let folded = try bottomRow(available: 167, title: 400)
        #expect(!folded.showsScrubber && folded.forms == [.margins: .compact, .pageIndicator: .full])
    }

    @Test("1 ページの文書の下の帯では今の章だけが使える幅の規則に従う")
    func bottomBandWithoutSlider() throws {
        let shown = try bottomRow(available: 168 + 26 + 72, title: 400, scrubber: nil)
        #expect(!shown.showsScrubber && shown.chapterTitleWidth == 72)
        let hidden = try bottomRow(available: 168 + 26 + 71, title: 400, scrubber: nil)
        #expect(hidden.chapterTitleWidth == nil && hidden.forms == [.margins: .full, .pageIndicator: .full])
    }

    @Test("上の帯の今の章は今までどおり測った幅を取り、枠の幅を決めない")
    func topBandKeepsReservation() throws {
        let plan = BandLayout.resolve(
            arrangement: BandArrangement(topLeft: [.formatBadge, .pageIndicator, .chapter]), mode: .top,
            availableItems: [.formatBadge, .pageIndicator, .chapter, .print],
            measurements: .init(
                items: [.formatBadge: .init(full: 30), .pageIndicator: .init(full: 50), .chapter: .init(full: 196)],
                name: 100, chapterTitle: 400, chapterChrome: 16),
            metrics: .init(topFixed: 150, bottomFixed: 28, separator: 9), availableWidth: 2000)
        #expect(plan.top.forms[.chapter] == .full && plan.top.chapterTitleWidth == nil)
    }
}

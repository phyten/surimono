import CoreGraphics
import SurimonoCore
import Testing

struct BandResolvedPlanTests {
    @Test("英語幅の上下の帯は380ptまで収まり、下段は読み方の設定から名前を省く")
    func splitBandWithEnglishLabels() throws {
        var layout = BandLayoutTests.quietSplit
        for item: BandLayout.Item in [.readingDirection, .scrollDirection] {
            layout = try layout.moving(item, to: .zone(.topRight), before: .print, for: .split)
        }
        let widths: [BandLayout.Item: BandLayout.Widths] = [
            .formatBadge: .init(full: 27), .readingDirection: .init(full: 110, compact: 31),
            .scrollDirection: .init(full: 115, compact: 27), .print: .init(full: 80, compact: 43),
            .style: .init(full: 99, compact: 22), .outline: .init(full: 84, compact: 22),
            .layout: .init(full: 56), .readingSettings: .init(full: 128, compact: 22),
        ]
        func plan(at width: CGFloat) -> BandResolvedPlan {
            BandLayout.resolve(
                arrangement: layout, mode: .split, availableItems: Set(widths.keys),
                measurements: .init(items: widths, name: 120),
                metrics: .init(topFixed: 138, bottomFixed: 28, separator: 7, titleGap: 6, toolGap: 6, outerGap: 6),
                availableWidth: width)
        }
        for width in stride(from: CGFloat(760), through: 380, by: -1) {
            let split = plan(at: width)
            let bottom = try #require(split.bottom)
            #expect(split.top.requiredWidth <= width && bottom.requiredWidth <= width)
            #expect(bottom.forms[.readingSettings] == (width >= 426 ? .full : .compact))
            #expect(bottom.forms[.style] == .full && bottom.forms[.outline] == .full)
        }
        let narrow = plan(at: 180)
        #expect(narrow.overflow.contains(.readingSettings))
        #expect(narrow.bottom?.forms == [.style: .compact, .outline: .compact, .layout: .full])
    }

    @Test("画像の束の入口は前の上下配置の標準でも上だけの標準でも目次の位置に来る", arguments: MenuArrangement.allCases)
    func bundlePlacement(mode: MenuArrangement) {
        let original = mode == .split ? BandLayoutTests.quietSplit : BandArrangement.standard(for: .top)
        let placed = original.forImageBundle(in: mode)
        let zone: BandZoneID = mode == .split ? .bottomLeft : .topRight
        #expect(placed[zone].firstIndex(of: .part(.thumbnails)) == original[zone].firstIndex(of: .part(.outline)))
        let plan = BandLayout.resolve(
            arrangement: placed, mode: mode, availableItems: [.thumbnails, .layout],
            measurements: BandMeasurementsValue(
                items: [.thumbnails: .init(full: 70, compact: 30), .layout: .init(full: 80)], name: 80),
            metrics: .init(topFixed: 120, bottomFixed: 20, separator: 9), availableWidth: 800)
        let row = mode == .split ? plan.bottom : plan.top
        #expect(row?.geometry.usesStandardSpacing == true)
    }

    @Test("上下配置の標準は名前を付けて保存した並びと同じく隣り合う部品で間隔を決める")
    func splitStandardSpacing() throws {
        let plan = BandLayout.resolve(
            arrangement: .standard(for: .split), mode: .split, availableItems: Set(BandLayout.Item.allCases),
            measurements: .init(items: [:], name: 0), metrics: .init(topFixed: 0, bottomFixed: 0, separator: 9),
            availableWidth: 2000)
        let bottom = try #require(plan.bottom)
        #expect(!plan.top.geometry.usesStandardSpacing && !bottom.geometry.usesStandardSpacing)
        #expect(
            plan.top.geometry.gapsBefore == [
                .formatBadge: 6, .selectText: 0, .layout: 8, .zoom: 8, .viewOptions: 8, .print: 10,
            ])
        #expect(plan.top.geometry.separatorsBefore == [.layout, .viewOptions])
        #expect(plan.top.geometry.moreDock == .beforePrint && plan.top.geometry.moreGap == 8)
        #expect(
            bottom.geometry.gapsBefore == [
                .presentation: 0, .style: 8, .readingSettings: 8, .outline: 8, .thumbnails: 8, .chapter: 0,
                .pageIndicator: 10, .pageTurn: 10,
            ])
        #expect(bottom.geometry.separatorsBefore == [.style, .outline])
        #expect(plan.overflow == [])
    }

    @Test("上下配置の標準は Markdown で出ない部品が抜けても区切りを重ねず端にも残さない")
    func splitStandardWithoutMarkdownParts() throws {
        let available = Set(BandLayout.Item.allCases).subtracting([.presentation, .thumbnails, .zoom])
        let plan = BandLayout.resolve(
            arrangement: .standard(for: .split), mode: .split, availableItems: available,
            measurements: .init(items: [:], name: 0), metrics: .init(topFixed: 0, bottomFixed: 0, separator: 9),
            availableWidth: 2000)
        let bottom = try #require(plan.bottom)
        #expect(plan.top.trailing == [.selectText, .layout, .viewOptions, .print])
        #expect(plan.top.geometry.separatorsBefore == [.layout, .viewOptions])
        #expect(bottom.leading == [.style, .readingSettings, .outline])
        #expect(bottom.geometry.separatorsBefore == [.outline])
        #expect(bottom.geometry.gapsBefore[.style] == 0)
    }

    @Test("画像の束では上下配置の標準のページ一覧が目次の位置に来て、前に区切りを残さない")
    func splitStandardForImageBundle() throws {
        let placed = BandArrangement.standard(for: .split).forImageBundle(in: .split)
        #expect(
            placed.bottomLeft == [
                .part(.presentation), .separator, .part(.style), .part(.readingSettings), .separator,
                .part(.thumbnails), .part(.outline),
            ])
        let plan = BandLayout.resolve(
            arrangement: placed, mode: .split, availableItems: [.layout, .zoom, .viewOptions, .thumbnails, .print],
            measurements: .init(items: [:], name: 0), metrics: .init(topFixed: 0, bottomFixed: 0, separator: 9),
            availableWidth: 2000)
        let bottom = try #require(plan.bottom)
        #expect(plan.top.trailing == [.layout, .zoom, .viewOptions, .print])
        #expect(plan.top.geometry.separatorsBefore == [.viewOptions])
        #expect(bottom.leading == [.thumbnails])
        #expect(bottom.geometry.separatorsBefore == [])
    }

    @Test("カスタムの並びで一覧を置いた場所は画像の束でも保つ")
    func customDrawer() throws {
        let standard = BandLayoutTests.quietSplit
        let custom = try standard.moving(.thumbnails, to: .zone(.topRight), before: .print, for: .split)
        #expect(custom.forImageBundle(in: .split) == custom)
    }

    @Test("印刷の後ろの部品が幅で消えてもその他のドックは印刷の反対側へ移らない")
    func moreDockDoesNotMoveOnCollapse() {
        let layout = BandArrangement(topRight: [.print, .style])
        let wide = resolve(layout, width: 1000)
        let narrow = resolve(layout, width: 1)
        #expect(wide.top.trailing == [.print, .style])
        #expect(narrow.top.trailing == [.print])
        #expect(wide.top.geometry.moreDock == .trailing && narrow.top.geometry.moreDock == .trailing)
    }

    @Test("画像の束では実測したページ入口の幅で線を畳み、章を外す前に入口をアイコンにする")
    func bundleDrawerFolds() {
        let layout = BandArrangement(bottomLeft: [.thumbnails], bottomRight: [.chapter, .pageIndicator])
        func plan(_ width: CGFloat) -> BandRowPlan? {
            BandLayout.resolve(
                arrangement: layout, mode: .split, availableItems: [.thumbnails, .chapter, .pageIndicator],
                measurements: .init(
                    items: [
                        .thumbnails: .init(full: 75, compact: 28), .chapter: .init(full: 40),
                        .pageIndicator: .init(full: 32),
                    ], name: 0, scrubber: 120),
                metrics: .init(topFixed: 0, bottomFixed: 0, separator: 0, titleGap: 0, toolGap: 0, outerGap: 0),
                availableWidth: width
            ).bottom
        }
        #expect(plan(267)?.showsScrubber == true)
        #expect(plan(266)?.showsScrubber == false)
        #expect(plan(147)?.forms[.thumbnails] == .full)
        #expect(plan(100)?.forms == [.thumbnails: .compact, .chapter: .full, .pageIndicator: .full])
        #expect(plan(99)?.forms == [.thumbnails: .compact, .pageIndicator: .full])
    }

    @Test("目次を外した旧配置も標準の隙間を保ち名前や他の部品を動かさない")
    func migratedSpacing() {
        let layouts = BandArrangementStore.previousArrangement(named: "Previous").activeLayouts
        let metrics = BandMetrics(topFixed: 150, bottomFixed: 28, separator: 9)
        let top = BandLayout.resolve(
            arrangement: layouts.top, mode: .top,
            availableItems: Set(BandLayout.Item.allCases.filter { $0 != .chapter && $0 != .readingSettings }),
            measurements: .init(items: BandLayoutTests.workedWidths, name: 120), metrics: metrics, availableWidth: 2000)
        let split = BandLayout.resolve(
            arrangement: layouts.split, mode: .split,
            availableItems: Set(BandLayout.Item.allCases.filter { $0 != .chapter && $0 != .readingSettings }),
            measurements: .init(items: BandLayoutTests.workedWidths, name: 120), metrics: metrics, availableWidth: 2000)
        #expect(top.top.geometry.usesStandardSpacing && split.bottom?.geometry.usesStandardSpacing == true)
        #expect(top.top.requiredWidth == 1002 && split.bottom?.requiredWidth == 679)
        #expect(
            top.unusedAvailable == [.outline, .showOnAllSpaces, .pageTurn] + BandLayoutTests.addedItems
                && split.unusedAvailable == [.outline, .showOnAllSpaces] + BandLayoutTests.addedItems)
    }

    private let metrics = BandMetrics(
        topFixed: 150, bottomFixed: 30, separator: 10, titleGap: 0, toolGap: 0, outerGap: 0)

    private func resolve(_ layout: BandArrangement, mode: MenuArrangement = .split, width: CGFloat) -> BandResolvedPlan
    {
        BandLayout.resolve(
            arrangement: layout, mode: mode,
            availableItems: Set(BandLayout.Item.allCases.filter { $0 != .chapter && $0 != .readingSettings }),
            measurements: BandMeasurementsValue(items: BandLayoutTests.workedWidths, name: 120),
            metrics: metrics, availableWidth: width)
    }

    @Test("新しい計画も上だけの標準と前の上下配置の標準の三つの幅で固定済みの表示形と名前幅を返す", arguments: [1000, 650, 250])
    func workedExamples(width: Int) throws {
        let top = resolve(.standard(for: .top), mode: .top, width: CGFloat(width))
        let split = resolve(BandLayoutTests.quietSplit, width: CGFloat(width))
        let bottom = try #require(split.bottom)
        #expect(top.bottom == nil)
        #expect(
            top.unusedAvailable == [.transition, .floatOnTop, .showOnAllSpaces, .pageTurn] + BandLayoutTests.addedItems)
        #expect(split.unusedAvailable == BandLayoutTests.standardUnused)
        switch width {
        case 1000:
            #expect(top.top.leading == [.formatBadge, .pageIndicator])
            #expect(
                top.top.trailing == [
                    .presentation, .style, .outline, .layout, .zoom, .thumbnails, .print,
                ])
            #expect(top.top.forms.count == 9 && top.top.forms.values.allSatisfy { $0 == .full })
            #expect(top.top.nameWidth == 120 && top.overflow == [])
            #expect(split.top.forms == [.formatBadge: .full, .print: .full])
            #expect(bottom.forms.count == 8 && bottom.forms.values.allSatisfy { $0 == .full })
            #expect(split.top.nameWidth == 120 && split.overflow == [])
        case 650:
            #expect(
                top.top.forms == [
                    .pageIndicator: .full, .presentation: .compact, .style: .compact, .outline: .compact,
                    .layout: .full,
                    .zoom: .full, .thumbnails: .full, .print: .full,
                ])
            #expect(top.top.nameWidth == 90 && top.overflow == [.formatBadge])
            #expect(split.top.forms == [.formatBadge: .full, .print: .full])
            #expect(split.top.nameWidth == 120 && split.overflow == [])
            #expect(
                bottom.forms == [
                    .presentation: .full, .style: .full, .outline: .full, .layout: .full,
                    .zoom: .full, .thumbnails: .full, .pageIndicator: .full, .pageTurn: .full,
                ])
        default:
            #expect(top.top.forms == [.print: .compact] && top.top.nameWidth == 66)
            #expect(split.top.forms == [.print: .compact] && split.top.nameWidth == 66)
            #expect(bottom.leading == [.presentation, .zoom, .thumbnails])
            #expect(bottom.trailing == [.pageIndicator])
            #expect(bottom.forms == [.presentation: .compact, .zoom: .full, .thumbnails: .full, .pageIndicator: .full])
            #expect(split.overflow == [.formatBadge, .style, .outline, .layout, .pageTurn])
            #expect(
                top.overflow == [
                    .formatBadge, .pageIndicator, .presentation, .style, .outline,
                    .layout, .zoom, .thumbnails,
                ])
        }
        #expect(top.top.minimumWidth == 184 && split.top.minimumWidth == 184 && bottom.minimumWidth == 30)
    }

    @Test("上だけの標準と前の上下配置の標準の実測間隔と予約された隙間はすべての幅で旧入口と一致する", arguments: MenuArrangement.allCases)
    func standardSpacing(mode: MenuArrangement) {
        let layout = mode == .split ? BandLayoutTests.quietSplit : BandArrangement.standard(for: .top)
        let numeric = BandMetrics(topFixed: 150, bottomFixed: 28, separator: 9)
        var spaced = BandLayoutTests.workedWidths
        for item in BandLayout.Item.allCases {
            let gap: CGFloat =
                item == .print ? 0 : (item == .formatBadge || (item == .pageIndicator && mode == .top) ? 6 : 8)
            spaced[item]?.full += gap
            if let compact = spaced[item]?.compact { spaced[item]?.compact = compact + gap }
        }
        // Include every point around all collapse boundaries, including the final filename threshold.
        for width in 0...1200 {
            let result = BandLayout.resolve(
                arrangement: layout, mode: mode,
                availableItems: Set(BandLayout.Item.allCases.filter { $0 != .chapter && $0 != .readingSettings }),
                measurements: .init(items: BandLayoutTests.workedWidths, name: 120), metrics: numeric,
                availableWidth: CGFloat(width))
            let legacyTop = BandLayout.plan(
                widths: spaced.filter { (layout.topLeft + layout.topRight).contains($0.key) },
                fixed: 150, separator: 9, name: 120, available: CGFloat(width))
            #expect(result.top.forms == legacyTop.forms && result.top.nameWidth == legacyTop.nameWidth)
            if mode == .split {
                let legacyBottom = BandLayout.plan(
                    widths: spaced.filter { (layout.bottomLeft + layout.bottomRight).contains($0.key) },
                    fixed: 28, separator: 9, name: 0, available: CGFloat(width), steps: BandLayout.bottomSteps)
                #expect(result.bottom?.forms == legacyBottom.forms)
            }
        }
        let full = BandLayout.resolve(
            arrangement: layout, mode: mode,
            availableItems: Set(BandLayout.Item.allCases.filter { $0 != .chapter && $0 != .readingSettings }),
            measurements: .init(items: BandLayoutTests.workedWidths, name: 120), metrics: numeric, availableWidth: 2000)
        #expect(full.top.geometry.usesStandardSpacing)
        #expect(full.top.geometry.gapsBefore[.formatBadge] == 6)
        #expect(full.top.geometry.gapsBefore[.floatOnTop] == nil)
        #expect(full.top.geometry.gapsBefore[.print] == 0)
        #expect(full.top.geometry.moreDock == .beforePrint)
        #expect(full.top.geometry.fixedWidth == 150)
    }

    @Test("標準の上の帯は拡大率とサムネイルがないときも目次が入る幅まで残す")
    func outlineFitsBesidePrint() {
        let layout = BandArrangement.standard(for: .top)
        let available: Set<BandLayout.Item> = [
            .formatBadge, .pageIndicator, .chapter, .style, .outline, .layout, .print,
        ]
        func row(at width: CGFloat) -> BandRowPlan {
            BandLayout.resolve(
                arrangement: layout, mode: .top, availableItems: available,
                measurements: .init(items: BandLayoutTests.workedWidths, name: 120),
                metrics: .init(topFixed: 153, bottomFixed: 28, separator: 9), availableWidth: width
            ).top
        }
        #expect(row(at: 900).geometry.separatorsBefore == [.layout])
        let fit = row(at: 341)
        #expect(fit.forms == [.outline: .compact, .print: .full])
        #expect(fit.nameWidth == 80 && fit.requiredWidth == 341)
        #expect(fit.geometry.separatorsBefore.isEmpty)
        #expect(row(at: 340).forms == [.print: .full])
    }

    @Test("下へ移した印刷は選んだ位置に残り物理的な帯の順で畳まれる", arguments: [220, 180, 140, 90, 1])
    func movedPrint(width: Int) throws {
        let layout = BandArrangement(
            topRight: [], bottomLeft: [.style, .print], bottomRight: [.floatOnTop, .pageIndicator])
        let plan = BandLayout.resolve(
            arrangement: layout, mode: .split,
            availableItems: Set(BandLayout.Item.allCases.filter { $0 != .chapter && $0 != .readingSettings }),
            measurements: .init(items: BandLayoutTests.workedWidths, name: 120),
            metrics: .init(topFixed: 150, bottomFixed: 30, separator: 0, titleGap: 0, toolGap: 0, outerGap: 0),
            availableWidth: CGFloat(width))
        let bottom = try #require(plan.bottom)
        switch width {
        case 220:
            #expect(bottom.leading == [.style, .print] && bottom.trailing == [.floatOnTop, .pageIndicator])
            #expect(bottom.forms == [.style: .compact, .print: .full, .floatOnTop: .full, .pageIndicator: .full])
            #expect(bottom.requiredWidth == 218)
        case 180:
            #expect(bottom.forms == [.print: .full, .floatOnTop: .full, .pageIndicator: .full])
            #expect(bottom.requiredWidth == 178 && plan.overflow == [.style])
        case 140:
            #expect(bottom.forms == [.print: .full] && bottom.requiredWidth == 100)
            #expect(plan.overflow == [.pageIndicator, .style, .floatOnTop])
        default:
            #expect(bottom.forms == [.print: .compact] && bottom.requiredWidth == 64)
        }
        #expect(bottom.minimumWidth == 64 && plan.top.minimumWidth == 150)
        #expect(
            bottom.leading.last == .print && !plan.overflow.contains(.print) && !plan.unusedAvailable.contains(.print))
        #expect(plan.top.geometry.moreDock == .trailing)
    }

    @Test("明示した区切り線は中間の部品が消えても残る部品の間に一本描く")
    func adjacentGroups() throws {
        let arrangement = BandArrangement(entries: [
            .topRight: [.part(.print)],
            .bottomLeft: [.part(.style), .separator, .part(.layout), .separator, .part(.outline)],
        ])
        let wide = resolve(arrangement, width: 1000)
        #expect(wide.bottom?.geometry.separatorsBefore == [.layout, .outline])
        #expect(wide.bottom?.requiredWidth == 260)
        let compact = resolve(arrangement, width: 259)
        #expect(compact.bottom?.forms == [.style: .compact, .layout: .full, .outline: .full])
        #expect(compact.bottom?.requiredWidth == 210)
        let removed = resolve(arrangement, width: 179)
        #expect(removed.bottom?.leading == [.style, .outline])
        #expect(removed.bottom?.geometry.separatorsBefore == [.outline])
        #expect(removed.bottom?.requiredWidth == 110)
    }

    @Test("区切りを置かなければ群が異なる部品の間にも線を描かない")
    func separatedGroups() {
        let arrangement = BandArrangement(
            topRight: [.print], bottomLeft: [.style, .pageIndicator, .layout], bottomRight: [.outline])
        let plan = resolve(arrangement, width: 1000)
        #expect(plan.bottom?.geometry.separatorsBefore == [])
        #expect(plan.bottom?.geometry.usesStandardSpacing == false)
    }

    @Test("上へ移したページ送りも幅が足りなければメニューへ入る")
    func topPageTurn() throws {
        let arrangement = try BandArrangement.standard(for: .top).moving(.pageTurn, to: .zone(.topLeft), for: .top)
        let wide = resolve(arrangement, mode: .top, width: 2000)
        #expect(wide.top.leading == [.formatBadge, .pageIndicator, .pageTurn])
        let narrow = resolve(arrangement, mode: .top, width: 250)
        #expect(narrow.top.forms == [.print: .compact])
        #expect(narrow.overflow.contains(.pageTurn) && narrow.unusedAvailable == BandLayoutTests.standardUnused)
    }

    @Test("使えない部品と使わない部品と幅で外れた部品を混ぜず印刷を残す")
    func availabilityAndUnused() throws {
        let layout = try BandLayoutTests.quietSplit.moving(.outline, to: .unused, for: .split)
        let plan = BandLayout.resolve(
            arrangement: layout, mode: .split, availableItems: [.style, .outline, .print],
            measurements: .init(items: BandLayoutTests.workedWidths, name: 120), metrics: metrics, availableWidth: 1)
        #expect(plan.unusedAvailable == [.outline])
        #expect(plan.overflow == [.style])
        #expect(plan.top.forms == [.print: .compact])
        #expect(plan.bottom?.forms == [:])
        #expect(
            layout.bottomLeft.compactMap(\.item) == [.presentation, .style, .layout, .zoom, .thumbnails])
    }
}

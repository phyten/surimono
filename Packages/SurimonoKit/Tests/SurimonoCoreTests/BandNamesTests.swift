import CoreGraphics
import SurimonoCore
import Testing

struct BandNamesTests {
    typealias Item = BandLayout.Item

    private let metrics = BandMetrics(topFixed: 0, bottomFixed: 0, separator: 0, titleGap: 0, toolGap: 0, outerGap: 0)

    @Test("アイコンのみでは広い帯でも名前を省き、値と縮小形のない部品を残す")
    func wide() {
        let named: [Item] =
            [
                .presentation, .style, .outline, .transition, .thumbnails, .print,
            ] + BandLayoutTests.addedItems
        let values: [Item] = [.formatBadge, .pageIndicator, .zoom, .chapter]
        let icons: [Item] = [.layout, .floatOnTop, .showOnAllSpaces, .pageTurn]
        // Give even the values a compact measurement: the preference must not abbreviate document information.
        var widths = Dictionary(
            uniqueKeysWithValues: (values + named).map { ($0, BandLayout.Widths(full: 40, compact: 10)) })
        for icon in icons { widths[icon] = .init(full: 20) }
        let plan = BandLayout.resolve(
            arrangement: .init(topLeft: values, topRight: named + icons), mode: .top,
            availableItems: Set(Item.allCases), measurements: .init(items: widths, name: 140),
            metrics: metrics, availableWidth: 3000, names: .hidden)
        #expect(Set(plan.top.forms.keys) == Set(Item.allCases))
        for item in named { #expect(plan.top.forms[item] == .compact) }
        for item in values + icons { #expect(plan.top.forms[item] == .full) }
        #expect(plan.top.nameWidth == 140)
        #expect(plan.top.requiredWidth == 580)
    }

    @Test("形式の詳しい値とファイル名はアイコンの設定によらず同じ幅で縮む")
    func documentValues() {
        let layout = BandArrangement(topLeft: [.formatBadge, .chapter, .pageIndicator, .zoom], topRight: [.print])
        // Equal Print widths isolate the existing width thresholds for the badge, filename and other values.
        let measurements = BandMeasurementsValue(
            items: [
                .formatBadge: .init(full: 110, compact: 18, withoutSuffix: 70), .chapter: .init(full: 100),
                .pageIndicator: .init(full: 40), .zoom: .init(full: 30), .print: .init(full: 20, compact: 20),
            ], name: 110)
        for width in stride(from: 0, through: 440, by: 5) {
            func row(_ names: BandLayout.Names) -> BandRowPlan {
                BandLayout.resolve(
                    arrangement: layout, mode: .top, availableItems: Set(measurements.items.keys),
                    measurements: measurements, metrics: metrics, availableWidth: CGFloat(width), names: names
                ).top
            }
            let hidden = row(.hidden)
            let shown = row(.shown)
            #expect(hidden.nameWidth == shown.nameWidth)
            for item in [Item.formatBadge, .chapter, .pageIndicator, .zoom] {
                #expect(hidden.forms[item] == shown.forms[item])
            }
        }
    }

    @Test("アイコンのみでも幅不足で外れる順は上下それぞれの帯の仕様に従う", arguments: [BandLayout.Position.top, .bottom])
    func removalOrder(position: BandLayout.Position) throws {
        let parts: [Item] = [.style, .transition, .pageIndicator, .chapter, .margins, .print]
        let layout = position == .top ? BandArrangement(topRight: parts) : BandArrangement(bottomRight: parts)
        let removed: [Item] =
            position == .top
            ? [.chapter, .margins, .pageIndicator, .style, .transition]
            : [.chapter, .margins, .transition, .style, .pageIndicator]
        let widths = Dictionary(uniqueKeysWithValues: parts.map { ($0, BandLayout.Widths(full: 10, compact: 10)) })
        for count in 0...removed.count {
            let plan = BandLayout.resolve(
                arrangement: layout, mode: .split, availableItems: Set(parts),
                measurements: .init(items: widths, name: 0), metrics: metrics,
                availableWidth: CGFloat(60 - 10 * count), names: .hidden)
            #expect(Set(plan.overflow) == Set(removed.prefix(count)))
            let row = position == .top ? plan.top : try #require(plan.bottom)
            #expect(row.forms[.print] == .compact)
        }
    }

    @Test("アイコンのみでも下の帯に余裕があればページのスクラバーが出る")
    func scrubber() {
        // The reader's preferred forms use no width-driven collapse at the exact clearance threshold.
        func showsScrubber(_ width: CGFloat) -> Bool? {
            BandLayout.resolve(
                arrangement: .init(bottomLeft: [.style]), mode: .split, availableItems: [.style],
                measurements: .init(items: [.style: .init(full: 75, compact: 30)], name: 0, scrubber: 120),
                metrics: metrics, availableWidth: width, names: .hidden
            ).bottom?.showsScrubber
        }
        #expect(showsScrubber(150) == true)
        #expect(showsScrubber(149) == false)
    }

    @Test("名前の指定を省くと名前を表示する設定と同じ計画になる", arguments: MenuArrangement.allCases)
    func defaultPlans(mode: MenuArrangement) {
        let arrangement = BandArrangement.standard(for: mode)
        let widths = BandLayoutTests.workedWidths
        let measurements = BandMeasurementsValue(items: widths, name: 100, scrubber: 120)
        for width in stride(from: 0, through: 1100, by: 11) {
            let original = BandLayout.resolve(
                arrangement: arrangement, mode: mode, availableItems: Set(widths.keys),
                measurements: measurements, metrics: metrics, availableWidth: CGFloat(width))
            let shown = BandLayout.resolve(
                arrangement: arrangement, mode: mode, availableItems: Set(widths.keys),
                measurements: measurements, metrics: metrics, availableWidth: CGFloat(width), names: .shown)
            #expect(shown == original)
        }
    }
}

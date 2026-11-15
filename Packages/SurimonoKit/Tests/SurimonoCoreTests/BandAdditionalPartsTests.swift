import CoreGraphics
import SurimonoCore
import Testing

struct BandAdditionalPartsTests {
    @Test("二十六部品の保存識別子は旧十二個の順を保ち区切りと衝突しない")
    func catalog() {
        let values = BandLayout.Item.allCases.map(\.rawValue)
        #expect(
            values == [
                "formatBadge", "pageIndicator", "presentation", "style", "outline", "layout", "transition", "zoom",
                "thumbnails", "floatOnTop", "pageTurn", "print", "readingDirection", "scrollDirection",
                "paperOrientation", "paperSeries", "cover", "selectText", "alwaysShowToolbar", "margins",
                "printSettings", "ignoreSlides", "beforePrinting", "viewOptions", "saveAsFile", "keysAndGestures",
            ])
        #expect(Set(values).count == 26)
        #expect(!values.contains("@separator"))
        #expect(BandLayoutTests.addedItems.map(\.group) == [2, 2, 5, 5, 2, 3, 4, 5, 6, 0, 6, 4, 6, 7])
    }

    private let priority: [BandLayout.Item] = [
        .keysAndGestures, .saveAsFile, .ignoreSlides, .printSettings, .margins, .paperSeries,
        .paperOrientation, .cover, .readingDirection, .scrollDirection, .alwaysShowToolbar,
        .viewOptions, .beforePrinting, .selectText,
    ]
    private let oldCompact: [BandLayout.Item] = [.style, .transition, .presentation, .outline]

    private func plan(bottom: Bool, width: CGFloat) -> BandResolvedPlan {
        let items = BandLayoutTests.addedItems + oldCompact + [.print]
        let arrangement = BandArrangement(
            topRight: bottom ? [] : items, bottomRight: bottom ? items : [])
        var widths = Dictionary(uniqueKeysWithValues: items.map { ($0, BandLayout.Widths(full: 100, compact: 20)) })
        widths[.print] = .init(full: 70, compact: 34)
        return BandLayout.resolve(
            arrangement: arrangement, mode: .split, availableItems: Set(items),
            measurements: .init(items: widths, name: 0),
            metrics: .init(topFixed: 24, bottomFixed: 0, separator: 0, titleGap: 0, toolGap: 0, outerGap: 0),
            availableWidth: width)
    }

    @Test("新部品の名前を先に省き文書名を80ptまで縮めてから既存の名前を省く")
    func filenamePriority() {
        let items: [BandLayout.Item] = [.keysAndGestures, .selectText, .style, .print]
        let widths: [BandLayout.Item: BandLayout.Widths] = [
            .keysAndGestures: .init(full: 100, compact: 20), .selectText: .init(full: 100, compact: 20),
            .style: .init(full: 100, compact: 20), .print: .init(full: 70, compact: 34),
        ]
        func row(_ width: CGFloat) -> BandRowPlan {
            BandLayout.resolve(
                arrangement: BandArrangement(topRight: items), mode: .split, availableItems: Set(items),
                measurements: .init(items: widths, name: 160),
                metrics: .init(topFixed: 24, bottomFixed: 0, separator: 0, titleGap: 0, toolGap: 0, outerGap: 0),
                availableWidth: width
            ).top
        }
        #expect(row(554).forms.values.allSatisfy { $0 == .full })
        #expect(row(553).forms[.keysAndGestures] == .compact)
        #expect(row(553).forms[.selectText] == .full)
        #expect(row(553).nameWidth == 160)
        #expect(row(473).forms[.selectText] == .compact)
        #expect(row(473).nameWidth == 160)
        #expect(row(393).nameWidth == 159)
        #expect(row(314).nameWidth == 80)
        #expect(row(314).forms[.style] == .full)
        #expect(row(313).forms[.style] == .compact)
        #expect(row(313).forms.count == 4)
    }

    @Test("上下とも新部品を指定順で縮めてから既存の名前を縮める", arguments: [false, true])
    func compactOrder(bottom: Bool) throws {
        let fixed: CGFloat = bottom ? 0 : 24
        for count in 1...18 {
            let result = plan(bottom: bottom, width: 1870 + fixed - CGFloat(count - 1) * 80 - 1)
            let row = try #require(bottom ? result.bottom : result.top)
            #expect(Set(row.forms.filter { $0.value == .compact }.keys) == Set((priority + oldCompact).prefix(count)))
            #expect(result.overflow.isEmpty)
            #expect(row.forms[.print] == .full)
        }
    }

    @Test("上下とも新部品を指定順で外してから既存の部品を外す", arguments: [false, true])
    func removalOrder(bottom: Bool) throws {
        let fixed: CGFloat = bottom ? 0 : 24
        for count in 1...14 {
            let result = plan(bottom: bottom, width: 430 + fixed - CGFloat(count - 1) * 20 - 1)
            let row = try #require(bottom ? result.bottom : result.top)
            #expect(Set(result.overflow) == Set(priority.prefix(count)))
            #expect(oldCompact.allSatisfy { row.forms[$0] == .compact })
            #expect(row.forms[.print] == .full)
        }
    }

    @Test("新部品を全部置いて印刷を下へ移しても最後は固定の詳細と印刷だけ残る", arguments: [false, true])
    func minimum(bottom: Bool) throws {
        let result = plan(bottom: bottom, width: 1)
        let row = try #require(bottom ? result.bottom : result.top)
        #expect(row.forms == [.print: .compact])
        #expect(result.top.geometry.moreDock != .absent)
        #expect(result.bottom?.geometry.moreDock == .absent)
        #expect(result.top.forms == (bottom ? [:] : [.print: .compact]))
        #expect(result.bottom?.forms == (bottom ? [.print: .compact] : [:]))
        #expect(row.minimumWidth == (bottom ? 34 : 58))
    }
}

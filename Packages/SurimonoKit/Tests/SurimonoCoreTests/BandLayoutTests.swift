import CoreGraphics
import SurimonoCore
import Testing

struct BandLayoutTests {
    /// A Markdown document in a single-page window: every tool of the band except zoom and thumbnails.
    private let markdown: [BandLayout.Item: BandLayout.Widths] = [
        .formatBadge: .init(full: 30),
        .pageIndicator: .init(full: 50),
        .style: .init(full: 90, compact: 40),
        .layout: .init(full: 60),
        .direction: .init(full: 60),
        .scrollAxis: .init(full: 60),
        .transition: .init(full: 100, compact: 40),
        .selectText: .init(full: 110, compact: 30),
        .floatOnTop: .init(full: 30),
        .keepMenuVisible: .init(full: 30),
        .print: .init(full: 70, compact: 34),
    ]
    private let fixed: CGFloat = 150
    private let separator: CGFloat = 10
    private let name: CGFloat = 120

    /// fixed 150 + name 80 + items 690 + three separators 30.
    private let fullWidth: CGFloat = 950

    private func plan(
        _ widths: [BandLayout.Item: BandLayout.Widths]? = nil, available: CGFloat, name: CGFloat? = nil
    ) -> BandLayout.Plan {
        BandLayout.plan(
            widths: widths ?? markdown, fixed: fixed, separator: separator, name: name ?? self.name,
            available: available)
    }

    @Test("すべて入る幅では全部を元の形で帯に出し、ファイル名は元の幅のまま")
    func everythingFits() {
        let result = plan(available: 2000)
        #expect(result.forms.count == markdown.count)
        #expect(result.forms.values.allSatisfy { $0 == .full })
        #expect(result.overflow.isEmpty)
        #expect(result.nameWidth == 120)
    }

    @Test("ファイル名は 80pt まで縮めてから、ほかの物を畳み始める")
    func nameShrinksToItsMinimumFirst() {
        let result = plan(available: fullWidth)
        #expect(result.forms.values.allSatisfy { $0 == .full })
        #expect(result.nameWidth == 80)
    }

    @Test("幅が足りないとまずスタイルの名前を省き、次に送り方の名前、「文字を選択」の文字を省く")
    func labelsGiveWayFirst() {
        #expect(plan(available: fullWidth - 1).forms[.style] == .compact)
        #expect(plan(available: fullWidth - 1).forms[.transition] == .full)
        let withoutStyleName = fullWidth - 50
        #expect(plan(available: withoutStyleName - 1).forms[.transition] == .compact)
        #expect(plan(available: withoutStyleName - 1).forms[.selectText] == .full)
        let withoutLabels = withoutStyleName - 60
        let result = plan(available: withoutLabels - 1)
        #expect(result.forms[.selectText] == .compact)
        #expect(result.overflow.isEmpty)
    }

    @Test("ラベルを省いても足りなければ、メニュー固定・最前面に固定・形式のバッジの順に帯から外す")
    func leastUsedToolsLeaveNext() {
        // Without the labels the band needs 950 - 50 - 60 - 80 = 760.
        #expect(plan(available: 759).overflow == [.keepMenuVisible])
        #expect(plan(available: 730).overflow == [.keepMenuVisible])
        // The second window tool goes, and with it the separator before their group.
        #expect(plan(available: 729).overflow == [.floatOnTop, .keepMenuVisible])
        #expect(plan(available: 690).overflow == [.floatOnTop, .keepMenuVisible])
        #expect(plan(available: 689).overflow == [.formatBadge, .floatOnTop, .keepMenuVisible])
    }

    @Test("帯の外の物は、外した順ではなく帯の並び順で返す")
    func overflowKeepsTheBandOrder() {
        // After the badge the band needs 660: cover is absent, then scrolling, direction and the page indicator leave.
        let result = plan(available: 500)
        #expect(
            result.overflow == [.formatBadge, .pageIndicator, .direction, .scrollAxis, .floatOnTop, .keepMenuVisible])
        #expect(result.forms[.layout] == .full)
        #expect(result.forms[.style] == .compact)
    }

    @Test("文書にない物の手順は飛ばし、ある物だけで畳む")
    func absentItemsAreSkipped() {
        var pdf = markdown
        pdf[.style] = nil
        pdf[.selectText] = nil
        pdf[.cover] = .init(full: 30)
        // fixed 150 + name 80 + items 520 + one separator 10 = 760.
        #expect(plan(pdf, available: 760).overflow.isEmpty)
        let result = plan(pdf, available: 759)
        #expect(result.forms[.transition] == .compact)
        #expect(result.forms[.style] == nil)
        #expect(!result.overflow.contains(.style))
    }

    @Test("どれだけ狭くても「…」と印刷は残り、印刷はアイコンだけになる")
    func printStaysToTheEnd() {
        let result = plan(available: 260)
        #expect(result.forms == [.print: .compact])
        #expect(result.overflow.count == markdown.count - 1)
    }

    @Test("畳み切っても足りない幅はファイル名から削り、24pt 未満なら名前を出さない")
    func nameGivesWayLast() {
        // fixed 150 + print icon 34 leaves 26 for the name at 210 and 16 at 200.
        #expect(plan(available: 210).nameWidth == 26)
        #expect(plan(available: 210).showsName)
        #expect(plan(available: 200).nameWidth == 16)
        #expect(!plan(available: 200).showsName)
    }

    @Test("帯が場所を空ける順は仕様の表のとおり")
    func stepsFollowTheSpecification() {
        #expect(
            BandLayout.steps == [
                .compact(.style), .compact(.transition), .compact(.selectText),
                .remove(.keepMenuVisible), .remove(.floatOnTop), .remove(.formatBadge),
                .remove(.cover), .remove(.scrollAxis), .remove(.direction), .remove(.pageIndicator),
                .remove(.style), .remove(.transition), .remove(.selectText), .remove(.layout),
                .remove(.thumbnails), .remove(.zoom), .compact(.print),
            ])
    }

    /// Every item at once, each with its own width, so that each step frees a different amount.
    private let everything: [BandLayout.Item: BandLayout.Widths] = [
        .formatBadge: .init(full: 30), .pageIndicator: .init(full: 50),
        .style: .init(full: 90, compact: 40),
        .layout: .init(full: 60), .direction: .init(full: 61), .scrollAxis: .init(full: 62),
        .transition: .init(full: 100, compact: 40), .cover: .init(full: 30),
        .selectText: .init(full: 110, compact: 30), .zoom: .init(full: 50), .thumbnails: .init(full: 30),
        .floatOnTop: .init(full: 30), .keepMenuVisible: .init(full: 30),
        .print: .init(full: 70, compact: 34),
    ]

    @Test(
        "1pt 足りないごとに、次の 1 つだけが場所を空ける",
        arguments: [
            // fixed 150 + name 80 + items 803 + three separators 30 = 1063.
            (1063, [], []),
            (1062, [], [.style]),
            (1012, [], [.style, .transition]),
            (952, [], [.style, .transition, .selectText]),
            (872, [.keepMenuVisible], [.style, .transition, .selectText]),
            (842, [.floatOnTop, .keepMenuVisible], [.style, .transition, .selectText]),
            (802, [.formatBadge, .floatOnTop, .keepMenuVisible], [.style, .transition, .selectText]),
            (772, [.formatBadge, .cover, .floatOnTop, .keepMenuVisible], [.style, .transition, .selectText]),
            (
                742, [.formatBadge, .scrollAxis, .cover, .floatOnTop, .keepMenuVisible],
                [.style, .transition, .selectText]
            ),
            (
                680, [.formatBadge, .direction, .scrollAxis, .cover, .floatOnTop, .keepMenuVisible],
                [.style, .transition, .selectText]
            ),
            (
                619, [.formatBadge, .pageIndicator, .direction, .scrollAxis, .cover, .floatOnTop, .keepMenuVisible],
                [.style, .transition, .selectText]
            ),
            (
                569,
                [.formatBadge, .pageIndicator, .style, .direction, .scrollAxis, .cover, .floatOnTop, .keepMenuVisible],
                [.transition, .selectText]
            ),
            (
                519,
                [
                    .formatBadge, .pageIndicator, .style, .direction, .scrollAxis, .transition, .cover, .floatOnTop,
                    .keepMenuVisible,
                ],
                [.selectText]
            ),
            (
                479,
                [
                    .formatBadge, .pageIndicator, .style, .direction, .scrollAxis, .transition, .cover, .selectText,
                    .floatOnTop, .keepMenuVisible,
                ],
                []
            ),
        ] as [(CGFloat, [BandLayout.Item], Set<BandLayout.Item>)])
    func eachStepFreesItsOwnRoom(
        available: CGFloat, overflow: [BandLayout.Item], compact: Set<BandLayout.Item>
    ) {
        let result = plan(everything, available: available)
        #expect(result.overflow == overflow)
        #expect(Set(result.forms.filter { $0.value == .compact }.keys) == compact)
    }

    @Test(
        "表示の型の後はサムネイル、拡大率の順に帯から外し、最後に印刷をアイコンにする",
        arguments: [
            // Before these steps the band holds the layout, zoom, thumbnails and Print, with one separator: 450.
            (450, [.layout, .zoom, .thumbnails, .print], false),
            (449, [.zoom, .thumbnails, .print], false),
            (379, [.zoom, .print], false),
            (349, [.print], false),
            (300, [.print], false),
            (299, [.print], true),
        ] as [(CGFloat, [BandLayout.Item], Bool)])
    func lastStepsKeepPrintToTheEnd(available: CGFloat, shown: [BandLayout.Item], printIsIcon: Bool) {
        let result = plan(everything, available: available)
        #expect(BandLayout.Item.allCases.filter { result.forms[$0] != nil } == shown)
        #expect((result.forms[.print] == .compact) == printIsIcon)
    }

    @Test("短いファイル名は 80pt より狭い元の幅で場所を取る")
    func shortNameReservesItsOwnWidth() {
        let result = plan(available: fullWidth - 30, name: 50)
        #expect(result.forms.values.allSatisfy { $0 == .full })
        #expect(result.nameWidth == 50)
    }
}

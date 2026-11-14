import CoreGraphics
import SurimonoCore
import Testing

struct BandLayoutTests {
    private let widths: [BandLayout.Item: BandLayout.Widths] = [
        .formatBadge: .init(full: 30), .pageIndicator: .init(full: 50),
        .presentation: .init(full: 120, compact: 50), .style: .init(full: 90, compact: 40),
        .layout: .init(full: 60), .transition: .init(full: 100, compact: 40),
        .zoom: .init(full: 50), .thumbnails: .init(full: 30), .print: .init(full: 70, compact: 34),
    ]

    private let bottomWidths: [BandLayout.Item: BandLayout.Widths] = [
        .style: .init(full: 90, compact: 40), .outline: .init(full: 60, compact: 30), .layout: .init(full: 60),
        .transition: .init(full: 100, compact: 40), .pageIndicator: .init(full: 50), .pageTurn: .init(full: 60),
    ]

    private func bottomPlan(_ available: CGFloat) -> BandLayout.Plan {
        BandLayout.plan(
            widths: bottomWidths, fixed: 30, separator: 10, name: 0, available: available,
            steps: BandLayout.bottomSteps)
    }

    private func plan(_ available: CGFloat, name: CGFloat = 120) -> BandLayout.Plan {
        BandLayout.plan(widths: widths, fixed: 150, separator: 10, name: name, available: available)
    }

    @Test("帯にはタイトル・形式別の操作・スタイル・表示の型・送り方・最前面に固定・印刷だけを並べる")
    func itemsFollowTheSpecification() {
        #expect(
            BandLayout.Item.allCases == [
                .formatBadge, .pageIndicator, .presentation, .style, .outline, .layout, .transition, .zoom,
                .thumbnails, .floatOnTop, .pageTurn, .print,
            ])
    }

    @Test("名前を先に省き、タイトルと操作を畳み、最前面に固定は最後まで残してから印刷をアイコンにする")
    func stepsFollowTheSpecification() {
        #expect(
            BandLayout.steps == [
                .compact(.style), .compact(.transition), .compact(.presentation), .compact(.outline),
                .remove(.formatBadge), .remove(.pageIndicator), .remove(.style), .remove(.transition),
                .remove(.layout), .remove(.outline), .remove(.presentation), .remove(.thumbnails), .remove(.zoom),
                .remove(.floatOnTop), .compact(.print),
            ])
    }

    @Test("最前面に固定は、ほかの道具がすべて外れるまで帯に残る")
    func pinStaysLate() {
        var withPin = widths
        withPin[.floatOnTop] = .init(full: 28)
        let narrow = BandLayout.plan(widths: withPin, fixed: 150, separator: 10, name: 120, available: 400)
        #expect(narrow.forms[.floatOnTop] == .full)
        #expect(narrow.overflow.contains(.style) && narrow.overflow.contains(.layout))
        let narrowest = BandLayout.plan(widths: withPin, fixed: 150, separator: 10, name: 120, available: 300)
        #expect(narrowest.overflow.last == .floatOnTop)
    }

    @Test("下の帯は名前を省いたあと、見方の操作から畳み、ページ表示を最後まで残す")
    func bottomStepsFollowTheSpecification() {
        #expect(
            BandLayout.bottomSteps == [
                .compact(.style), .compact(.transition), .compact(.presentation), .compact(.outline),
                .remove(.transition), .remove(.layout), .remove(.pageTurn), .remove(.style), .remove(.outline),
                .remove(.presentation), .remove(.thumbnails), .remove(.zoom), .remove(.pageIndicator),
            ])
    }

    @Test("上と下に分けると、上の帯には形式の印・最前面に固定・印刷だけが残る")
    func splitPlacesItems() {
        let top = BandLayout.Item.allCases.filter { BandLayout.position(of: $0, in: .split) == .top }
        #expect(top == [.formatBadge, .floatOnTop, .print])
    }

    @Test("上だけなら、すべての部品が上の帯に並ぶ")
    func topKeepsEverything() {
        #expect(BandLayout.Item.allCases.allSatisfy { BandLayout.position(of: $0, in: .top) == .top })
    }

    @Test(
        "下の帯も幅の境界を1pt下回ると次の部品だけが場所を空ける",
        arguments: [
            (460, [], []),
            (459, [], [.style]),
            (409, [], [.style, .transition]),
            (349, [], [.outline, .style, .transition]),
            (319, [.transition], [.outline, .style]),
            (279, [.layout, .transition], [.outline, .style]),
            (209, [.layout, .transition, .pageTurn], [.outline, .style]),
            (149, [.style, .layout, .transition, .pageTurn], [.outline]),
            (109, [.style, .outline, .layout, .transition, .pageTurn], []),
            (79, [.pageIndicator, .style, .outline, .layout, .transition, .pageTurn], []),
        ] as [(CGFloat, [BandLayout.Item], Set<BandLayout.Item>)])
    func bottomBoundaries(available: CGFloat, overflow: [BandLayout.Item], compact: Set<BandLayout.Item>) {
        let result = bottomPlan(available)
        #expect(result.overflow == overflow)
        #expect(Set(result.forms.filter { $0.value == .compact }.keys) == compact)
    }

    @Test("下の帯は名前を持たないので、名前の場所を取らない")
    func bottomBandHasNoName() {
        #expect(bottomPlan(480).nameWidth == 0)
        #expect(!bottomPlan(480).showsName)
    }

    @Test("すべて入る幅では元の形で並びファイル名も元の幅になる")
    func everythingFits() {
        let result = plan(2000)
        #expect(result.forms.count == 9)
        #expect(result.forms.values.allSatisfy { $0 == .full })
        #expect(result.overflow.isEmpty)
        #expect(result.nameWidth == 120)
    }

    @Test("ファイル名は80ptまで縮めてから部品を畳む")
    func nameShrinksFirst() {
        let result = plan(860)
        #expect(result.forms.values.allSatisfy { $0 == .full })
        #expect(result.nameWidth == 80)
    }

    @Test(
        "幅の境界を1pt下回ると次の部品だけが場所を空ける",
        arguments: [
            (860, [], []),
            (859, [], [.style]),
            (809, [], [.style, .transition]),
            (749, [], [.presentation, .style, .transition]),
            (679, [.formatBadge], [.presentation, .style, .transition]),
            (649, [.formatBadge, .pageIndicator], [.presentation, .style, .transition]),
            (599, [.formatBadge, .pageIndicator, .style], [.presentation, .transition]),
            (549, [.formatBadge, .pageIndicator, .style, .transition], [.presentation]),
            (509, [.formatBadge, .pageIndicator, .style, .layout, .transition], [.presentation]),
            (439, [.formatBadge, .pageIndicator, .presentation, .style, .layout, .transition], []),
            (379, [.formatBadge, .pageIndicator, .presentation, .style, .layout, .transition, .thumbnails], []),
            (349, [.formatBadge, .pageIndicator, .presentation, .style, .layout, .transition, .zoom, .thumbnails], []),
            (
                299, [.formatBadge, .pageIndicator, .presentation, .style, .layout, .transition, .zoom, .thumbnails],
                [.print]
            ),
        ] as [(CGFloat, [BandLayout.Item], Set<BandLayout.Item>)])
    func boundaries(available: CGFloat, overflow: [BandLayout.Item], compact: Set<BandLayout.Item>) {
        let result = plan(available)
        #expect(result.overflow == overflow)
        #expect(Set(result.forms.filter { $0.value == .compact }.keys) == compact)
        #expect(result.nameWidth >= 80)
    }

    @Test("文書にない部品は測らず畳む手順も飛ばす")
    func absentItemsAreSkipped() {
        let web: [BandLayout.Item: BandLayout.Widths] = [
            .formatBadge: .init(full: 30), .presentation: .init(full: 120, compact: 50),
            .print: .init(full: 70, compact: 34),
        ]
        let result = BandLayout.plan(widths: web, fixed: 150, separator: 10, name: 120, available: 379)
        #expect(result.forms == [.presentation: .compact, .print: .full])
        #expect(result.overflow == [.formatBadge])
    }

    @Test("翻訳でラベルが長くなっても実測幅に従って畳む")
    func longLocalizedLabels() {
        let widths: [BandLayout.Item: BandLayout.Widths] = [
            .style: .init(full: 260, compact: 40), .transition: .init(full: 240, compact: 40),
            .layout: .init(full: 200), .print: .init(full: 130, compact: 34),
        ]
        let result = BandLayout.plan(widths: widths, fixed: 100, separator: 0, name: 120, available: 360)
        #expect(result.forms == [.print: .full])
        #expect(result.nameWidth == 120)
    }

    @Test("畳み切っても足りなければ名前を縮め印刷と固定部分を残す")
    func nameGivesWayLast() {
        #expect(plan(210).forms == [.print: .compact])
        #expect(plan(210).nameWidth == 26)
        #expect(plan(210).showsName)
        #expect(plan(200).nameWidth == 16)
        #expect(!plan(200).showsName)
    }

    @Test("短いファイル名は80ptより狭い元の幅で場所を取る")
    func shortName() {
        let result = plan(830, name: 50)
        #expect(result.forms.values.allSatisfy { $0 == .full })
        #expect(result.nameWidth == 50)
    }
}

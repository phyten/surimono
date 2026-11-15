import Testing

@testable import SurimonoCore

struct ManualDuplexPlanTests {
    @Test("3枚の表裏の順序と回転は8通りの表に従う")
    func orderTable() throws {
        let rows: [(PrintPageOrder, Bool, Bool, [Int])] = [
            (.firstSheetFirst, false, false, [5, 3, 1]),
            (.firstSheetFirst, false, true, [5, 3, 1]),
            (.firstSheetFirst, true, false, [1, 3, 5]),
            (.firstSheetFirst, true, true, [1, 3, 5]),
            (.lastSheetFirst, false, false, [1, 3, 5]),
            (.lastSheetFirst, false, true, [1, 3, 5]),
            (.lastSheetFirst, true, false, [5, 3, 1]),
            (.lastSheetFirst, true, true, [5, 3, 1]),
        ]
        for (order, reverse, rotate, expected) in rows {
            let plan = try ManualDuplexPlan.make(
                imposition: Imposition.plan(pageCount: 6, layout: .a4Duplex), copies: 1,
                frontPageOrder: order,
                correction: ManualDuplexCorrection(reversesBackOrder: reverse, rotatesBackSides: rotate))
            #expect(plan.fronts.map(\.sourceSideIndex) == [0, 2, 4])
            #expect(plan.fronts.allSatisfy { !$0.rotates180 })
            #expect(plan.backs.map(\.sourceSideIndex) == expected)
            #expect(plan.backs.allSatisfy { $0.rotates180 == rotate })
            #expect(plan.frontPageOrder == order)
            #expect(plan.sheetCount == 3)
        }
    }

    @Test("2部の用紙を部単位で展開し全体の出力順に裏を対応させる")
    func copies() throws {
        for order in [PrintPageOrder.firstSheetFirst, .lastSheetFirst] {
            let plan = try ManualDuplexPlan.make(
                imposition: Imposition.plan(pageCount: 6, layout: .a4Duplex), copies: 2,
                frontPageOrder: order, correction: .init())
            #expect(plan.fronts.map(\.copyIndex) == [0, 0, 0, 1, 1, 1])
            #expect(plan.fronts.map(\.sheetIndex) == [0, 1, 2, 0, 1, 2])
            if order == .lastSheetFirst {
                #expect(plan.backs.map(\.copyIndex) == [0, 0, 0, 1, 1, 1])
                #expect(plan.backs.map(\.sourceSideIndex) == [1, 3, 5, 1, 3, 5])
            } else {
                #expect(plan.backs.map(\.copyIndex) == [1, 1, 1, 0, 0, 0])
                #expect(plan.backs.map(\.sourceSideIndex) == [5, 3, 1, 5, 3, 1])
            }
            #expect(plan.sheetCount == 6)
        }
    }

    @Test("5ページの最後の白紙と冊子の白紙を含む面を省略しない")
    func blanks() throws {
        let plan = try ManualDuplexPlan.make(
            imposition: Imposition.plan(pageCount: 5, layout: .a4Duplex), copies: 1,
            frontPageOrder: .firstSheetFirst, correction: .init())
        #expect(plan.backs.map(\.isBlank) == [true, false, false])
        let booklet = try ManualDuplexPlan.make(
            imposition: Imposition.plan(pageCount: 1, layout: .a4BookletA5), copies: 1,
            frontPageOrder: .lastSheetFirst, correction: .init())
        #expect(booklet.fronts.map(\.isBlank) == [false])
        #expect(booklet.backs.map(\.isBlank) == [true])
    }

    @Test("片面と空の面付けと不正な部数を拒否する")
    func invalidInputs() {
        for (pages, layout, copies) in [
            (1, PrintLayout.a4Single, 1), (0, .a4Duplex, 1), (2, .a4Duplex, 0),
            (2, .a4Duplex, 100), (2, .a4Duplex, Int.max),
        ] {
            #expect(throws: ManualDuplexPlan.PlanError.self) {
                try ManualDuplexPlan.make(
                    imposition: Imposition.plan(pageCount: pages, layout: layout), copies: copies,
                    frontPageOrder: .firstSheetFirst, correction: .init())
            }
        }
    }

    @Test("表裏の対応が壊れた面付けと枚数のオーバーフローを拒否する")
    func brokenPairs() {
        for plan in [
            ImpositionPlan(
                sides: [.init(slots: [0], isBack: true), .init(slots: [1], isBack: false)],
                sheetCount: 1, isDuplex: true, logicalPageCount: 2, paper: .a4),
            ImpositionPlan(sides: [], sheetCount: Int.max, isDuplex: true, logicalPageCount: 2, paper: .a4),
            ImpositionPlan(
                sides: [.init(slots: [0], isBack: false)],
                sheetCount: 1, isDuplex: true, logicalPageCount: 1, paper: .a4),
        ] {
            #expect(throws: ManualDuplexPlan.PlanError.self) {
                try ManualDuplexPlan.make(
                    imposition: plan, copies: 99, frontPageOrder: .firstSheetFirst, correction: .init())
            }
        }
    }
}

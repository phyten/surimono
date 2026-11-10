import SurimonoCore
import Testing

struct NotePagePlanTests {
    @Test("本文8ページの左ノートは本文とノートが交互になる")
    func leftSpread() {
        let pages = NotePagePlan.pages(bodyPageIndices: Array(0..<8), placement: .spreadLeft)
        #expect(
            pages == [
                .body(0), .note, .body(1), .note, .body(2), .note, .body(3), .note,
                .body(4), .note, .body(5), .note, .body(6), .note, .body(7), .note,
            ])
    }

    @Test("冊子の右ノートは単独の先頭ノートと最後の対向ノートを持つ")
    func rightSpread() {
        #expect(
            NotePagePlan.pages(bodyPageIndices: [0, 1, 2], placement: .spreadRight)
                == [.note, .body(0), .note, .body(1), .note, .body(2), .note])
    }

    @Test("2アップは奇数ページが左になり余分な末尾ノートを足さない")
    func twoUp() {
        #expect(
            NotePagePlan.pages(bodyPageIndices: [3, 7], placement: .spreadLeft, layoutKind: .twoUp)
                == [.note, .body(3), .note, .body(7)])
        #expect(
            NotePagePlan.pages(bodyPageIndices: [3, 7], placement: .spreadRight, layoutKind: .twoUp)
                == [.body(3), .note, .body(7), .note])
    }

    @Test("両面の裏には各本文の直後にノートが入る")
    func backs() {
        let pages = NotePagePlan.pages(bodyPageIndices: [0, 1, 2], placement: .duplexBack)
        #expect(pages == [.body(0), .note, .body(1), .note, .body(2), .note])
        let plan = Imposition.plan(pageCount: pages.count, layout: .a4Duplex)
        #expect(
            plan.sides.filter(\.isBack).compactMap { $0.slots.first ?? nil }.map { pages[$0] }
                == [.note, .note, .note])
    }

    @Test("章末は本文indexで指定し最終ページのノートを重複させない")
    func chapters() {
        #expect(
            NotePagePlan.pages(
                bodyPageIndices: Array(0..<8), placement: .chapterEnd,
                chapterEndBodyIndices: [0, 2, 3, 5, 7, 99])
                == [
                    .body(0), .note, .body(1), .body(2), .note, .body(3), .note,
                    .body(4), .body(5), .note, .body(6), .body(7), .note,
                ])
        #expect(
            NotePagePlan.pages(bodyPageIndices: [5, 2], placement: .chapterEnd)
                == [.body(5), .body(2), .note])
    }

    @Test("本文が空ならどの入れ方でもノートを作らない", arguments: NotePagePlan.Placement.allCases)
    func empty(placement: NotePagePlan.Placement) {
        #expect(NotePagePlan.pages(bodyPageIndices: [], placement: placement).isEmpty)
    }

    @Test("ノートを含む8論理ページを既存の中綴じ式へそのまま渡せる")
    func imposition() {
        let pages = NotePagePlan.pages(bodyPageIndices: [0, 1, 2, 3], placement: .spreadLeft)
        let plan = Imposition.plan(pageCount: pages.count, layout: .a3BookletA4)
        #expect(plan.sides.map(\.slots) == [[7, 0], [1, 6], [5, 2], [3, 4]])
        #expect(plan.sheetCount == 2)
        #expect(
            plan.sides.map { side in side.slots.map { $0.map { pages[$0] } } }
                == [[.note, .body(0)], [.note, .body(3)], [.note, .body(1)], [.note, .body(2)]])
    }

    @Test("右とじの左ノートは面付け後も左に並び、補完の白紙はノートにしない")
    func rightBoundLeftNotes() {
        let pages = NotePagePlan.pages(
            bodyPageIndices: [0, 1, 2, 3], placement: .spreadLeft, bookletBinding: .right)
        #expect(pages == [.note, .body(0), .note, .body(1), .note, .body(2), .note, .body(3), .note])
        let imposed = Imposition.plan(pageCount: pages.count, layout: PrintLayout.a4BookletA5.bound(.right))
        #expect(
            imposed.sides.map { side in side.slots.map { $0.map { pages[$0] } } }
                == [
                    [.note, nil], [nil, .body(0)], [.note, nil], [.note, .body(1)],
                    [.note, .body(3)], [.note, .body(2)],
                ])
    }

    @Test("右とじの右ノートは面付け後も全ての用紙の右に並ぶ")
    func rightBoundRightNotes() {
        let pages = NotePagePlan.pages(
            bodyPageIndices: [0, 1, 2, 3], placement: .spreadRight, bookletBinding: .right)
        #expect(pages == [.body(0), .note, .body(1), .note, .body(2), .note, .body(3), .note])
        let imposed = Imposition.plan(pageCount: pages.count, layout: PrintLayout.a4BookletA5.bound(.right))
        #expect(
            imposed.sides.map { side in side.slots.map { $0.map { pages[$0] } } }
                == [[.body(0), .note], [.body(3), .note], [.body(1), .note], [.body(2), .note]])
    }

    @Test("右とじの指定は2アップの左右と両面の裏と章末の並びを変えない")
    func bindingOnlyChangesBookletSpreads() {
        #expect(
            NotePagePlan.pages(
                bodyPageIndices: [0, 1], placement: .spreadLeft, layoutKind: .twoUp, bookletBinding: .right)
                == [.note, .body(0), .note, .body(1)])
        #expect(
            NotePagePlan.pages(
                bodyPageIndices: [0, 1], placement: .spreadRight, layoutKind: .twoUp, bookletBinding: .right)
                == [.body(0), .note, .body(1), .note])
        #expect(
            NotePagePlan.pages(bodyPageIndices: [0, 1], placement: .duplexBack, bookletBinding: .right)
                == [.body(0), .note, .body(1), .note])
        #expect(
            NotePagePlan.pages(bodyPageIndices: [0, 1], placement: .chapterEnd, bookletBinding: .right)
                == [.body(0), .body(1), .note])
    }

    @Test("右ノートの末尾以降の冊子補完はノートではなく白紙になる")
    func padding() {
        let pages = NotePagePlan.pages(bodyPageIndices: [0], placement: .spreadRight)
        #expect(pages == [.note, .body(0), .note])
        #expect(
            Imposition.plan(pageCount: pages.count, layout: .a4BookletA5).sides.map(\.slots)
                == [[nil, 0], [1, 2]])
    }

    @Test("目次の後ろから始めても本文は同じ側に並び、足りない所だけノートで埋める")
    func leadingPages() {
        #expect(
            NotePagePlan.pages(bodyPageIndices: [0, 1], placement: .spreadRight, leadingPageCount: 1)
                == [.body(0), .note, .body(1), .note])
        #expect(
            NotePagePlan.pages(bodyPageIndices: [0, 1], placement: .spreadLeft, leadingPageCount: 1)
                == [.note, .body(0), .note, .body(1), .note])
        #expect(
            NotePagePlan.pages(bodyPageIndices: [0], placement: .duplexBack, leadingPageCount: 2)
                == [.body(0), .note])
    }
}

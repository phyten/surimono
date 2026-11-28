import SurimonoCore
import Testing

struct HeadingKeepTests {
    private typealias Facts = HeadingKeep.Facts

    private func text(
        heading: Int = 3, previous: Int? = 3, follow: Int?, last: Int? = nil, lines: Int? = nil, required: Int = 3,
        move: Double? = 0.05, space: Double? = nil
    ) -> HeadingKeep.Placement {
        HeadingKeep.placement(
            of: Facts(
                headingFirstPage: heading, headingLastPage: heading, previousPage: previous,
                follow: .text(requiredLines: required), followFirstPage: follow, followLastPage: last ?? follow,
                linesOnHeadingPage: lines, move: move, precedingSpace: space))
    }

    @Test("本文の最初の行が次のページにある見出しは離れている")
    func textOnNextPageIsSeparated() {
        #expect(text(follow: 4) == .separated(move: 0.05, startsPage: false))
    }

    @Test("読んだ本文がすべて見出しのページにあれば一緒にある")
    func wholeTextOnPageIsTogether() {
        #expect(text(follow: 3) == .together(precedingSpace: nil))
    }

    @Test("見出しのページに本文が求める行数より少ししかなければ離れている")
    func tooFewLinesIsSeparated() {
        #expect(text(follow: 3, last: 4, lines: 2) == .separated(move: 0.05, startsPage: false))
        #expect(text(follow: 3, last: 4, lines: 3) == .together(precedingSpace: nil))
    }

    @Test("本文の行数が読めないときは一緒とみなさず未判定にする")
    func unknownLinesIsUnmeasured() {
        #expect(text(follow: 3, last: 4, lines: nil) == .unmeasured(.ambiguous))
    }

    @Test("表やコードは最初の文字が同じページにあれば一緒にある")
    func blockNeedsOnlyItsStart() {
        let facts = Facts(
            headingFirstPage: 2, headingLastPage: 2, previousPage: 2, follow: .block, followFirstPage: 2,
            followLastPage: 5)
        #expect(HeadingKeep.placement(of: facts) == .together(precedingSpace: nil))
    }

    @Test("ページの先頭にある見出しは、離れていても送って直せない")
    func groupOpeningAPageCannotMove() {
        #expect(text(previous: 2, follow: 4) == .separated(move: 0.05, startsPage: true))
        let first = Facts(
            headingFirstPage: 0, headingLastPage: 0, previousPage: nil, hasPreviousText: false,
            follow: .text(requiredLines: 3), followFirstPage: 1)
        #expect(HeadingKeep.placement(of: first) == .separated(move: nil, startsPage: true))
    }

    @Test("ページの先頭の見出しは前のページの余りを一緒に返す")
    func openingGroupReportsPrecedingSpace() {
        #expect(text(previous: 2, follow: 3, space: 0.4) == .together(precedingSpace: 0.4))
    }

    @Test("続いた見出しの上の見出しだけがページの末尾にあれば離れている")
    func splitGroupIsSeparated() {
        let split = Facts(
            headingFirstPage: 1, headingLastPage: 2, previousPage: 1, follow: .text(requiredLines: 3),
            followFirstPage: 2, move: 0.04)
        #expect(HeadingKeep.placement(of: split) == .separated(move: 0.04, startsPage: false))
    }

    @Test("見出しの後の図は、見出しのページの見出しより下に何か描かれていれば一緒にある")
    func graphicIsReadFromThePage() {
        var facts = Facts(headingFirstPage: 1, headingLastPage: 1, previousPage: 1, follow: .graphic, move: 0.03)
        facts.drawnBelow = true
        #expect(HeadingKeep.placement(of: facts) == .together(precedingSpace: nil))
        facts.drawnBelow = false
        #expect(HeadingKeep.placement(of: facts) == .separated(move: 0.03, startsPage: false))
    }

    @Test("本文が読めない、印のない対応は未判定にする")
    func unmeasured() {
        let picture = Facts(headingFirstPage: 1, headingLastPage: 1, previousPage: 1, follow: .graphic)
        #expect(HeadingKeep.placement(of: picture) == .unmeasured(.unreadable))
        let lost = Facts(headingFirstPage: nil, headingLastPage: 1, previousPage: 1, follow: .block)
        #expect(HeadingKeep.placement(of: lost) == .unmeasured(.ambiguous))
        #expect(text(follow: nil) == .unmeasured(.ambiguous))
    }

    @Test("後ろに改ページや文書の終わりが来る見出しは補正の対象にしない")
    func nothingToKeepWith() {
        let facts = Facts(headingFirstPage: 4, headingLastPage: 4, previousPage: 4, follow: .none)
        #expect(HeadingKeep.placement(of: facts) == .alone)
    }

    @Test("離れた見出しがなければ組み直さない")
    func nothingSeparatedPrintsOnce() {
        var planner = HeadingKeep.Planner()
        #expect(planner.next(after: [0: .together(precedingSpace: nil), 1: .alone]) == .finish(.settled))
        #expect(planner.extraPasses == 0)
    }

    @Test("離れた見出しの前にまとめて改ページを入れ、次で落ち着けば止まる")
    func correctsAllSeparatedGroupsAtOnce() {
        var planner = HeadingKeep.Planner()
        let first: [Int: HeadingKeep.Placement] = [
            0: .together(precedingSpace: nil), 1: .separated(move: 0.04, startsPage: false),
            2: .separated(move: 0.1, startsPage: false),
        ]
        #expect(planner.next(after: first) == .print([1, 2]))
        let second: [Int: HeadingKeep.Placement] = [
            0: .together(precedingSpace: nil), 1: .together(precedingSpace: 0.04), 2: .together(precedingSpace: 0.1),
        ]
        #expect(planner.next(after: second) == .finish(.settled))
        #expect(planner.extraPasses == 1)
    }

    @Test("ページの先頭で離れている見出しと、送ると空きが大きすぎる見出しは送らない")
    func skipsUncorrectableGroups() {
        var planner = HeadingKeep.Planner()
        let observed: [Int: HeadingKeep.Placement] = [
            0: .separated(move: 0.05, startsPage: true), 1: .separated(move: 0.3, startsPage: false),
            2: .separated(move: nil, startsPage: false),
        ]
        #expect(planner.next(after: observed) == .finish(.settled))
    }

    @Test("空きの上限は本文の領域の 25% で、それちょうどは送る")
    func moveLimitIsInclusive() {
        var planner = HeadingKeep.Planner()
        #expect(planner.next(after: [0: .separated(move: 0.25, startsPage: false)]) == .print([0]))
    }

    @Test("入れた改ページの前に大きな空きが残れば、その改ページを外して前に組んだものへ戻る")
    func withdrawsBreakThatLeftRoom() {
        var planner = HeadingKeep.Planner()
        #expect(planner.next(after: [0: .separated(move: 0.05, startsPage: false)]) == .print([0]))
        #expect(planner.next(after: [0: .together(precedingSpace: 0.6)]) == .reuse([]))
        #expect(planner.withdrawn == [0])
        #expect(planner.forced.isEmpty)
    }

    @Test("図が自分で次のページへ移って空いた所は、見出しを送った後に残っても改ページを外さない")
    func expectedRoomIsNotHeldAgainstTheBreak() {
        var planner = HeadingKeep.Planner()
        #expect(
            planner.next(after: [0: .separated(move: 0.04, startsPage: false, vacated: 0.45)]) == .print([0]))
        #expect(planner.next(after: [0: .together(precedingSpace: 0.47)]) == .finish(.settled))
        #expect(planner.forced == [0])
        #expect(planner.withdrawn.isEmpty)
    }

    @Test("入れた改ページで直らない見出しは外し、別の見出しの補正は続ける")
    func withdrawsBreakThatDidNotHelp() {
        var planner = HeadingKeep.Planner()
        let first: [Int: HeadingKeep.Placement] = [
            0: .separated(move: 0.05, startsPage: false), 1: .together(precedingSpace: nil),
            2: .separated(move: 0.05, startsPage: false),
        ]
        #expect(planner.next(after: first) == .print([0, 2]))
        let second: [Int: HeadingKeep.Placement] = [
            0: .separated(move: 0.05, startsPage: true), 1: .separated(move: 0.05, startsPage: false),
            2: .together(precedingSpace: 0.05),
        ]
        #expect(planner.next(after: second) == .print([1, 2]))
        #expect(planner.withdrawn == [0])
        // A withdrawn group is not tried again, even if it comes apart once more.
        #expect(planner.next(after: [0: .separated(move: 0.05, startsPage: false)]) == .finish(.settled))
    }

    @Test("見出しのために組み直すのは 2 回までで、それ以上は組んだうちの一番良いものを使う")
    func stopsAtTheBudget() {
        var planner = HeadingKeep.Planner()
        let first: [Int: HeadingKeep.Placement] = [
            0: .separated(move: 0.05, startsPage: false), 1: .separated(move: 0.05, startsPage: false),
            2: .separated(move: 0.05, startsPage: false),
        ]
        #expect(planner.next(after: first) == .print([0, 1, 2]))
        #expect(planner.next(after: [3: .separated(move: 0.05, startsPage: false)]) == .print([0, 1, 2, 3]))
        #expect(planner.next(after: [4: .separated(move: 0.05, startsPage: false)]) == .reuse([0, 1, 2]))
        #expect(planner.stop == .budget)
        #expect(planner.extraPasses == 2)
    }

    @Test("組み直しが尽きたとき、最後の組版が一番良ければそれを使う")
    func budgetKeepsTheBestLastPrint() {
        var planner = HeadingKeep.Planner()
        let first: [Int: HeadingKeep.Placement] = [
            0: .separated(move: 0.05, startsPage: false), 1: .separated(move: 0.05, startsPage: false),
            2: .separated(move: 0.05, startsPage: false),
        ]
        #expect(planner.next(after: first) == .print([0, 1, 2]))
        let second: [Int: HeadingKeep.Placement] = [
            3: .separated(move: 0.05, startsPage: false), 5: .separated(move: 0.05, startsPage: false),
        ]
        #expect(planner.next(after: second) == .print([0, 1, 2, 3, 5]))
        #expect(planner.next(after: [4: .separated(move: 0.05, startsPage: false)]) == .finish(.budget))
        #expect(planner.forced == [0, 1, 2, 3, 5])
    }

    @Test("最後の組み直しで大きな空きを残す改ページが出たら、それより良かった前の組版に戻る")
    func budgetEndsOnTheBestPrint() {
        var planner = HeadingKeep.Planner()
        let first: [Int: HeadingKeep.Placement] = [
            0: .separated(move: 0.05, startsPage: false), 3: .separated(move: 0.05, startsPage: false),
        ]
        #expect(planner.next(after: first) == .print([0, 3]))
        let second: [Int: HeadingKeep.Placement] = [
            0: .together(precedingSpace: 0.02), 1: .separated(move: 0.05, startsPage: false),
            3: .together(precedingSpace: 0.04),
        ]
        #expect(planner.next(after: second) == .print([0, 1, 3]))
        // The second break moved the text before the first, which now ends a page almost empty.
        let last: [Int: HeadingKeep.Placement] = [
            0: .together(precedingSpace: 0.9), 1: .together(precedingSpace: 0.03),
            2: .separated(move: 0.05, startsPage: false), 3: .together(precedingSpace: 0.04),
        ]
        #expect(planner.next(after: last) == .reuse([0, 3]))
        #expect(planner.forced == [0, 3])
        #expect(planner.stop == .budget)
    }

    @Test("同じ数だけ離れた組版のうちでは、改ページの少ない方に戻る")
    func tiesPreferFewerBreaks() {
        var planner = HeadingKeep.Planner()
        #expect(planner.next(after: [0: .separated(move: 0.05, startsPage: false)]) == .print([0]))
        #expect(
            planner.next(after: [0: .together(precedingSpace: 0.02), 1: .separated(move: 0.05, startsPage: false)])
                == .print([0, 1]))
        let last: [Int: HeadingKeep.Placement] = [
            0: .together(precedingSpace: 0.02), 1: .together(precedingSpace: 0.9),
            2: .separated(move: 0.05, startsPage: true),
        ]
        #expect(planner.next(after: last) == .reuse([]))
        #expect(planner.stop == .settled)
    }

    @Test("未判定の見出しは、入れた改ページを保つ")
    func unmeasuredKeepsBreak() {
        var planner = HeadingKeep.Planner()
        #expect(planner.next(after: [0: .separated(move: 0.05, startsPage: false)]) == .print([0]))
        #expect(planner.next(after: [0: .unmeasured(.ambiguous)]) == .finish(.settled))
        #expect(planner.forced == [0])
    }

    @Test("集計は離れた見出しのうち直せないものと未判定の理由を数える")
    func summaryCounts() {
        let summary = HeadingKeep.Summary([
            0: .together(precedingSpace: nil), 1: .separated(move: 0.05, startsPage: false),
            2: .separated(move: 0.5, startsPage: false), 3: .separated(move: 0.05, startsPage: true),
            4: .unmeasured(.ambiguous), 5: .unmeasured(.unreadable), 6: .alone,
        ])
        #expect(summary.groups == 7)
        #expect(summary.together == 1)
        #expect(summary.separated == 3)
        #expect(summary.uncorrectable == 2)
        #expect(summary.alone == 1)
        #expect(summary.unmeasured == ["ambiguous": 1, "unreadable": 1])
    }
}

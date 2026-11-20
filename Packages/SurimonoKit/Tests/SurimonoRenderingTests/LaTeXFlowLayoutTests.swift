import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

struct LaTeXFlowLayoutTests {
    typealias Flow = LaTeXFlowLayout

    private func item(_ id: Int, _ height: CGFloat, notes: [String] = [], placement: String? = nil, wide: Bool = false)
        -> Flow.Item
    {
        .init(
            slice: .init(strip: id, start: 0, end: height, width: wide ? 100 : 45), notes: notes, placement: placement,
            wide: wide)
    }

    private func segment(_ items: [Flow.Item], columns: Int = 1, balance: Bool = false, pageNotes: Bool = false)
        -> Flow.Segment
    {
        .init(
            columns: columns, gap: 10, rule: columns == 2 ? 1 : 0, balance: balance, pageNotes: pageNotes, items: items)
    }

    private func pages(_ segments: [Flow.Segment]) throws -> [Flow.Page] {
        try Flow.pages(
            .init(
                segments: segments, notes: ["a": .init(strip: 99, start: 0, end: 20, width: 45)],
                noteSkip: 5, textFloatSep: 4, floatSep: 2, inTextSep: 4), width: 100, height: 100)
    }

    @Test("行枠がわずかに重なる脚注段落の改ページ禁止を次の節に持ち越さない")
    func fractionalOverlapBeforeHeading() throws {
        func line(_ start: CGFloat, _ end: CGFloat, paragraph: Int, heading: Bool = false, notes: [String] = [])
            -> Flow.Item
        {
            .init(
                slice: .init(strip: 0, start: start, end: end, width: 100), notes: notes, paragraph: paragraph,
                heading: heading)
        }
        let rows = [
            item(9, 42), line(0, 10, paragraph: 1), line(9.96, 20, paragraph: 1),
            line(19.96, 30, paragraph: 1, notes: ["a"]), line(32, 44, paragraph: 0, heading: true),
            line(45, 55, paragraph: 2), line(55, 65, paragraph: 2), line(65, 75, paragraph: 2),
        ]
        let measure = Flow.Measurement(
            glueShrink: .init(), segments: [segment(rows)],
            notes: ["a": .init(strip: 8, start: 0, end: 10, width: 100)], noteSkip: 3, textFloatSep: 4, floatSep: 2,
            inTextSep: 4)
        let pages = try Flow.pages(measure, width: 100, height: 100)
        #expect(pages.count == 2)
        #expect(pages[0].pieces.map(\.slice.strip) == [9, 0, 8])
        #expect(pages[0].pieces[1].slice.end == 30)
        #expect(pages[1].pieces.first?.slice.start == 32)
    }

    @Test("頁の前半の糊も使って次の段落を収め、縮められる量を超えたときは送る")
    func finitePageShrink() throws {
        var second = item(2, 20)
        var third = item(3, 18)
        second.gap = 4
        second.shrinkBefore = 2
        third.gap = 6
        third.shrinkBefore = 3
        for (tail, pages) in [(12, 1), (13, 2)] {
            let measurement = Flow.Measurement(
                glueShrink: .init(),
                segments: [segment([item(1, 45), second, third, item(4, CGFloat(tail))])], notes: [:],
                noteSkip: 5, textFloatSep: 4, floatSep: 2, inTextSep: 4)
            let result = try Flow.pages(measurement, width: 100, height: 100)
            #expect(result.count == pages)
            #expect(result.flatMap(\.pieces).allSatisfy { $0.scale == 1 })
            #expect(result[0].pieces[1].y == (tail == 12 ? 47 : 49))
        }
    }

    private func spaced(_ id: Int, _ height: CGFloat, gap: CGFloat, plus: CGFloat) -> Flow.Item {
        var row = item(id, height)
        row.gap = gap
        row.stretchBefore = plus
        return row
    }

    @Test("自然改ページでは有限の伸びに比例して段末を揃え、段内の行送りを保つ")
    func proportionalStretch() throws {
        var lines = spaced(2, 10, gap: 4, plus: 2)
        lines.paragraph = 5
        var next = item(2, 10)
        next.slice?.start = 10
        next.slice?.end = 20
        next.paragraph = 5
        let rows = [
            item(1, 30), lines, next, spaced(3, 26, gap: 5, plus: 3),
            item(4, 40), spaced(5, 30, gap: 2, plus: 20),
        ]
        let pages = try Flow.pages(
            .init(
                glueStretch: .init(), segments: [segment(rows)], notes: [:],
                noteSkip: 0, textFloatSep: 0, floatSep: 0, inTextSep: 0), width: 100, height: 100)
        #expect(pages.count == 2)
        #expect(pages[0].pieces.map(\.y) == [0, 40, 74])
        #expect(pages[0].pieces[1].slice.height == 20)
        #expect(pages[0].pieces.last?.end == 100)
        #expect(pages[1].pieces.map(\.y) == [0, 42])
        #expect(pages[1].pieces.last?.end == 72)
    }

    @Test("伸び率の大きい有限糊も段末まで使い、糊なしと強制改ページは自然長にする")
    func raggedBreaks() throws {
        for (plus, forced) in [(CGFloat.zero, false), (2, false), (20, true)] {
            var rows = [item(1, 40), spaced(2, 30, gap: 5, plus: plus)]
            if forced { rows.append(.init(forced: "page")) }
            rows.append(item(3, 40))
            let pages = try Flow.pages(
                .init(
                    glueStretch: .init(), segments: [segment(rows)], notes: [:],
                    noteSkip: 0, textFloatSep: 0, floatSep: 0, inTextSep: 0), width: 100, height: 100)
            #expect(pages.count == 2)
            #expect(pages[0].pieces.last?.end == (plus > 0 && !forced ? 100 : 75))
        }
    }

    @Test("無限糊は最も高い次数だけに配分し、同じ次数の重みの比を保つ")
    func higherOrderStretch() throws {
        let rows = [
            item(1, 10), spaced(2, 10, gap: 5, plus: 8), Flow.Item(gap: 2, fil: 4),
            item(3, 10), .init(fil: 1, filOrder: 2), item(4, 8),
            .init(fil: 2, filOrder: 2), item(5, 10), item(6, 75),
        ]
        let pages = try Flow.pages(
            .init(
                glueStretch: .init(), segments: [segment(rows)], notes: [:], noteSkip: 0,
                textFloatSep: 0, floatSep: 0, inTextSep: 0), width: 100, height: 100)
        #expect(pages.count == 2)
        #expect(pages[0].pieces.map(\.y) == [0, 15, 27, 52, 90])
        #expect(pages[0].pieces.last?.end == 100)
    }

    @Test("脚注末行の下降部は予約から除き、本文と脚注の両方に自然の字面を残す")
    func terminalNoteDepth() throws {
        for columns in [1, 2] {
            let rows = [
                item(1, 59), spaced(2, 12, gap: 4, plus: 1), item(3, 5, notes: ["a"]), item(4, 78),
                item(5, 50),
            ]
            let note = Flow.Slice(strip: 9, start: 0, end: 23, width: 45, noteDepth: 3)
            let pages = try Flow.pages(
                .init(
                    glueStretch: .init(), segments: [segment(rows, columns: columns)], notes: ["a": note], noteSkip: 0,
                    textFloatSep: 0, floatSep: 0, inTextSep: 0), width: 100, height: 100)
            let left = pages[0].pieces.filter { $0.x == 0 }
            #expect(left.map(\.slice.strip) == [1, 2, 3, 9])
            #expect(left.last?.end == 103)
            #expect(left[2].end == 80)
        }
    }

    @Test("左右の段頭で書体の異なる行を同じトップスキップに置く")
    func topSkipUsesFirstBaseline() throws {
        var heading = item(1, 15)
        var reference = item(2, 12)
        heading.columnTopAdjustment = -2
        reference.columnTopAdjustment = 3
        let rows = [heading, .init(forced: "column"), reference]
        let pages = try pages([segment([item(0, 20)]), segment(rows, columns: 2)])
        #expect(pages[0].pieces.map(\.y) == [0, 18, 23])
        #expect(pages[0].pieces[1].y + 12 == 30)
        #expect(pages[0].pieces[2].y + 7 == 30)
    }

    @Test("段抜き表題の下で左右の伸縮率を独立に求め、左段の脚注だけが本文の高さを減らす")
    func separateColumnStretch() throws {
        let rows = [
            item(1, 35), spaced(2, 25, gap: 4, plus: 2),
            item(3, 43), spaced(4, 22, gap: 5, plus: 5), item(5, 55),
        ]
        let pages = try Flow.pages(
            .init(
                glueStretch: .init(),
                columnNotice: .init(strip: 8, start: 0, end: 10, width: 45),
                segments: [segment([item(0, 15)]), segment(rows, columns: 2)], notes: [:],
                noteSkip: 5, textFloatSep: 0, floatSep: 0, inTextSep: 0), width: 100, height: 100)
        #expect(pages.count == 2)
        #expect(pages[0].pieces.map(\.slice.strip) == [0, 1, 2, 8, 3, 4])
        #expect(pages[0].pieces.map(\.y) == [0, 15, 60, 90, 15, 78])
        #expect(pages[0].pieces.map(\.x) == [0, 0, 0, 0, 55, 55])
        #expect(pages[1].pieces.map(\.slice.strip) == [5])
    }

    @Test("明示改段は左段を伸ばさず右段だけを自然改ページで揃える")
    func forcedColumnIsRagged() throws {
        let rows = [
            item(1, 30), spaced(2, 40, gap: 2, plus: 15), .init(forced: "column"),
            item(3, 48), spaced(4, 38, gap: 2, plus: 6), item(5, 50),
        ]
        let pages = try Flow.pages(
            .init(
                glueStretch: .init(), segments: [segment(rows, columns: 2)], notes: [:],
                noteSkip: 0, textFloatSep: 0, floatSep: 0, inTextSep: 0), width: 100, height: 100)
        #expect(pages[0].pieces.map(\.y) == [0, 32, 0, 62])
    }

    @Test("段頭図と本文の間隔も有限糊の割合に応じて伸ばす")
    func topFloatStretch() throws {
        let rows = [item(1, 30), item(2, 20, placement: "t"), spaced(3, 25, gap: 5, plus: 2), item(4, 30)]
        let pages = try Flow.pages(
            .init(
                glueStretch: .init(textFloat: 2), segments: [segment(rows)], notes: [:],
                noteSkip: 0, textFloatSep: 10, floatSep: 5, inTextSep: 5), width: 100, height: 100)
        #expect(pages[0].pieces.map(\.slice.strip) == [2, 1, 3])
        #expect(pages[0].pieces.map(\.y) == [0, 35, 75])
    }

    @Test("左段の通知と本文脚注は一つの罫の下に指定順に並ぶ")
    func columnNoticeOrder() throws {
        let notice = Flow.Slice(strip: 8, start: 0, end: 15, width: 45, noteDepth: 2)
        let bodyNote = Flow.Slice(strip: 9, start: 0, end: 10, width: 45, noteDepth: 3)
        for last in [true, false] {
            let pages = try Flow.pages(
                .init(
                    columnNotice: notice, columnNoticeLast: last,
                    segments: [
                        segment([item(1, 30, notes: ["body"]), .init(forced: "column"), item(2, 25)], columns: 2)
                    ],
                    notes: ["body": bodyNote], noteSkip: 5, noteRuleWidth: 16, textFloatSep: 4, floatSep: 2,
                    inTextSep: 4),
                width: 100, height: 100)
            #expect(pages.count == 1)
            #expect(pages[0].pieces.map(\.slice.strip) == (last ? [1, 9, 8, 2] : [1, 8, 9, 2]))
            #expect(pages[0].pieces.map(\.y) == (last ? [0, 77, 87, 0] : [0, 78, 93, 0]))
            #expect(pages[0].rules.filter { $0.width == 16 }.count == 1)
        }
    }

    @Test("本文が版面の下端に来るとき字面の下降部を縮みとして請求しない")
    func columnEndsOnBaseline() throws {
        var last = spaced(2, 27, gap: 6, plus: 2)
        last.bottomDepth = 3
        let rows = [item(1, 65), last, item(3, 30)]
        let measurement = Flow.Measurement(
            glueStretch: .init(), segments: [segment(rows)], notes: [:],
            noteSkip: 0, textFloatSep: 0, floatSep: 0, inTextSep: 0)
        let pages = try Flow.pages(measurement, width: 100, height: 100)
        #expect(pages.count == 2)
        #expect(pages[0].pieces.last?.end == 103)
    }

    @Test("段末の数式の上下と見出し前の糊は同じ比率で縮む")
    func proportionalDisplayShrink() throws {
        var heading = item(2, 10)
        heading.gap = 8
        heading.shrinkBefore = 2
        var display = item(3, 10)
        display.gap = 10
        display.shrinkBefore = 5
        display.keepBefore = true
        var text = item(4, 14)
        text.gap = 10
        text.shrinkBefore = 5
        let measurement = Flow.Measurement(
            glueShrink: .init(),
            segments: [segment([item(1, 44), heading, display, text])], notes: [:],
            noteSkip: 0, textFloatSep: 0, floatSep: 0, inTextSep: 0)
        let pages = try Flow.pages(measurement, width: 100, height: 100)
        #expect(pages.count == 1)
        // 106 units of natural height fit at a glue ratio of 6 / (2 + 5 + 5).
        #expect(pages[0].pieces.map(\.y) == [0, 51, 68.5, 86])
    }

    @Test("片方の段の見出しを追い込んでも隣の段の糊を縮めない")
    func independentColumnShrink() throws {
        var second = item(2, 40)
        second.gap = 6
        second.shrinkBefore = 4
        var following = item(5, 18)
        following.gap = 8
        following.shrinkBefore = 6
        let measurement = Flow.Measurement(
            glueShrink: .init(), glueStretch: .init(),
            segments: [segment([item(1, 48), second, item(3, 9), item(4, 70), following], columns: 2)],
            notes: [:], noteSkip: 0, textFloatSep: 0, floatSep: 0, inTextSep: 0)
        let pages = try Flow.pages(measurement, width: 100, height: 100)
        #expect(pages.count == 1)
        #expect(pages[0].pieces.map(\.x) == [0, 0, 0, 55, 55])
        #expect(pages[0].pieces.map(\.y) == [0, 51, 91, 0, 78])
    }

    @Test("段末の語中分割の罰点と、手前の切れ目を伸ばす悪さを比較する")
    func discretionaryColumnBreak() throws {
        for (broken, plus, expectedColumn) in [(true, 18, 55), (false, 18, 0), (true, 2, 0)] {
            var second = spaced(2, 36, gap: 12, plus: CGFloat(plus))
            second.shrinkBefore = 8
            var third = item(3, 16)
            third.brokenAfter = broken
            let rows = [item(1, 40), second, third, item(4, 80), item(5, 80), item(6, 80)]
            let measurement = Flow.Measurement(
                glueShrink: .init(), glueStretch: .init(), segments: [segment(rows, columns: 2)], notes: [:],
                noteSkip: 0, textFloatSep: 0, floatSep: 0, inTextSep: 0)
            let result = try Flow.pages(measurement, width: 100, height: 100)
            #expect(result.first?.pieces.first { $0.slice.strip == 3 }?.x == CGFloat(expectedColumn))
        }
    }

    @Test("脚注付き右段の五行段落は挿入の深さと語中分割の罰点で段を切る")
    func discretionaryBreakWithColumnFootnote() throws {
        var paragraph = (0..<5).map { index -> Flow.Item in
            let start = CGFloat(index * 12)
            return .init(
                slice: .init(strip: 3, start: start, end: start + 12, width: 45), paragraph: 1,
                brokenAfter: index == 2, bottomDepth: 2.165)
        }
        paragraph[0].gap = 6
        // Concentrate the column's adjustable skips at the paragraph boundary.
        paragraph[0].stretchBefore = 10.5
        paragraph[0].shrinkBefore = 4.8
        // The first two cases differ by the 1.85 pt title shift and a taller left notice.
        // The last two straddle the point where the third line earns its hyphen penalty.
        let cases: [(CGFloat, CGFloat, CGFloat)] = [(13.85, 10, 24), (12, 16, 24), (11.24, 16, 24), (10.8, 16, 36)]
        for (title, notice, cut) in cases {
            let columns = [item(1, 20), .init(forced: "column"), item(2, 33.35, notes: ["a"])] + paragraph
            let measurement = Flow.Measurement(
                glueShrink: .init(), glueStretch: .init(),
                columnNotice: .init(strip: 8, start: 0, end: notice, width: 45),
                segments: [segment([item(0, title)]), segment(columns, columns: 2)],
                notes: ["a": .init(strip: 9, start: 0, end: 12, width: 45, noteDepth: 2)],
                noteSkip: 4, noteStrutDepth: 3, textFloatSep: 0, floatSep: 0, inTextSep: 0)
            let pages = try Flow.pages(measurement, width: 100, height: 100)
            try #require(pages.count == 2)
            let first = try #require(pages[0].pieces.last { $0.slice.strip == 3 })
            let continuation = try #require(pages[1].pieces.first { $0.slice.strip == 3 })
            #expect(first.x == 55 && first.slice.end == cut)
            #expect(continuation.x == 0 && continuation.slice.start == cut)
            let note = try #require(pages[0].pieces.first { $0.slice.strip == 9 })
            #expect(note.x == 55 && note.end - 2 == 100)
        }
    }

    @Test("最終頁の段境界と脚注を保ち、自然に右段へ続くときだけ左段末を揃える")
    func keepNaturalFinalColumns() throws {
        var second = spaced(2, 28, gap: 8, plus: 1)
        second.shrinkBefore = 6
        let pair = [item(1, 50), second, item(3, 17, notes: ["a"])]
        for explicit in [false, true] {
            var rows = pair
            if explicit { rows.insert(.init(forced: "column"), at: 2) }
            rows.append(item(4, 20))
            let measurement = Flow.Measurement(
                glueShrink: .init(), glueStretch: .init(), segments: [segment(rows, columns: 2)],
                notes: ["a": .init(strip: 8, start: 0, end: 4, width: 45, noteDepth: 2)],
                noteSkip: 1, textFloatSep: 0, floatSep: 0, inTextSep: 0)
            let result = try Flow.pages(measurement, width: 100, height: 100)
            #expect(result.count == 1)
            #expect(result[0].pieces.map(\.slice.strip) == [1, 2, 3, 4, 8])
            #expect(result[0].pieces.map(\.x) == [0, 0, 55, 55, 55])
            #expect(result[0].pieces.map(\.y) == [0, explicit ? 58 : 72, 0, 17, 98])
        }
    }

    @Test("最終頁左段の図間と本文の空きが伸び、右段の本文は自然長を保つ")
    func finalLeftColumnFloatSeparation() throws {
        let rows = [
            item(1, 15, placement: "t"), item(2, 15, placement: "t"), item(3, 20),
            spaced(4, 20, gap: 4, plus: 2), item(5, 40), spaced(6, 10, gap: 2, plus: 8),
        ]
        let pages = try Flow.pages(
            .init(
                glueStretch: .init(textFloat: 4, float: 2), segments: [segment(rows, columns: 2)],
                notes: [:], noteSkip: 0, textFloatSep: 6, floatSep: 4, inTextSep: 0), width: 100, height: 100)
        #expect(pages.count == 1)
        #expect(pages[0].pieces.map(\.slice.strip) == [1, 2, 3, 4, 5, 6])
        #expect(pages[0].pieces.map(\.y) == [0, 23, 52, 80, 0, 42])
        #expect(pages[0].pieces.map(\.x) == [0, 0, 0, 0, 55, 55])
    }

    @Test("脚注と下端通知の有限の糊を使っても通知の位置を保つ")
    func shrinkFooterSkips() throws {
        let measurement = Flow.Measurement(
            glueShrink: .init(note: 2, textFloat: 4),
            firstNotice: .init(strip: 77, start: 0, end: 10, width: 100), firstPageExtension: 10,
            segments: [segment([item(1, 50, notes: ["a"]), item(2, 23)])],
            notes: ["a": .init(strip: 99, start: 0, end: 20, width: 100)],
            noteSkip: 9, textFloatSep: 4, floatSep: 2, inTextSep: 4)
        let result = try Flow.pages(measurement, width: 100, height: 100)
        #expect(result.count == 1)
        #expect(result.first?.pieces.map(\.slice.strip) == [1, 2, 99, 77])
        #expect(result.first?.pieces.last?.y == 100)
    }

    @Test("初頁だけを延長し、脚注の後ろに余白を確保して提出通知を置く")
    func firstPageNotice() throws {
        let measurement = Flow.Measurement(
            firstNotice: .init(strip: 77, start: 0, end: 10, width: 100), firstPageExtension: 22,
            segments: [segment([item(1, 81, notes: ["a"]), item(2, 92)])],
            notes: ["a": .init(strip: 99, start: 0, end: 20, width: 100)],
            noteSkip: 5, textFloatSep: 4, floatSep: 2, inTextSep: 4)
        let output = try Flow.pages(measurement, width: 100, height: 100)
        #expect(output.map { $0.pieces.map(\.slice.strip) } == [[1, 99, 77], [2]])
        #expect(output.first?.pieces.last?.y == 112)
        #expect(output.first?.pieces.first(where: { $0.slice.strip == 99 })?.end == 108)
    }

    @Test("章起こしは浮動体を送り出してから片側にだけ白ページを挟む")
    func facingOpenings() throws {
        let right = Flow.Item(forced: "right")
        let left = Flow.Item(forced: "left")
        let result = try pages([
            segment([
                right, item(1, 15), item(2, 10, placement: "p"), right, right, item(3, 10), left, item(4, 10), left,
                item(5, 10),
            ])
        ])
        #expect(result.map { $0.pieces.map(\.slice.strip) } == [[1], [2], [3], [4], [], [5]])
        #expect(result.indices.filter { result[$0].isBlankVersoOrRecto } == [4])
    }

    @MainActor @Test("専用スタイルの和文格子・段組み・注・図を横組みのページ割りに送る")
    func routing() async throws {
        let dedicated = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let general = PrintTheme(id: "general", name: "General", css: "")
        for (tex, theme, expected) in [
            (#"\documentclass{jsarticle}\begin{document}紙\end{document}"#, dedicated, true),
            (#"\documentclass{ltjsreport}\begin{document}紙\end{document}"#, general, false),
            ("Body", dedicated, false), ("Body\\footnote{Note}", dedicated, true),
            ("\\begin{figure}Box\\end{figure}", dedicated, true),
            ("\\twocolumn Body", dedicated, true), ("\\twocolumn Body", general, false),
        ] {
            var flags: [Bool] = []
            let renderer = DocumentRenderer(paginate: { request in
                flags.append(request.latexFlow)
                return try RenderingFixtures.pdf(size: request.pageSize)
            })
            _ = try await renderer.prepare(
                DocumentSource(data: Data(tex.utf8), format: .latex),
                settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
            #expect(flags == [expected])
        }
    }

    @Test("長表は送りの脚を予約し、次の用紙の最初の行の前に継続見出しを置く")
    func tablePageBreak() throws {
        var rows = [item(1, 50), item(2, 40), item(3, 45), item(4, 35)]
        for i in rows.indices {
            if i > 0 { rows[i].repeatHead = .init(strip: 7, start: 0, end: 12, width: 100) }
            if i < 3 { rows[i].repeatFoot = .init(strip: 8, start: 0, end: 8, width: 100) }
        }
        let result = try pages([segment(rows)])
        #expect(result.map { $0.pieces.map(\.slice.strip) } == [[1, 2, 8], [7, 3, 4]])
        #expect(result.last?.pieces.map(\.y) == [0, 12, 57])
    }

    @Test("長表は行と送り脚の深さを描画に残し、先頭の伸縮糊を一度だけ縮める")
    func tableFootDepth() throws {
        var first = item(1, 35)
        first.gap = 10
        first.tablePreShrink = 4
        var second = item(2, 30)
        let foot = Flow.Slice(strip: 8, start: 0, end: 12, width: 100)
        first.repeatFoot = foot
        second.repeatFoot = foot
        second.tableBreakDepth = 6
        let result = try pages([segment([item(0, 22), first, second, item(3, 80)])])
        #expect(result.count == 2)
        #expect(result[0].pieces.map(\.slice.strip) == [0, 1, 2, 8])
        #expect(result[0].pieces.map(\.y) == [0, 29, 64, 94])
    }

    @Test("長表の継続見出しと行が空の用紙にも収まらないときは改ページを繰り返さない")
    func oversizedContinuation() {
        var last = item(2, 95)
        last.repeatHead = .init(strip: 7, start: 0, end: 12, width: 100)
        #expect(throws: Flow.CannotFit.self) { try pages([segment([item(1, 70), last])]) }
    }

    @Test("和文の見出しが段頭に来たときだけトップスキップを加える")
    func sectionTopSkip() throws {
        var heading = item(1, 20)
        heading.heading = true
        heading.topSkip = 13.77
        heading.gap = 28
        let atTop = try #require(pages([segment([heading, item(2, 10)])]).first)
        #expect(atTop.pieces.first?.y == 13.77)
        let following = try #require(pages([segment([item(0, 10), heading, item(2, 10)])]).first)
        #expect(following.pieces.map(\.y) == [0, 38, 58])
    }

    @Test("別行数式の下の糊は段末で不足した分だけ縮み、限界を超えた組は次段へ送る")
    func displayShrink() throws {
        var group = item(1, 27)
        group.gap = 10
        group.shrinkBefore = 4
        for (used, expectedY, count): (CGFloat, CGFloat, Int) in [(60, 70, 1), (65, 73, 1), (68, 0, 2)] {
            let result = try pages([segment([item(0, used), group])])
            #expect(result.count == count)
            #expect(result.last?.pieces.last?.y == expectedY)
        }
    }

    @Test("数式直前の本文行は切片が別でも同じでも数式と一緒に送る")
    func keepBeforeDisplay() throws {
        for sameStrip in [false, true] {
            let line = item(1, 10)
            var display = item(sameStrip ? 1 : 2, 20)
            if sameStrip {
                display.slice?.start = 10
                display.slice?.end = 30
            }
            display.keepBefore = true
            let moved = try pages([segment([item(0, 75), line, display])])
            #expect(moved.count == 2)
            #expect(moved.first?.pieces.map(\.slice.strip) == [0])
            #expect(moved.last?.pieces.last?.end == 30)
            #expect(try pages([segment([item(0, 70), line, display])]).count == 1)
        }
    }

    @Test("段末に収まる固定図は下の空きだけを捨てて本文と同じページに残す")
    func pinnedAtFoot() throws {
        let result = try pages([segment([item(0, 75), item(1, 20, placement: "H"), item(2, 10)])])
        #expect(result.map { $0.pieces.map(\.slice.strip) } == [[0, 1], [2]])
        #expect(result.first?.pieces.last?.end == 99)
        let notes = try pages([segment([item(0, 50), item(1, 20, notes: ["a"], placement: "H")])])
        #expect(notes.first?.pieces.map(\.slice.strip) == [0, 1, 99])
    }

    @Test("行間が一画素に満たないときも端数をベクトル断片の配置で保つ", arguments: [CGFloat(3), 0.3])
    func fractionalSkip(points: CGFloat) throws {
        let exact = points * 72 / 72.27 * 1.25
        let measured = max(1, floor(exact))
        let extra = exact - measured
        let rows = [
            Flow.Item(
                slice: .init(strip: 0, start: 0, end: 15 + measured, width: 100), paragraph: 1, extraAfter: extra),
            Flow.Item(slice: .init(strip: 0, start: 15 + measured, end: 30 + measured, width: 100), paragraph: 1),
        ]
        let page = try #require(pages([segment(rows)]).first)
        #expect(page.pieces.count == 2)
        let second = try #require(page.pieces.last)
        #expect(abs((second.y - 15) / 1.25 - points * 72 / 72.27) < 0.0001)
    }

    @Test("本文行の字面より下の余白だけをその場の図の上空きに数え、次の図の空きは足す")
    func leadingBeforeHere() throws {
        var figure = item(1, 5, placement: "h")
        figure.leadingBeforeHere = 2
        let page = try #require(pages([segment([item(0, 10), figure, item(2, 5, placement: "h")])]).first)
        #expect(page.pieces.map(\.y) == [0, 12, 25])
    }

    @Test("収まらない参照行を注と一緒に送り、段下の罫と本文の間隔を予約する")
    func notes() throws {
        let result = try pages([segment([item(0, 70), item(1, 10, notes: ["a"])])])
        #expect(result.map { $0.pieces.map(\.slice.strip) } == [[0], [1, 99]])
        #expect(result.last?.pieces.last?.y == 80)
        #expect(result.last?.rules.first?.height == 0.5)
    }

    @Test("右段のページ脚注は左段の既存の本文にも重ならない")
    func pageNotes() throws {
        let result = try pages([
            segment([item(0, 90), .init(forced: "column"), item(1, 10, notes: ["a"])], columns: 2, pageNotes: true)
        ])
        #expect(result.count == 2)
        #expect(result.last?.pieces.map(\.slice.strip) == [1, 99])
    }

    @Test("段頭図・本文・段下図・注の順に左段を出力してから右段に移る")
    func columnReadingOrder() throws {
        let rows = [
            item(1, 10, notes: ["a"]), item(2, 10, placement: "t"), item(3, 10, placement: "b"),
            Flow.Item(forced: "column"), item(4, 10),
        ]
        let page = try #require(pages([segment(rows, columns: 2)]).first)
        #expect(page.pieces.map(\.slice.strip) == [2, 1, 3, 99, 4])
        #expect(page.pieces.map(\.y) == [0, 14, 65, 80, 0])
        let shared = try #require(pages([segment(rows, columns: 2, pageNotes: true)]).first)
        #expect(shared.pieces.map(\.slice.strip) == [2, 1, 3, 4, 99])
    }

    @Test("見出しと段落頭の二行を一緒に保ち、末尾の二行も分けない")
    func keeps() {
        let rows: [Flow.Item] = (0..<6).map { i in
            let start = CGFloat(i) * 10
            let slice = Flow.Slice(strip: 0, start: start, end: start + 10, width: 45)
            return Flow.Item(slice: slice, paragraph: i == 0 ? 0 : 1, heading: i == 0)
        }
        let kept = Flow.keptItems(rows, capacity: 100)
        #expect(kept.compactMap { $0.slice?.height } == [30, 10, 20])
    }

    @Test("追い込み段落の本文で改段でき、連続する見出しと次の三行のうち先頭二行を保つ")
    func sectionAfterRunIn() {
        let rows = [1, 0, 0, 2, 2, 2].enumerated().map { i, paragraph in
            Flow.Item(
                slice: .init(strip: 0, start: CGFloat(i) * 18, end: CGFloat(i + 1) * 18, width: 100),
                paragraph: paragraph, heading: paragraph == 0)
        }
        #expect(Flow.keptItems(rows, capacity: 135).compactMap { $0.slice?.height } == [18, 72, 18])
    }

    @Test("段末で収まる見出しを本文と一緒に送ったときだけ直後の図を次段の頭に置く")
    func floatAfterCarriedHeading() throws {
        var heading = item(1, 15)
        heading.heading = true
        var opening = item(3, 16)
        opening.leadingAfterHeading = 2
        let content = [heading, item(2, 15, placement: "htbp"), opening]
        for (used, order) in [(75, [2, 1, 3]), (90, [1, 2, 3])] {
            let result = try pages([segment([item(0, CGFloat(used))] + content)])
            #expect(result.last?.pieces.map(\.slice.strip) == order)
        }
    }

    @Test("見出しの深さを引いた行間は図を本文中に置けたときだけ加える")
    func leadingAfterInTextFloat() throws {
        var text = item(3, 16)
        text.leadingAfterHere = 2
        for used in [0, 75] {
            var heading = item(1, 15)
            heading.heading = true
            let before = used == 0 ? [] : [item(0, CGFloat(used))]
            let content = before + [heading, item(2, 15, placement: "htbp")]
            let ordinary = try pages([segment(content + [item(3, 16)])])
            let adjusted = try pages([segment(content + [text])])
            let start = try #require(ordinary.last?.pieces.last?.y)
            let end = try #require(adjusted.last?.pieces.last?.y)
            #expect(end - start == (used == 0 ? 2 : 0))
        }
    }

    @Test("見出しに続く数式は上空きの伸縮分だけ段末に収まり、字面の高さを保つ")
    func displayAfterHeading() throws {
        var rows = [item(0, 49), item(1, 20)]
        rows[1].heading = true
        rows.append(.init(slice: .init(strip: 1, start: 28, end: 54, width: 45), gap: 8, shrinkBefore: 4))
        let result = try pages([segment(rows)])
        #expect(result.count == 1)
        let page = try #require(result.last)
        #expect(page.pieces.last?.y == 74)
        #expect(page.pieces.last?.end == 100)
    }

    @Test("見出しと本文の間の図が段末の二行を追い出さない")
    func headingAcrossFloat() throws {
        var heading = item(1, 10)
        heading.heading = true
        let result = try pages([segment([item(0, 50), heading, item(2, 30, placement: "htbp"), item(3, 25)])])
        #expect(result.map { $0.pieces.map(\.slice.strip) } == [[0, 1, 3], [2]])
        let moved = try pages([segment([item(0, 70), heading, item(2, 15, placement: "t"), item(3, 25)])])
        #expect(moved.map { $0.pieces.map(\.slice.strip) } == [[0], [2, 1, 3]])
    }

    @Test("段抜き表題の下で二段を始め、通常の段は詰め、均等割りの末尾だけを揃える")
    func balance() throws {
        let rows = (1...6).map { item($0, 10) }
        for balanced in [true, false] {
            let result = try pages([segment([item(0, 20)]), segment(rows, columns: 2, balance: balanced)])
            let page = try #require(result.first)
            #expect(result.count == 1)
            #expect(page.pieces[1].y == 20)
            #expect(page.pieces.filter { $0.x == 55 }.count == (balanced ? 3 : 0))
            #expect(page.rules == [CGRect(x: 49.5, y: 20, width: 1, height: balanced ? 30 : 60)])
        }
    }

    @Test("同じ種類の図は指定順に次段の頭に置き、段抜き図は次ページの頭から始める")
    func floats() throws {
        let result = try pages([
            segment(
                [
                    item(0, 82), item(1, 20, placement: "t"), item(2, 20, placement: "ht"),
                    item(3, 20, placement: "t", wide: true), item(4, 14), item(5, 8),
                ], columns: 2)
        ])
        #expect(result.count == 2)
        let first = try #require(result.first)
        #expect(first.pieces.filter { $0.x > 0 }.map(\.slice.strip) == [1, 2, 5])
        #expect(first.pieces.first { $0.slice.strip == 1 }?.y == 0)
        #expect(result.last?.pieces.first?.slice.strip == 3)
        #expect(result.last?.pieces.first?.y == 0)
    }

    @Test("改ページ後の二つの標準配置の図表を呼び出し元の見出しより上に刷る")
    func topsOnReferencePage() throws {
        let result = try pages([
            segment([
                item(0, 55), .init(forced: "column"), item(1, 15),
                item(2, 22, placement: "tbp"), item(3, 25, placement: "tbp"),
            ])
        ])
        #expect(result.map { $0.pieces.map(\.slice.strip) } == [[0], [2, 3, 1]])
        #expect(result.last?.pieces.map(\.y) == [0, 24, 53])
    }

    @Test("連続する本文位置の図表はそれぞれの上下十二ポイントを保つ")
    func consecutiveHere() throws {
        let result = try Flow.pages(
            .init(
                segments: [
                    segment([
                        item(0, 20), item(1, 25, placement: "h"),
                        item(2, 30, placement: "h"), item(3, 10),
                    ])
                ],
                notes: [:], noteSkip: 0, textFloatSep: 20, floatSep: 12, inTextSep: 12),
            width: 240, height: 350)
        #expect(result.first?.pieces.map(\.y) == [0, 32, 81, 123])
    }

    @Test("本文位置・段下・図だけのページにそれぞれ指定した図表が入る")
    func placements() throws {
        let result = try pages([
            segment([
                item(0, 20), item(1, 20, placement: "H"), item(2, 15, placement: "b"),
                item(3, 75, placement: "p"), item(4, 10),
            ])
        ])
        #expect(result.first?.pieces.first { $0.slice.strip == 1 }?.y == 24)
        #expect(result.first?.pieces.last?.y == 85)
        #expect(result.last?.pieces.map(\.slice.strip) == [3])
    }
    @Test("段頭の見出しの前の十五ポイントと通常の空きは捨て、星付きの空きは保つ")
    func columnTopGlue() throws {
        var heading = item(1, 18)
        heading.slice?.start = 15
        heading.slice?.end = 33
        heading.gap = 15
        heading.heading = true
        var glue = item(0, 13)
        glue.discardable = true
        let left = segment([glue, heading, .init(forced: "column"), heading], columns: 2)
        let first = try #require(try pages([left]).first)
        #expect(first.pieces.map(\.y) == [0, 0])
        #expect(first.pieces.map(\.x) == [0, 55])
        glue.discardable = false
        let starred = try #require(try pages([segment([glue, heading])]).first)
        #expect(starred.pieces.map(\.y) == [0, 28])
    }

    @Test("本文中の表は上下十二ポイントを取り、残り二七四ポイントの二六〇ポイント図を次ページ頭に送る")
    func paperTableThenFigure() throws {
        let items = [
            item(0, 300), .init(forced: "page"), item(1, 160), item(2, 180, placement: "htbp"),
            item(3, 62), item(4, 260, placement: "htbp"), item(5, 75), item(6, 30),
        ]
        let result = try Flow.pages(
            .init(
                segments: [segment(items)], notes: [:], noteSkip: 10, textFloatSep: 20,
                floatSep: 12, inTextSep: 12), width: 450, height: 700)
        #expect(result.map { $0.pieces.map(\.slice.strip) } == [[0], [1, 2, 3, 5, 6], [4]])
        #expect(result[1].pieces.map(\.y) == [0, 172, 364, 426, 501])
        #expect(result[2].pieces[0].y == 0)
    }

    @Test("図の後にも本文の二割を確保し、感嘆符はその割合を緩める")
    func minimumText() throws {
        for (spec, count) in [("ht", 2), ("!ht", 1)] {
            let result = try pages([segment([item(0, 2), item(1, 38, placement: "ht"), item(2, 35, placement: spec)])])
            #expect(result.count == count)
        }
    }

    @Test("上部の図間は十二、本文までは二十ポイントで図だけのページは上下が等しい")
    func topAndFloatPageSpacing() throws {
        let items = [item(0, 80), item(1, 20, placement: "t"), item(2, 20, placement: "t"), item(3, 40)]
        let result = try Flow.pages(
            .init(segments: [segment(items)], notes: [:], noteSkip: 0, textFloatSep: 20, floatSep: 12, inTextSep: 12),
            width: 100, height: 115)
        #expect(result.last?.pieces.map(\.y) == [0, 32, 72])
        let dedicated = try pages([segment([item(0, 10), item(1, 20, placement: "p"), item(2, 30, placement: "p")])])
        #expect(dedicated.last?.pieces.map(\.y) == [24, 46])
    }

    @Test("同じ段の上は二個、下は一個、本文中を含めて三個まで配置する")
    func floatCounts() throws {
        let top = try pages([
            segment([
                item(0, 95), item(1, 8, placement: "t"), item(2, 8, placement: "t"),
                item(3, 8, placement: "t"),
            ])
        ])
        #expect(top.map { $0.pieces.map(\.slice.strip) } == [[0], [1, 2], [3]])
        let bottom = try pages([segment([item(0, 10), item(1, 10, placement: "b"), item(2, 10, placement: "b")])])
        #expect(bottom.map { $0.pieces.map(\.slice.strip) } == [[0, 1], [2]])
        let here = try pages([segment([item(0, 10)] + (1...4).map { item($0, 5, placement: "ht") })])
        #expect(here.map { $0.pieces.map(\.slice.strip) } == [[0, 1, 2, 3], [4]])
        #expect(here[0].pieces.map(\.y) == [0, 14, 27, 40])
    }

    @Test("その場に指定された図が収まらないと本文も一緒に次の段へ送る")
    func pinnedFrame() throws {
        let result = try pages([segment([item(0, 80), item(1, 28, placement: "H"), item(2, 20)])])
        #expect(result.map { $0.pieces.map(\.slice.strip) } == [[0], [1, 2]])
    }

    @Test("排出する図の脚注は図と同じページに付き、改ページ後の本文を先に置かない")
    func clearFloatsWithNotes() throws {
        let result = try pages([
            segment([
                item(0, 70), item(1, 35, notes: ["a"], placement: "t"),
                .init(forced: "clear"), item(2, 10),
            ])
        ])
        #expect(result.map { $0.pieces.map(\.slice.strip) } == [[0], [1, 99], [2]])
    }

    @Test("分割せずに収められない注は一段組みへの再試行を求める")
    func oversizedNote() {
        let measurement = Flow.Measurement(
            segments: [segment([item(0, 15, notes: ["long"])])],
            notes: ["long": .init(strip: 1, start: 0, end: 101, width: 100)],
            noteSkip: 5, textFloatSep: 4, floatSep: 2, inTextSep: 4)
        #expect(throws: Flow.CannotFit.self) { try Flow.pages(measurement, width: 100, height: 100) }
    }
}

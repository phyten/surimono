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

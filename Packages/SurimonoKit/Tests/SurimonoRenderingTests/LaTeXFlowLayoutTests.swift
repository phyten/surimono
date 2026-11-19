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

    @MainActor @Test("専用スタイルの段組み・注・図だけを横組みのページ割りに送る")
    func routing() async throws {
        let dedicated = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let general = PrintTheme(id: "general", name: "General", css: "")
        for (tex, theme, expected) in [
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
                    item(0, 50), item(1, 20, placement: "t"), item(2, 20, placement: "ht"),
                    item(3, 20, placement: "t", wide: true), item(4, 45), item(5, 8),
                ], columns: 2)
        ])
        #expect(result.count == 2)
        let first = try #require(result.first)
        #expect(first.pieces.filter { $0.x > 0 }.map(\.slice.strip) == [1, 2, 5])
        #expect(first.pieces.first { $0.slice.strip == 1 }?.y == 0)
        #expect(result.last?.pieces.first?.slice.strip == 3)
        #expect(result.last?.pieces.first?.y == 0)
    }

    @Test("本文位置・段下・図だけのページにそれぞれ指定した図表が入る")
    func placements() throws {
        let result = try pages([
            segment([
                item(0, 20), item(1, 20, placement: "H"), item(2, 15, placement: "b"),
                item(3, 75, placement: "p"), item(4, 10),
            ])
        ])
        #expect(result.first?.pieces.first { $0.slice.strip == 1 }?.y == 22)
        #expect(result.first?.pieces.last?.y == 85)
        #expect(result.last?.pieces.map(\.slice.strip) == [3])
    }
    @Test("排出する図の脚注は図と同じページに付き、改ページ後の本文を先に置かない")
    func clearFloatsWithNotes() throws {
        let result = try pages([
            segment([
                item(0, 30), item(1, 35, notes: ["a"], placement: "t"),
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

import Foundation
import SurimonoCore
import Testing

struct NotePagesTests {
    private func plan(
        _ pages: Int, contents: Int = 0, starts: Set<Int> = [], placement: NotePagePlan.Placement,
        kind: LayoutKind = .booklet, ends: Set<Int> = []
    ) -> FinishedPagePlan {
        FinishedPagePlan(
            bodyPageCount: pages, contentsPageCount: contents, rightPageStarts: starts,
            notes: .init(placement: placement, layoutKind: kind, chapterEnds: ends))
    }

    @Test("ノートは既定でオフで、大学ノートから始める")
    func defaults() {
        let notes = NotePages()
        #expect(!notes.isEnabled)
        #expect(notes.placement == .spreadRight)
        #expect(notes.presetID == "daigaku")
        #expect(notes.style == NotePaperPreset.standard.style)
    }

    @Test("ノートなしの計画は今までと同じ")
    func withoutNotes() {
        let plan = FinishedPagePlan(bodyPageCount: 3, contentsPageCount: 1, rightPageStarts: [0])
        #expect(plan.pages == [.contents(0), .blank, .body(0), .body(1), .body(2)])
        #expect(plan.notePages.isEmpty)
    }

    @Test("右がノートの 8 ページの冊子は 17 ページで、本文はいつも左に来る")
    func bookletRight() {
        let plan = plan(8, placement: .spreadRight)
        #expect(plan.pages.count == 17)
        #expect(plan.notePages == [0, 2, 4, 6, 8, 10, 12, 14, 16])
        #expect(plan.bodyPageIndices == [1, 3, 5, 7, 9, 11, 13, 15])
    }

    @Test("見開きの片側なら本文はどこも同じ側で、右ページ始まりの白紙は入らない")
    func spreadsTakeNoBlanks() {
        let plan = plan(4, starts: [1, 2], placement: .spreadLeft)
        #expect(plan.blankPages.isEmpty)
        #expect(plan.bodyPageIndices == [0, 2, 4, 6])
    }

    @Test("目次は本文の前に置き、本文はノートの反対側に並ぶ")
    func contentsStayInFront() {
        let plan = plan(2, contents: 1, placement: .spreadRight)
        #expect(plan.pages == [.contents(0), .body(0), .note, .body(1), .note])
        #expect(plan.bodyPageIndices == [1, 3])
    }

    @Test("章の終わりのノートが入ると、次の章の右ページ始まりは数え直す")
    func chapterEndCountsAgain() {
        let plan = plan(4, starts: [1, 2], placement: .chapterEnd, ends: [0, 1])
        // 本文1・ノート・本文2（右）・ノート・本文3（右）・本文4・ノート
        #expect(plan.pages == [.body(0), .note, .body(1), .note, .body(2), .body(3), .note])
        #expect(plan.bodyPageIndices == [0, 2, 4, 5])
    }

    @Test("章の終わりのあとに右ページへ送るときは白紙を足す")
    func chapterEndWithBlank() {
        let plan = plan(3, starts: [2], placement: .chapterEnd, ends: [1])
        #expect(plan.pages == [.body(0), .body(1), .note, .blank, .body(2), .note])
        #expect(plan.blankPages == [3])
    }

    @Test("中綴じの式に n=8 のノートつきの列をそのまま渡せる")
    func imposition() {
        let plan = plan(4, placement: .spreadLeft)
        #expect(plan.pages.count == 8)
        let imposed = Imposition.plan(pageCount: plan.pages.count, layout: .a4BookletA5)
        #expect(imposed.sheetCount == 2)
        // 用紙1 表[8|1] 裏[2|7]、用紙2 表[6|3] 裏[4|5]（1 始まり）。左がノートなので、左はいつも偶数のノート
        #expect(imposed.sides.map(\.slots) == [[7, 0], [1, 6], [5, 2], [3, 4]])
        #expect(plan.notePages == [1, 3, 5, 7])
    }

    @Test("3枚＋メモのレイアウトにはノートを入れない")
    func handout() {
        #expect(!NotePages().applies(to: .a4Handout3))
        #expect(NotePages().applies(to: .a4BookletA5))
        #expect(NotePages().applies(to: .a3TwoUp))
    }

    @Test("文書の記録はノートを覚え、以前の記録はノートなしのまま読める")
    func settingsRecord() throws {
        var notes = NotePages(isEnabled: true, placement: .chapterEnd, presetID: "ichigo")
        notes.style.spacingInMillimeters = 9
        let saved = DocumentSettings(zoom: 2, notes: notes)
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(saved))
        #expect(decoded.notes == notes)
        let old = try JSONDecoder().decode(DocumentSettings.self, from: Data(#"{"zoom":2}"#.utf8))
        #expect(old.notes == nil)
        #expect(old.zoom == 2)
    }

    @Test("知らない入れ方の記録でも線の設定を失わない")
    func unknownPlacement() throws {
        let json = #"""
            {"isEnabled":true,"placement":"halfPage","presetID":"mine","style":{"kind":"grid","spacingInMillimeters":6}}
            """#
        let notes = try JSONDecoder().decode(NotePages.self, from: Data(json.utf8))
        #expect(notes.isEnabled)
        #expect(notes.placement == .spreadRight)
        #expect(notes.presetID == "mine")
        #expect(notes.style.kind == .grid)
        #expect(notes.style.spacingInMillimeters == 6)
    }

    @Test("文書の記録の中のノートが壊れていても他の設定は残る")
    func brokenNotes() throws {
        let saved = try JSONDecoder().decode(DocumentSettings.self, from: Data(#"{"zoom":3,"notes":12}"#.utf8))
        #expect(saved.zoom == 3)
        #expect(saved.notes == nil)
    }

    @Test("設定セットはノートを含み、以前のセットはノートに触らない")
    func settingSets() throws {
        let notes = NotePages(isEnabled: true, placement: .duplexBack, presetID: "hougan")
        let set = PrintSettingSet(name: "ノートつき", settings: DocumentSettings(layoutID: "a4Duplex", notes: notes))
        let decoded = try JSONDecoder().decode(PrintSettingSet.self, from: JSONEncoder().encode(set))
        #expect(decoded.notes == notes)
        #expect(set.matches(DocumentSettings(layoutID: "a4Duplex", notes: notes)))
        #expect(!set.matches(DocumentSettings(layoutID: "a4Duplex")))
        let old = try JSONDecoder().decode(
            PrintSettingSet.self,
            from: Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"前の","layoutID":"a4Duplex"}"#.utf8))
        #expect(old.notes == nil)
        #expect(old.matches(DocumentSettings(layoutID: "a4Duplex", notes: notes)))
    }

    @Test("組み込みの設定セットはノートなしで、ノートのある文書とは一致しない")
    func builtInSetsHaveNoNotes() throws {
        let set = try #require(PrintSettingSet.builtIns(language: "ja").last)
        #expect(set.notes == NotePages())
        let options = PrintOptions()
        var finish = PrintFinish()
        finish.toc.mode = .hidden
        var settings = DocumentSettings(layoutID: "a4Single", printOptions: options, printFinish: finish)
        #expect(set.matches(settings))
        settings.notes = NotePages(isEnabled: true)
        #expect(!set.matches(settings))
    }

    @Test("細く淡い線だけに注意を出す")
    func faintLines() {
        var style = NotePaperStyle(kind: .ruled, weightInMillimeters: 0.15, colorHex: "#E59AAE")
        #expect(style.isFaint)
        style.weightInMillimeters = 0.3
        #expect(!style.isFaint)
        style = NotePaperStyle(kind: .ruled, weightInMillimeters: 0.15, colorHex: "#2B4C6F")
        #expect(!style.isFaint)
        style = NotePaperStyle(kind: .plain, weightInMillimeters: 0.1, colorHex: "#E59AAE")
        #expect(!style.isFaint)
    }

    @Test("組み込みのプリセットの線の色はすべて色の一覧にある")
    func paletteCoversPresets() {
        let colors = Set(NotePaperStyle.palette.map(\.hex))
        for preset in NotePaperPreset.all { #expect(colors.contains(preset.style.colorHex), "\(preset.id)") }
    }
}

struct ChapterEndTests {
    private func heading(_ level: Int, _ text: String) -> DocumentHeading { DocumentHeading(level: level, text: text) }

    @Test("章がページの頭で始まれば、前のページが前の章の終わりになる")
    func chapterOpensPage() {
        let headings = [heading(1, "第一章"), heading(1, "第二章"), heading(1, "第三章")]
        let texts = ["第一章\n本文", "続き", "第二章\n本文", "続き", "第三章\n本文"]
        #expect(DocumentOutline.chapterEnds(of: headings, pages: [0, 2, 4], inPageTexts: texts) == [1, 3])
    }

    @Test("章がページの途中で始まれば、そのページが前の章の終わりになる")
    func chapterInsidePage() {
        let headings = [heading(1, "第一章"), heading(1, "第二章")]
        let texts = ["第一章\n本文", "続き\n第二章\n本文"]
        #expect(DocumentOutline.chapterEnds(of: headings, pages: [0, 1], inPageTexts: texts) == [1])
    }

    @Test("文書の題の h1 が 1 つだけなら、その下の見出しを章とする")
    func titleOverChapters() {
        let headings = [heading(1, "題"), heading(2, "一"), heading(3, "節"), heading(2, "二")]
        let texts = ["題\n一\n節", "二\n本文"]
        #expect(DocumentOutline.chapterEnds(of: headings, pages: [0, 0, 0, 1], inPageTexts: texts) == [0])
    }

    @Test("テーマが番号を付けた見出しでも章の頭だと分かる")
    func numberedHeading() {
        let headings = [heading(1, "はじめに"), heading(1, "本論")]
        let texts = ["1. はじめに\n本文", "第2章 本論\n本文"]
        #expect(DocumentOutline.chapterEnds(of: headings, pages: [0, 1], inPageTexts: texts) == [0])
    }

    @Test("ページの見つからない見出しは飛ばす")
    func missingPage() {
        let headings = [heading(1, "一"), heading(1, "二"), heading(1, "三")]
        #expect(DocumentOutline.chapterEnds(of: headings, pages: [0, nil, 2], inPageTexts: ["一", "", "三"]) == [1])
    }

    @Test("PDF のしおりは一番上の階層を章とする")
    func bookmarks() {
        let entries = [
            OutlineEntry(level: 1, title: "一", pageIndex: 0), OutlineEntry(level: 2, title: "節", pageIndex: 1),
            OutlineEntry(level: 1, title: "二", pageIndex: 3), OutlineEntry(level: 1, title: "三", pageIndex: 5),
        ]
        #expect(DocumentOutline.chapterEnds(of: entries) == [2, 4])
    }

    @Test("見出しがなければ章の終わりもない")
    func noHeadings() {
        #expect(DocumentOutline.chapterEnds(of: [], pages: [], inPageTexts: ["本文"]).isEmpty)
    }
}

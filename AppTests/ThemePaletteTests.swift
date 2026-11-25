import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import Surimono

@MainActor
struct ThemePaletteTests {
    private func library() -> UserLibrary {
        UserLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    /// A renderer whose logical pages say which renderer made them by their count.
    private func renderer(pages: Int) -> DocumentRenderer {
        DocumentRenderer(paginate: { _ in
            PDFDocument(data: TestFixtures.pdf("theme-palette-\(pages)", pages: pages)) ?? PDFDocument()
        })
    }

    private func model(_ suite: TestDefaultsSuite, format: DocumentFormat = .markdown) -> DocumentViewModel {
        DocumentViewModel(
            data: Data("# Palette fixture".utf8), fileURL: nil, format: format,
            preferences: AppPreferences(defaults: suite.defaults), library: library(), renderer: renderer(pages: 1),
            trialRenderer: renderer(pages: 3))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("移動先には表示中の区分だけが紙面と同じ順に並び、検索中はなくなる")
    func jumpTargets() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        let categoryIDs = [
            "everyday", "japanese", "business", "academic", "tech", "reading", "notes", "printing",
            "retro", "pop", "seasons", "kids",
        ].map { "category:" + $0 }
        #expect(ThemePalette.browsingSections(for: "", model: model)?.map(\.id) == ["featured"] + categoryIDs)
        model.preferences.recordThemeChoice("mincho")
        model.toggleFavoriteTheme("modern")
        let groups = ThemePalette.browsingSections(for: " ", model: model)
        #expect(groups?.map(\.id) == ["recent", "favorites", "featured"] + categoryIDs)
        #expect(groups == model.themeMenu.sections)
        #expect(ThemePalette.browsingSections(for: "明朝", model: model) == nil)
    }

    @Test("試しのキャッシュから追い出し紙を作り直してもリンク注釈の元を残す", .timeLimit(.minutes(1)))
    func evictedTrialCanBeShownAgain() async throws {
        let previous = WebPaginator.clearBackground
        WebPaginator.clearBackground = { _ in }
        defer { WebPaginator.clearBackground = previous }
        weak var backing: CGPDFDocument?
        var bodyCount = 0
        let renderer = DocumentRenderer(paginateWithResult: { request in
            try autoreleasepool {
                let document = try #require(PDFDocument(data: TestFixtures.pdf("trial links", pages: 1)))
                if !request.drawsBackground {
                    bodyCount += 1
                    let page = try #require(document.page(at: 0))
                    let annotation = PDFAnnotation(
                        bounds: CGRect(x: 30, y: 40, width: 100, height: 20), forType: .link, withProperties: nil)
                    annotation.url = URL(string: "https://example.com/")
                    page.addAnnotation(annotation)
                    let data = try #require(document.dataRepresentation())
                    let source = try #require(PDFDocument(data: data))
                    if bodyCount == 1 { backing = source.page(at: 0)?.pageRef?.document }
                    return WebPaginator.Result(document: source, preparationResult: "paper")
                }
                return WebPaginator.Result(document: document)
            }
        })
        let trial = ThemeTrial(renderer: renderer)
        defer { trial.clear() }
        let source = DocumentSource(data: Data("# Trial links".utf8), format: .markdown)
        var settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "first", name: "First", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        trial.begin(source: source, settings: settings, isBusy: { false })
        try await waitUntil { trial.document != nil }
        let paperDocument = try #require(trial.document)
        for index in 1...6 {
            settings.theme = PrintTheme(id: "trial-\(index)", name: "Trial", css: "")
            trial.begin(source: source, settings: settings, isBusy: { false })
            try await waitUntil { trial.document != nil }
        }
        #expect(bodyCount == 7)
        settings.theme = PrintTheme(id: "first", name: "First", css: "")
        trial.begin(source: source, settings: settings, isBusy: { false })
        #expect(trial.document == nil)
        trial.clear()
        try #require(backing != nil)
        let paper = PaperPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        paper.configure(
            paperDocument, at: 0,
            options: ViewOptions(layout: .spread, scrollAxis: .horizontal, transition: .instant, showsCoverAlone: true),
            logicalMargin: nil, showsPageNumbers: false)
        #expect(paper.document?.pageCount == 2)
        #expect(paper.document?.page(at: 1)?.annotations.first?.url?.absoluteString == "https://example.com/")
    }

    @Test("パレットの星は、いまのスタイルを変えずに、そのテーマのお気に入りを切り替える")
    func starsAnyTheme() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.toggleFavoriteTheme("mincho")
        #expect(model.preferences.favoriteThemeIDs == ["mincho"])
        #expect(model.isFavoriteTheme("mincho"))
        #expect(model.themeID == "standard")
        model.toggleFavoriteTheme("mincho")
        #expect(model.preferences.favoriteThemeIDs.isEmpty)
    }

    @Test("乗せたテーマを紙で試し、離すと文書のページに戻り、同じテーマはすぐにまた出る", .timeLimit(.minutes(1)))
    func triesAThemeOnThePaper() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.render()
        try await waitUntil { model.result != nil && !model.isRendering }
        let own = try #require(model.result?.logicalDocument)

        model.tryTheme("mincho")
        #expect(model.trialThemeName != nil)
        try await waitUntil { model.themeTrial.document != nil }
        #expect(model.paperDocument?.pageCount == 3)
        #expect(model.themeID == "standard")

        model.endThemeTrial()
        #expect(model.paperDocument === own)
        #expect(model.trialThemeName == nil)

        model.tryTheme("mincho")
        #expect(model.themeTrial.document != nil)
        model.tryTheme("standard")
        #expect(model.themeTrial.themeID == nil)
        #expect(model.paperDocument === own)
    }

    @Test("混植原稿の試し刷りと選択後の A4 に文末注が載る", .timeLimit(.minutes(1)))
    func mixedVerticalEndnote() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let source = #"""
            # 第三章 混ぜ書き

            吾輩は試し刷りの文章である。「名前はまだ無い。」（どこで刷られたか）、とんと見当がつかぬ。

            ## 表とコード

            次の表は横組みのまま置く。

            | 用紙 | 段 | 字数 | 行数 |
            |---|---|---|---|
            | A4 | 2 | 30 | 24 |
            | A5 | 1 | 42 | 18 |

            ```swift
            let pages = paginate(document, paper: .a4)
            print("pages: \(pages.count)")
            ```

            - 一つ目の項目は少し長くして、二行目がぶら下がるかを確かめるための文章である。
            - 二つ目
              - 入れ子

            1. 番号の一
            2. 番号の二

            > 引用は一字下げて右に罫を引く。

            *強調*と *emphasis* と `code` と{漢字|かんじ}、脚注[^a]。数式 $E=mc^2$ と

            $$\int_0^1 x^2\,dx=\frac13$$

            [^a]: 脚注は文書の終わりに置く。

            """#
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mix-2.md")
        try Data(source.utf8).write(to: url)
        let opened = try SurimonoDocument(
            file: FileWrapper(url: url, options: .immediate), contentType: #require(UTType(filenameExtension: "md")))
        let format = try #require(opened.format)
        #expect(format == .markdown)
        let model = DocumentViewModel(
            data: opened.data, fileURL: url, format: format,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        defer { model.closeWindow() }
        let settings = try #require(model.renderSettings)
        #expect(settings.layout == .a4Single && settings.textScale == 1)
        #expect(settings.options.margins == .uniform(15))
        func checkNote() throws {
            let document = try #require(model.paperDocument)
            let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
                .filter { !$0.isWhitespace }
            #expect(text.components(separatedBy: "脚注は文書の終わりに置く。").count == 2)
        }
        model.render()
        try await waitUntil { model.result != nil && !model.isRendering }
        let original = try #require(model.paperDocument)
        model.hoverPaletteTheme("tategaki")
        try await waitUntil { model.themeTrial.document != nil }
        #expect(model.paperShowsTrial)
        try checkNote()
        model.endThemeTrial()
        model.selectTheme("tategaki")
        model.render()
        try await waitUntil { !model.isRendering && model.paperDocument === model.result?.logicalDocument }
        #expect(model.error == nil && model.paperDocument !== original && !model.paperShowsTrial)
        try checkNote()
    }

    #if DEBUG
        @Test("二枚目を指定した撮影は一枚の元文書から試しの PDF に切り替わり、指定ページが見えるまで待つ", .timeLimit(.minutes(1)))
        func snapshotTrialPage() async throws {
            let suite = TestDefaultsSuite()
            defer { suite.remove() }
            let model = model(suite)
            let controller = MemoryDocumentWindowController(model: model, onClose: {})
            defer { controller.close() }
            model.viewOptions.layout = .single
            model.render()
            try await waitUntil { model.result != nil && !model.isRendering && model.paper.isConnected }
            model.tryTheme("tategaki")
            try await DebugSnapshot.showTrialPage(2, of: "tategaki", in: model)
            try await waitUntil { model.pageIndicator == "2 / 3" }
            #expect(model.currentPageIndex == 0)
        }
    #endif

    @Test("元の一枚を縦書きで試すと帯から試しの最終ページに移れ、試しを終えると元の一枚に戻る", .timeLimit(.minutes(1)))
    func verticalTrialPageTurns() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.viewOptions.layout = .single
        model.render()
        try await waitUntil { model.result != nil && !model.isRendering }
        model.tryTheme("tategaki")
        try await waitUntil { model.themeTrial.document != nil }
        let document = try #require(model.paperDocument)
        let host = NSHostingView(
            rootView: PaperView(
                document: document, initialPageIndex: 0, options: model.viewOptions, zoom: 1, controller: model.paper,
                onZoomChange: { _ in }, onPageChange: model.paperDidChangePage, onTurn: {}, onKey: { _ in false }))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await waitUntil { model.paper.isConnected }
        #expect(model.pageIndicator == "1 / 3")
        #expect(BandLayout.Item.applicable(for: model).contains(.pageTurn))
        model.paper.turnPage(forward: true)
        try await waitUntil { model.pageIndicator == "2 / 3" }
        model.goToPage(entered: "3")
        try await waitUntil { model.pageIndicator == "3 / 3" }
        #expect(model.currentPageIndex == 0)
        model.endThemeTrial()
        #expect(model.pageIndicator == "1 / 1")
        #expect(!BandLayout.Item.applicable(for: model).contains(.pageTurn))
    }

    @Test("試しているテーマを選ぶと、文書のページがそのテーマで組み上がるまで試しのページを出し続ける", .timeLimit(.minutes(1)))
    func choosingKeepsTheTrialUntilTheRenderIsDone() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.render()
        try await waitUntil { model.result != nil && !model.isRendering }
        model.tryTheme("mincho")
        try await waitUntil { model.themeTrial.document != nil }
        let trial = try #require(model.themeTrial.document)

        model.selectTheme("mincho")
        #expect(model.themeTrial.themeID == nil)
        #expect(model.paperDocument === trial)
        #expect(model.preferences.recentThemeIDs == ["mincho"])
        model.render()
        try await waitUntil { !model.isRendering }
        #expect(model.paperDocument === model.result?.logicalDocument)
        #expect(model.paperDocument?.pageCount == 1)
    }

    @Test("試しのページが出ているあいだは、読んでいるページを書き換えない", .timeLimit(.minutes(1)))
    func trialsLeaveTheReadingPosition() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = DocumentViewModel(
            data: Data("# Reading position fixture".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: library(), renderer: renderer(pages: 10),
            trialRenderer: renderer(pages: 3))
        model.render()
        try await waitUntil { model.result != nil && !model.isRendering }
        model.paperDidChangePage(8)
        #expect(model.currentPageIndex == 8)

        model.tryTheme("mincho")
        try await waitUntil { model.themeTrial.document != nil }
        #expect(model.paperShowsTrial)
        // The trial has three pages, so the paper turns to its last one.
        model.paperDidChangePage(2)
        #expect(model.currentPageIndex == 8)
        // Going to the print tray now keeps the reading position for coming back.
        model.enterPrintMode()
        #expect(model.currentPageIndex == 8)
        model.exitPrintMode()

        model.endThemeTrial()
        #expect(!model.paperShowsTrial)
        model.paperDidChangePage(3)
        #expect(model.currentPageIndex == 3)
    }

    @Test("試しのページが表紙になったら窓も表紙 1 ページの幅になり、試しを終えると読んでいた見開きに戻る", .timeLimit(.minutes(1)))
    func trialCoverWidthFollowsTheShownPage() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = DocumentViewModel(
            data: Data("# Cover width fixture".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: library(), renderer: renderer(pages: 10),
            trialRenderer: renderer(pages: 1))
        model.render()
        try await waitUntil { model.result != nil && !model.isRendering }
        model.viewOptions = ViewOptions(
            layout: .spread, scrollAxis: .horizontal, transition: .slide, showsCoverAlone: true)
        model.paperDidChangePage(5)
        #expect(!model.showsNarrowCover)

        model.tryTheme("mincho")
        try await waitUntil { model.themeTrial.document != nil }
        #expect(model.paperShowsTrial)
        // A one-page trial can only show its cover.
        model.paperDidChangePage(0)
        #expect(model.showsNarrowCover)
        #expect(model.currentPageIndex == 5)

        model.endThemeTrial()
        model.paperDidChangePage(5)
        #expect(!model.showsNarrowCover)
        #expect(model.currentPageIndex == 5)
    }

    @Test("組版に時間のかかる文書では、乗せてもテーマを試さない", .timeLimit(.minutes(1)))
    func longDocumentsDoNotTryOnHover() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.hoverTrialLimit = .zero
        model.render()
        try await waitUntil { model.result != nil && !model.isRendering }
        #expect(!model.canTryThemesOnHover)
        model.tryTheme("mincho")
        #expect(model.themeTrial.themeID == nil)
    }

    @Test("見比べ台には、いまのスタイルを先頭に定番が並び、表示へ戻れる")
    func comparisonStage() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.openThemePalette()
        #expect(model.isThemePalettePresented)
        model.enterCompareMode()
        #expect(model.mode == .compare)
        #expect(!model.isThemePalettePresented)
        let candidates = model.themeComparison?.candidates ?? []
        #expect(candidates.count == ThemeComparison.capacity)
        #expect(candidates.first == "standard")
        #expect(candidates.dropFirst().allSatisfy { model.theme($0)?.featuredRank != nil })
        // ⌘P on the stage opens the tray rather than printing.
        #expect(model.printCommand == .enterPrintMode)

        model.selectTheme(candidates[2])
        #expect(model.themeComparison?.current == candidates[2])
        model.exitCompareMode()
        #expect(model.mode == .view)
    }

    @Test("見比べ台に戻ると、そのあと選んだスタイルを先頭に、前に足した候補を残して並べ直す")
    func comparisonKeepsEarlierChoices() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.enterCompareMode()
        model.themeComparison?.toggle("confetti")
        model.exitCompareMode()
        model.selectTheme("grid")
        model.enterCompareMode()
        let candidates = model.themeComparison?.candidates ?? []
        #expect(candidates.first == "grid")
        #expect(candidates.contains("confetti"))
        #expect(model.themeComparison?.current == "grid")
    }

    @Test("パレットを開いたまま文字の大きさを変えると、見えている見本を描き直す", .timeLimit(.minutes(1)))
    func samplesFollowTheTextSize() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        let standard = try #require(model.theme("standard"))
        await model.themeSamples.load(standard)
        let first = try #require(model.themeSamples.page(for: standard))
        let drawing = model.themeSamples.taskID(for: standard)

        model.setTextScale(1.5)
        model.followThemeSamples()
        #expect(model.themeSamples.taskID(for: standard) != drawing)
        #expect(model.themeSamples.page(for: standard) == nil)
        await model.themeSamples.load(standard)
        let larger = try #require(model.themeSamples.page(for: standard))
        #expect(larger.characterBounds(at: 0).height > first.characterBounds(at: 0).height * 1.3)
    }

    @Test("中身の変わった同じ名前のテーマや、読み込み直した文書には、前の見本を出さない", .timeLimit(.minutes(1)))
    func samplesDoNotOutliveTheirSource() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        let standard = try #require(model.theme("standard"))
        await model.themeSamples.load(standard)
        #expect(model.themeSamples.page(for: standard) != nil)

        let edited = PrintTheme(
            id: standard.id, name: standard.name, css: standard.css + "\nbody { color: #c00; }", isBuiltIn: true,
            category: standard.category)
        #expect(model.themeSamples.page(for: edited) == nil)
        #expect(model.themeSamples.taskID(for: edited) != model.themeSamples.taskID(for: standard))

        let drawing = model.themeSamples.taskID(for: standard)
        model.reload()
        #expect(model.themeSamples.taskID(for: standard) != drawing)
        #expect(model.themeSamples.page(for: standard) == nil)
    }

    @Test("テーマを使わない形式では、パレットも見比べ台も開かない")
    func unthemedFormatsOpenNeither() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite, format: .pdf)
        model.openThemePalette()
        model.enterCompareMode()
        #expect(!model.isThemePalettePresented)
        #expect(model.mode == .view)
        #expect(model.themedSource == nil)
    }
}

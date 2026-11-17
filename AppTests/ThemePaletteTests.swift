import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

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

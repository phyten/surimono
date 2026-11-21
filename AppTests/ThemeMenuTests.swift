import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct ThemeMenuTests {
    private func library() -> UserLibrary {
        UserLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test("スライド原稿のスタイルは帯・刷り台・パレットで同じ名前になり、文書用の候補と混ざらない")
    func deckStyle() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let names = library()
        let deck = DocumentViewModel(
            data: Data(#"\documentclass{beamer}\begin{document}\frame{Low tide}\end{document}"#.utf8),
            fileURL: nil, format: .latex, preferences: preferences, library: names)
        #expect(deck.themeID == "latex-beamer")
        let slides = try #require(deck.theme(deck.themeID))
        #expect(
            UILanguage.supported.map { slides.displayName(language: $0) } == [
                "Slides", "スライド", "幻灯片", "投影片", "슬라이드", "Diapositives", "Folien", "Diapositivas",
            ])
        deck.restoreClosedDocument(DocumentSettings(themeID: "latex-article"))
        #expect(deck.themeID == "latex-beamer")
        #expect(deck.themeMenu.sections.first?.themes.map(\.id) == ["latex-beamer"])
        #expect(deck.searchThemes("latex-article").isEmpty)
        deck.selectTheme("latex-report")
        #expect(deck.themeID == "latex-beamer")
        deck.selectTheme("standard")
        #expect(deck.themeID == "standard")
        deck.selectTheme("latex-beamer")
        preferences.toggleFavoriteTheme("latex-beamer")
        let article = DocumentViewModel(
            data: Data(#"\documentclass{article}"#.utf8), fileURL: nil, format: .latex,
            preferences: preferences, library: names)
        #expect(article.themeID == "latex-article")
        #expect(article.theme("latex-beamer") == nil)
        #expect(article.themeMenu.sections.allSatisfy { !$0.themes.contains(slides) })
        #expect(article.searchThemes("Slides").isEmpty)
        let sample = ThemeSpecimen.source(language: "en", format: .latex, classStyle: deck.classStyle)
        #expect(DocumentRenderer().latexClassInfo(for: sample).beamerPageSize != nil)
    }

    @Test("最近使ったテーマは新しい順に重複なく5つまで別のインスタンスにも残る")
    func recentThemesPersist() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        for id in ["standard", "mincho", "modern", "github", "report", "bunko", "mincho"] {
            preferences.recordThemeChoice(id)
        }
        #expect(
            AppPreferences(defaults: suite.defaults).recentThemeIDs == [
                "mincho", "bunko", "report", "github", "modern",
            ])
    }

    @Test("お気に入りは切り替えるたびに足し外しされ別のインスタンスにも残る")
    func favoriteThemesPersist() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.toggleFavoriteTheme("mincho")
        preferences.toggleFavoriteTheme("github")
        preferences.toggleFavoriteTheme("bunko")
        preferences.toggleFavoriteTheme("github")
        #expect(AppPreferences(defaults: suite.defaults).favoriteThemeIDs == ["mincho", "bunko"])
    }

    @Test("メニューでテーマを選ぶと最近使ったテーマに入る")
    func selectingRecords() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown, preferences: preferences, library: library())
        model.selectTheme("mincho")
        #expect(model.themeID == "mincho")
        #expect(preferences.recentThemeIDs == ["mincho"])
    }

    @Test("文書の設定を既定に戻しても最近使ったテーマに入らない")
    func resettingDoesNotRecord() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.themeID = "bunko"
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown, preferences: preferences, library: library())
        model.themeID = "modern"
        model.resetDocumentSettings()
        #expect(model.themeID == "bunko")
        #expect(preferences.recentThemeIDs.isEmpty)
    }

    @Test("文書ごとに保存したテーマを復元しても最近使ったテーマに入らない", .timeLimit(.minutes(1)))
    func restoringDoesNotRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = TestDefaultsSuite()
        defer {
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
        let preferences = AppPreferences(defaults: suite.defaults)
        let store = DocumentSettingsStore(directory: directory.appendingPathComponent("Settings"))
        let data = Data("# Restored theme fixture".utf8)
        try store.save(DocumentSettings(themeID: "bunko"), for: ContentHash.of(data).hex)
        let model = DocumentViewModel(
            data: data, fileURL: nil, format: .markdown, preferences: preferences,
            library: UserLibrary(root: directory.appendingPathComponent("Library")),
            renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: TestFixtures.pdf("Theme", pages: 1))! }),
            settingsStore: store)
        defer { model.stop() }
        model.start()
        for _ in 0..<500 where model.themeID != "bunko" || model.isRendering {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.themeID == "bunko")
        #expect(preferences.recentThemeIDs.isEmpty)
    }

    @Test("お気に入りの切り替えは表示中のテーマを対象にする")
    func favoriteCurrentTheme() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown, preferences: preferences, library: library())
        model.themeID = "github"
        #expect(!model.isFavoriteTheme)
        model.toggleFavoriteTheme()
        #expect(model.isFavoriteTheme)
        #expect(preferences.favoriteThemeIDs == ["github"])
        #expect(preferences.recentThemeIDs.isEmpty)
    }

    @Test("テーマのメニューは最近使った・お気に入り・定番・分類の順に並ぶ")
    func menuSections() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown, preferences: preferences, library: library())
        model.selectTheme("bunko")
        model.selectTheme("modern")
        preferences.toggleFavoriteTheme("github")
        let sections = model.themeMenu.sections
        try #require(sections.count >= 4)
        #expect(sections[0].kind == .recent)
        #expect(sections[0].themes.map(\.id) == ["modern", "bunko"])
        #expect(sections[1].kind == .favorites)
        #expect(sections[1].themes.map(\.id) == ["github"])
        #expect(sections[2].kind == .featured)
        #expect(sections[2].themes.first?.id == "standard")
        #expect(sections[2].themes.map(\.id).contains("mincho"))
        guard case .category(let first) = sections[3].kind else {
            Issue.record("The fourth section is not a category")
            return
        }
        #expect(first.id == "everyday")
        #expect(!sections.contains { $0.kind == .user })

        let tex = DocumentViewModel(
            data: Data(), fileURL: nil, format: .latex, preferences: preferences, library: model.library)
        tex.selectTheme("latex-report")
        tex.toggleFavoriteTheme()
        let latexSections = tex.themeMenu.sections
        try #require(latexSections.count >= 4)
        #expect(
            latexSections[0].themes.map(\.id) == [
                "latex-article", "latex-report", "latex-plain-ja", "latex-plain-zh", "latex-plain-ko",
            ])
        #expect(latexSections[1].kind == .recent)
        #expect(latexSections[1].themes.first?.id == "latex-report")
        #expect(latexSections[2].kind == .favorites)
        #expect(latexSections[3].kind == .featured)
        #expect(model.themeMenu.sections == sections)
    }
}

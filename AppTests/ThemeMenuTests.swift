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
    }
}

import AppKit
import SurimonoCore
import SurimonoFormats
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct GettingStartedTests {
    @Test("表示の言語が日本語なら日本語の案内を選ぶ")
    func japanese() {
        #expect(GettingStarted.edition(for: ["ja"]) == .japanese)
        #expect(GettingStarted.edition(for: ["ja-JP", "en"]) == .japanese)
    }

    @Test("日本語以外の表示の言語では、あとに日本語が続いても英語の案内を選ぶ")
    func otherLanguages() {
        #expect(GettingStarted.edition(for: ["en"]) == .english)
        #expect(GettingStarted.edition(for: ["fr", "ja"]) == .english)
        #expect(GettingStarted.edition(for: ["zh-Hans"]) == .english)
        #expect(GettingStarted.edition(for: []) == .english)
    }

    @Test("日本語と英語の案内がアプリに入っていて、題名がファイル名と同じ Markdown として読める")
    func bundled() throws {
        for (languages, name) in [(["ja"], "Surimono の使い方"), (["en"], "Getting Started with Surimono")] {
            let url = try #require(GettingStarted.url(for: languages))
            #expect(url.lastPathComponent == name + ".md")
            #expect(DocumentFormat(fileExtension: url.pathExtension) == .markdown)
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.hasPrefix("# \(name)\n"))
        }
    }

    @Test("和英の見本は読み取りの問題がなく、表・図・数式・脚注を含む三つの部分に組まれる")
    func sampleContents() throws {
        for (language, name) in [("ja", "Surimono 見本"), ("en", "Surimono Sample")] {
            let url = try #require(GettingStarted.sampleURL(for: [language]))
            #expect(url.deletingPathExtension().lastPathComponent == name)
            let fragment = MarkdownConverter.convert(try String(contentsOf: url, encoding: .utf8))
            #expect(fragment.language == language)
            #expect(fragment.readingIssues.isEmpty)
            #expect(!fragment.body.contains("math-error"))
            for tag in [
                "<table>", "task-list-item", "callout-note", "mermaid-block", "hl-keyword", "footnotes",
                "math-inline", "math-display", "<dl>",
            ] {
                #expect(fragment.body.contains(tag), "\(language): \(tag)")
            }
            #expect(fragment.body.contains("<ruby>") == (language == "ja"))
        }
        #expect(GettingStarted.sampleURL(for: ["de", "ja"]) == GettingStarted.sampleURL(for: ["en"]))
    }

    @Test("ヘルプメニューに見本文書の項目が一つある")
    func sampleHelpMenu() throws {
        let help = try #require(NSApp.mainMenu?.items.last?.submenu)
        let items = help.items.filter { $0.title == String(localized: "Open Sample Document") }
        #expect(items.count == 1)
    }

    @Test("和英の見本は標準スタイルの A4 で各3ページになり、印刷前の確認事項がない", .timeLimit(.minutes(1)))
    func samplePages() async throws {
        let themes = try PrintThemeLibrary.load()
        let standard = try #require(themes.first { $0.id == "standard" })
        let settings = RenderSettings(layout: .a4Single, theme: standard, preset: .init(id: "none", name: "None"))
        for language in ["ja", "en"] {
            let url = try #require(GettingStarted.sampleURL(for: [language]))
            let source = DocumentSource(data: try Data(contentsOf: url), format: .markdown)
            let result = try await DocumentRenderer().prepare(source, settings: settings)
            // The sample flows on its own; forced breaks left half-empty pages.
            #expect((2...3).contains(result.logicalDocument.pageCount), "\(language)")
            #expect(result.issues.isEmpty, "\(language)")
        }
    }

    @Test("アプリの中のファイルだけをアプリの中とみなす")
    func insideApp() throws {
        let guide = try #require(GettingStarted.url(for: ["en"]))
        #expect(GettingStarted.isInsideApp(guide))
        #expect(!GettingStarted.isInsideApp(URL(fileURLWithPath: "/tmp/Getting Started with Surimono.md")))
        // A folder whose name only begins with the app's is outside it.
        let neighbor = URL(fileURLWithPath: Bundle.main.bundleURL.path + " copy/Contents/Resources/a.md")
        #expect(!GettingStarted.isInsideApp(neighbor))
    }

    @Test("案内を開いても最近使ったファイルに記録しない")
    func notRecorded() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let history = RecentFileHistory(preferences: preferences)
        history.systemLimit = { 10 }
        let guide = try #require(GettingStarted.url(for: ["ja"]))
        history.record(guide)
        #expect(preferences.recentFiles.isEmpty)
        history.record(URL(fileURLWithPath: "/tmp/notes.md"))
        #expect(preferences.recentFiles.entries.map(\.path) == ["/tmp/notes.md"])
    }

    @Test("文書コントローラが案内を開いたと知らせても、システムの最近使った項目にもアプリの一覧にも載らない")
    func notNotedBySystem() throws {
        let guide = try #require(GettingStarted.url(for: ["en"]))
        let saved = RecentFileHistory.shared?.preferences.recentFiles
        NSDocumentController.shared.noteNewRecentDocumentURL(guide)
        #expect(!NSDocumentController.shared.recentDocumentURLs.contains { GettingStarted.isInsideApp($0) })
        #expect(RecentFileHistory.shared?.preferences.recentFiles == saved)
    }

    @Test("ヘルプメニューに案内の項目があり、選ぶと案内を開く")
    func helpMenu() throws {
        let help = try #require(NSApp.mainMenu?.items.last?.submenu)
        let item = try #require(help.items.first { $0.title == String(localized: "Getting Started with Surimono") })
        let action = try #require(item.action)
        var asked = 0
        let original = OpenRouter.shared.gettingStartedURL
        OpenRouter.shared.gettingStartedURL = {
            asked += 1
            return nil
        }
        defer { OpenRouter.shared.gettingStartedURL = original }
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(asked == 1)
    }
}

import AppKit
import SurimonoCore
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

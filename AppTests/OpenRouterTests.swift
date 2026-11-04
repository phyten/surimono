import AppKit
import Testing

@testable import Surimono

@MainActor
struct OpenRouterTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixtures/" + name) }

    private func router(
        openDocument: @escaping (URL, @escaping (Bool) -> Void) -> Void = { _, _ in Issue.record("単独では開かない") },
        openBundle: @escaping ([URL], [URL]) -> Void = { _, _ in Issue.record("束は開かない") },
        openBinder: @escaping ([URL], [URL]) -> Void = { _, _ in Issue.record("合本は開かない") },
        warn: @escaping (NSWindow?) -> Void = { _ in Issue.record("警告しない") },
        hasOpenWindows: @escaping () -> Bool = { false },
        showWelcome: @escaping () -> Void = { Issue.record("ウェルカム画面は出さない") }
    ) -> OpenRouter {
        OpenRouter(
            openDocument: openDocument,
            openBundle: {
                openBundle($0, $1)
                return nil
            },
            openBinder: {
                openBinder($0, $1)
                return nil
            },
            warn: warn,
            hasOpenWindows: hasOpenWindows,
            showWelcome: showWelcome)
    }

    @Test("1つのファイルは文書を開く処理に渡す")
    func single() {
        var opened: [URL] = []
        let router = router(openDocument: { url, _ in opened.append(url) })
        router.open([url("a.pdf")])
        #expect(opened == [url("a.pdf")])
    }

    @Test("画像3つは自然順の束として開く")
    func bundle() {
        var opened: [URL] = []
        let router = router(openBundle: { urls, excluded in
            opened = urls
            #expect(excluded.isEmpty)
        })
        router.open([url("10.png"), url("2.jpg"), url("1.heic")])
        #expect(opened == [url("1.heic"), url("2.jpg"), url("10.png")])
    }

    @Test("画像とZIPの選択は除外一覧付きの画像の束として開き警告しない")
    func imagesWithExclusions() {
        var opened: [URL] = []
        var exclusions: [URL] = []
        let router = router(openBundle: { urls, excluded in
            opened = urls
            exclusions = excluded
        })
        router.open([url("b.zip"), url("a.png")])
        #expect(opened == [url("a.png")])
        #expect(exclusions == [url("b.zip")])
    }

    @Test("MarkdownとPDFは合本を開いて警告しない")
    func binder() {
        var opened: [URL] = []
        let router = router(openBinder: { urls, excluded in
            opened = urls
            #expect(excluded.isEmpty)
        })
        router.open([url("b.pdf"), url("a.md")])
        #expect(opened == [url("a.md"), url("b.pdf")])
    }

    @Test("対応する文書がないドロップは対象ウィンドウで警告する")
    func sheet() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        var parent: NSWindow?
        let router = router(warn: { parent = $0 })
        router.open([url("a.zip"), url("b.unknown")], from: window)
        #expect(parent === window)
    }

    @Test("対応する文書がなく何も開いていなければウェルカム画面を出す")
    func welcomeAfterRejection() {
        var welcomes = 0
        let router = router(warn: { _ in }, showWelcome: { welcomes += 1 })
        router.open([url("a.zip"), url("b.unknown")])
        router.showWelcomeIfIdle()
        #expect(welcomes == 1)
    }

    @Test("文書を開けず何も開いていなければウェルカム画面を出す")
    func welcomeAfterFailure() {
        var welcomes = 0
        let router = router(openDocument: { _, completion in completion(false) }, showWelcome: { welcomes += 1 })
        router.open([url("unreadable.pdf")])
        #expect(welcomes == 1)
    }

    @Test("ほかの文書を開いている途中ならウェルカム画面を出さない")
    func noWelcomeWhilePending() {
        var completions: [(Bool) -> Void] = []
        let router = router(openDocument: { _, completion in completions.append(completion) })
        router.open([url("a.pdf")])
        router.open([url("unreadable.pdf")])
        completions[1](false)
        router.showWelcomeIfIdle()
        #expect(router.pendingOpens == 1)
    }

    @Test("文書のウィンドウがあれば開けなかったときもウェルカム画面を出さない")
    func noWelcomeWithWindows() {
        let router = router(openDocument: { _, completion in completion(false) }, hasOpenWindows: { true })
        router.open([url("unreadable.pdf")])
        #expect(router.pendingOpens == 0)
    }

    @Test("3枚＋メモはレイアウトメニューのコマンド6で選べる")
    func handoutShortcut() throws {
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
            .flatMap { [$0] + ($0.submenu?.items ?? []) }
        let item = try #require(items.first { $0.keyEquivalent == "6" && $0.keyEquivalentModifierMask == .command })
        #expect(item.title.contains("3枚＋メモ") || item.title.contains("3-up + Notes"))
    }

    @Test("ファイルメニューの開く…は1つだけで、選ぶと振り分けの開くパネルが出る")
    func openMenu() throws {
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
        let openItems = items.filter { $0.action == #selector(NSDocumentController.openDocument(_:)) }
        #expect(openItems.count == 1)
        #expect(items.filter { $0.keyEquivalent == "o" && $0.keyEquivalentModifierMask == .command }.count == 1)
        #expect(!items.contains { $0.action == #selector(NSDocumentController.newDocument(_:)) })
        let item = try #require(openItems.first)
        let action = try #require(item.action)
        var panels = 0
        let original = OpenRouter.shared.presentOpenPanel
        OpenRouter.shared.presentOpenPanel = { _ in panels += 1 }
        defer { OpenRouter.shared.presentOpenPanel = original }
        let handled = NSApp.sendAction(action, to: item.target, from: item)
        #expect(handled)
        #expect(panels == 1)
    }

    @Test("open-documentsイベントの複数URLを分割せず取り出す")
    func appleEvent() {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenDocuments), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: url("2.png")), at: 1)
        list.insert(NSAppleEventDescriptor(fileURL: url("1.png")), at: 2)
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        #expect(AppDelegate.documentURLs(in: event) == [url("2.png"), url("1.png")])
    }
}

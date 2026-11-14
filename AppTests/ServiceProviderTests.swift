import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct ServiceProviderTests {
    private func board() -> NSPasteboard {
        NSPasteboard(name: .init("SurimonoTests.service.\(UUID().uuidString)"))
    }

    private var services: [[String: Any]] {
        Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]] ?? []
    }

    private func router(
        openDocument: @escaping (URL, @escaping (Bool) -> Void) -> Void = { _, _ in Issue.record("文書は開かない") },
        openBinder: @escaping ([URL], [URL]) -> DocumentViewModel? = { _, _ in
            Issue.record("合本は開かない")
            return nil
        },
        openMemory: @escaping (Data, DocumentFormat, String?, Bool) -> Void = { _, _, _, _ in Issue.record("メモリからは開かない")
        },
        openWindows: @escaping () -> [DocumentViewModel] = { [] }
    ) -> OpenRouter {
        OpenRouter(
            openDocument: openDocument,
            openBundle: { _, _ in
                Issue.record("束は開かない")
                return nil
            }, openBinder: openBinder,
            warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { false },
            showWelcome: { Issue.record("ウェルカム画面は出さない") }, openMemory: openMemory, openWindows: openWindows)
    }

    private func model(url: URL, suite: TestDefaultsSuite, library: URL) -> DocumentViewModel {
        DocumentViewModel(
            data: Data("# a".utf8), fileURL: url, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: library))
    }

    @Test("開発版のサービスは公開版と別の名前と窓口で答える")
    func developmentNames() {
        let names = services.compactMap { ($0["NSMenuItem"] as? [String: String])?["default"] }
        #expect(names == ["Open in Surimono Dev", "Print with Surimono Dev"])
        #expect(services.allSatisfy { $0["NSPortName"] as? String == "Surimono Dev" })
        #expect(ServiceProvider.portName == "Surimono Dev")
    }

    @Test("サービスの項目はメニューに出る宣言を持ち、文字と RTF とファイルを受ける")
    func declaration() {
        #expect(services.count == 2)
        for service in services {
            #expect((service["NSRequiredContext"] as? [String: Any])?.isEmpty == true)
            let types = service["NSSendTypes"] as? [String] ?? []
            #expect(types.contains("public.utf8-plain-text"))
            #expect(types.contains("public.rtf"))
            #expect((service["NSSendFileTypes"] as? [String] ?? []).contains("net.daringfireball.markdown"))
            #expect(service["NSReturnTypes"] == nil)
        }
    }

    @Test("宣言した項目のメッセージにサービスの受け手が答える")
    func messages() {
        let provider = ServiceProvider(router: router(), activate: {})
        for service in services {
            let message = service["NSMessage"] as? String ?? ""
            #expect(provider.responds(to: NSSelectorFromString("\(message):userData:error:")))
        }
    }

    @Test("サービスの項目は 8 言語に訳してある", arguments: ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"])
    func localized(language: String) throws {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        for key in ["Open in Surimono", "Print with Surimono", "Open in Surimono Dev", "Print with Surimono Dev"] {
            #expect(bundle.localizedString(forKey: key, value: "MISSING", table: "ServicesMenu") != "MISSING")
        }
    }

    @Test("「Surimono で開く」は選んだ文字をメモリから表示モードで開き、前面に出す")
    func openText() {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("# 見出し", forType: .string)
        var opened: [(Data, DocumentFormat, Bool)] = []
        var activations = 0
        let provider = ServiceProvider(
            router: router(openMemory: { opened.append(($0, $1, $3)) }), activate: { activations += 1 })
        var message: NSString?
        provider.openSelection(board, userData: nil, error: &message)
        #expect(message == nil)
        #expect(opened.count == 1)
        #expect(opened.first?.0 == Data("# 見出し".utf8))
        #expect(opened.first?.1 == .markdown)
        #expect(opened.first?.2 == false)
        #expect(activations == 1)
    }

    @Test("「Surimono で刷る」は選んだ文字を刷り台で開く")
    func printText() {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("本文", forType: .string)
        var printing: Bool?
        let provider = ServiceProvider(router: router(openMemory: { _, _, _, flag in printing = flag }), activate: {})
        var message: NSString?
        provider.printSelection(board, userData: nil, error: &message)
        #expect(printing == true)
    }

    @Test("RTF だけの選択は文字にして開く")
    func richText() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let text = NSAttributedString(string: "飾りのある文字")
        let rtf = try #require(text.rtf(from: NSRange(location: 0, length: text.length)))
        board.setData(rtf, forType: .rtf)
        #expect(
            ClipboardWindows.content(from: board)
                == .document(data: Data("飾りのある文字".utf8), format: .plainText))
    }

    @Test("何も受け取れないときは開かずに理由を返す")
    func nothing() {
        let board = board()
        defer { board.releaseGlobally() }
        var activations = 0
        let provider = ServiceProvider(router: router(), activate: { activations += 1 })
        var message: NSString?
        provider.openSelection(board, userData: nil, error: &message)
        #expect(message != nil)
        #expect(activations == 0)
    }

    @Test("ファイルはルーターの規則で開く")
    func files() {
        let board = board()
        defer { board.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/fixtures/b.pdf"), URL(fileURLWithPath: "/fixtures/a.md")]
        board.writeObjects(urls as [NSURL])
        var opened: [URL] = []
        let provider = ServiceProvider(
            router: router(openBinder: { urls, _ in
                opened = urls
                return nil
            }), activate: {})
        var message: NSString?
        provider.openSelection(board, userData: nil, error: &message)
        #expect(opened == [urls[1], urls[0]])
    }

    @Test("Finder で選んだファイルを「Surimono で刷る」に渡すと、ルーターが印刷モードで開く")
    func printFiles() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = board()
        defer { board.releaseGlobally() }
        let url = URL(fileURLWithPath: "/fixtures/a.md")
        board.writeObjects([url as NSURL])
        var opened: [URL] = []
        var activations = 0
        let router = router(openDocument: { url, completion in
            opened.append(url)
            completion(true)
        })
        let provider = ServiceProvider(router: router, activate: { activations += 1 })
        var message: NSString?
        provider.printSelection(board, userData: nil, error: &message)
        #expect(message == nil)
        #expect(opened == [url])
        #expect(activations == 1)
        let window = model(url: url, suite: suite, library: directory)
        defer { window.stop() }
        router.printIfRequested(window)
        #expect(window.isPrintModeRequested)
    }

    @Test("「Surimono で刷る」に渡した複数の画像は、画像の束が刷り台を頼まれる")
    func printImages() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = board()
        defer { board.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/fixtures/2.png"), URL(fileURLWithPath: "/fixtures/1.png")]
        board.writeObjects(urls as [NSURL])
        let bundle = model(url: urls[1], suite: suite, library: directory)
        defer { bundle.stop() }
        var opened: [URL] = []
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("文書は開かない") },
            openBundle: { urls, _ in
                opened = urls
                return bundle
            }, openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { false },
            showWelcome: { Issue.record("ウェルカム画面は出さない") })
        var message: NSString?
        ServiceProvider(router: router, activate: {}).printSelection(board, userData: nil, error: &message)
        #expect(opened == [urls[1], urls[0]])
        #expect(bundle.isPrintModeRequested)
    }

    @Test("「Surimono で刷る」で渡したファイルは、その文書の窓だけが刷り台を頼まれる")
    func printFileOnceOpen() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(fileURLWithPath: "/fixtures/a.md")
        let router = router(openDocument: { _, completion in completion(true) })
        router.open(.files([url]), printing: true)
        let opened = model(url: url, suite: suite, library: directory)
        defer { opened.stop() }
        let other = model(url: URL(fileURLWithPath: "/fixtures/b.md"), suite: suite, library: directory)
        defer { other.stop() }
        router.printIfRequested(other)
        #expect(!other.isPrintModeRequested)
        router.printIfRequested(opened)
        #expect(opened.isPrintModeRequested)
        let again = model(url: url, suite: suite, library: directory)
        defer { again.stop() }
        router.printIfRequested(again)
        #expect(!again.isPrintModeRequested)
    }

    @Test("すでに開いているファイルを「Surimono で刷る」で渡すとその窓が頼まれる")
    func printOpenFile() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(fileURLWithPath: "/fixtures/a.md")
        let existing = model(url: url, suite: suite, library: directory)
        defer { existing.stop() }
        let router = router(openDocument: { _, completion in completion(true) }, openWindows: { [existing] })
        router.open(.files([url]), printing: true)
        #expect(existing.isPrintModeRequested)
    }

    private func binder(_ urls: [URL], suite: TestDefaultsSuite, library: URL) -> DocumentViewModel {
        DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: library), binder: BinderModel(urls: urls, read: { _ in Data() }))
    }

    @Test("単独の文書を刷るとき、同じファイルを含む合本の窓は要求を受け取らない")
    func singleFileBesideBinder() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = URL(fileURLWithPath: "/fixtures/a.md")
        let b = URL(fileURLWithPath: "/fixtures/b.md")
        let document = model(url: a, suite: suite, library: directory)
        defer { document.stop() }
        let bound = binder([a, b], suite: suite, library: directory)
        defer { bound.stop() }
        let router = router(openDocument: { _, completion in completion(true) }, openWindows: { [bound, document] })
        router.open(.files([a]), printing: true)
        #expect(document.isPrintModeRequested)
        #expect(!bound.isPrintModeRequested)
    }

    @Test("合本を刷るとき、中のファイルを単独で開いた窓は要求を受け取らない")
    func binderBesideSingleFile() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = URL(fileURLWithPath: "/fixtures/a.md")
        let b = URL(fileURLWithPath: "/fixtures/b.md")
        let document = model(url: a, suite: suite, library: directory)
        defer { document.stop() }
        let bound = binder([a, b], suite: suite, library: directory)
        defer { bound.stop() }
        let router = router(openBinder: { _, _ in bound }, openWindows: { [bound, document] })
        router.open(.files([a, b]), printing: true)
        #expect(bound.isPrintModeRequested)
        #expect(!document.isPrintModeRequested)
    }

    @Test("開けなかったファイルの刷り台の依頼は残らない")
    func failedOpenForgetsRequest() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(fileURLWithPath: "/fixtures/a.md")
        let router = OpenRouter(
            openDocument: { _, completion in completion(false) }, openBundle: { _, _ in nil },
            openBinder: { _, _ in nil },
            warn: { _ in }, hasOpenWindows: { true }, showWelcome: {})
        router.open(.files([url]), printing: true)
        let later = model(url: url, suite: suite, library: directory)
        defer { later.stop() }
        router.printIfRequested(later)
        #expect(!later.isPrintModeRequested)
    }

    @Test("サービスから新しく開く文字は、初回の組版と窓の大きさの調整のあとで刷り台へ入る", .timeLimit(.minutes(1)))
    func memoryWindowOnTray() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = ClipboardWindows(
            openFiles: { _, _, _ in Issue.record("ファイルは開かない") }, warn: { _ in Issue.record("警告しない") }, closeWelcome: {})
        windows.preferences = AppPreferences(defaults: suite.defaults)
        windows.library = UserLibrary(root: directory)
        let recent = NSDocumentController.shared.recentDocumentURLs
        let controller = windows.open(Data("本文".utf8), format: .plainText, title: "Selected Text", printing: true)
        defer { controller.window?.close() }
        let model = controller.model
        #expect(model.mode == .view)
        #expect(model.isPrintModeRequested)
        #expect(model.result == nil)
        #expect(!model.hasSizedWindow)
        for _ in 0..<1500 where model.mode != .print { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.mode == .print)
        #expect(model.result != nil)
        #expect(model.hasSizedWindow)
        #expect(!model.isPrintModeRequested)
        #expect(model.fileURL == nil)
        #expect(model.displayName == "Selected Text")
        #expect(NSDocumentController.shared.recentDocumentURLs == recent)
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        model.mode = .view
        let same = windows.open(Data("本文".utf8), format: .plainText, title: "Other", printing: true)
        #expect(same === controller)
        #expect(model.mode == .print)
    }
}

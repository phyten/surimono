import AppKit
import SurimonoCore
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
        hasOpenWindows: @escaping () -> Bool = { true },
        showWelcome: @escaping () -> Void = { Issue.record("ウェルカム画面は出さない") },
        openMemory: @escaping (Data, DocumentFormat, String?, Bool) -> Void = { _, _, _, _ in }
    ) -> OpenRouter {
        OpenRouter(
            openDocument: openDocument,
            openBundle: {
                openBundle($0, $1)
                return nil
            },
            openBinder: {
                openBinder($0.urls, $1)
                return nil
            },
            warn: warn,
            hasOpenWindows: hasOpenWindows,
            showWelcome: showWelcome, openMemory: openMemory)
    }

    @Test("単独ファイルの判定中もメインスレッドを空け、要求順に窓へ渡す", .timeLimit(.minutes(1)))
    func gateOffMainThread() async {
        var opened: [URL] = []
        let files = [url("Dockerfile"), url("memo.md")]
        let secondOpened = DispatchSemaphore(value: 0)
        let router = router(openDocument: { file, complete in
            opened.append(file)
            if file == files[1] { secondOpened.signal() }
            complete(true)
        })
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { entered in
            router.route = { @Sendable _ in
                #expect(!Thread.isMainThread)
                entered.resume()
                release.wait()
                return .document
            }
            router.open([files[0]])
        }
        router.route = { @Sendable _ in
            #expect(!Thread.isMainThread)
            return .document
        }
        router.open([files[1]])
        // Give the ready second worker an opportunity to overtake the held first one if the queue is broken.
        let stayedQueued = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: secondOpened.wait(timeout: .now() + 1) == .timedOut)
            }
        }
        #expect(stayedQueued)
        #expect(opened.isEmpty)
        release.signal()
        await router.waitForOpeningRequests()
        #expect(opened == files)
    }

    @Test("1つのファイルは文書を開く処理に渡す")
    func single() async {
        var opened: [URL] = []
        let router = router(openDocument: { url, _ in opened.append(url) })
        router.open([url("a.pdf")])
        await router.waitForOpeningRequests()
        #expect(opened == [url("a.pdf")])
    }

    @Test("同梱の案内は1つのファイルとして文書を開く処理に渡し、2度目も同じファイルを渡す")
    func gettingStarted() async {
        var opened: [URL] = []
        let router = router(openDocument: { url, _ in opened.append(url) })
        router.gettingStartedURL = { self.url("Getting Started with Surimono.md") }
        #expect(router.openGettingStarted())
        #expect(router.openGettingStarted())
        await router.waitForOpeningRequests()
        #expect(opened == [url("Getting Started with Surimono.md"), url("Getting Started with Surimono.md")])
    }

    @Test("案内がアプリに見つからなければ何も開かない")
    func gettingStartedMissing() {
        let router = router()
        router.gettingStartedURL = { nil }
        #expect(!router.openGettingStarted())
    }

    @Test("見本を開くとファイルの場所を渡さず、文書名と内容からメモリの Markdown を表示する")
    func sampleDocument() throws {
        let url = try #require(GettingStarted.sampleURL())
        let expected = try Data(contentsOf: url)
        var calls = 0
        let router = router(openMemory: { data, format, title, printing in
            calls += 1
            #expect(data == expected)
            #expect(format == .markdown)
            #expect(title == url.deletingPathExtension().lastPathComponent)
            #expect(!printing)
        })
        #expect(router.openSampleDocument())
        #expect(calls == 1)
    }

    @Test("画像3つは自然順の束として開く")
    func bundle() async {
        var opened: [URL] = []
        let router = router(openBundle: { urls, excluded in
            opened = urls
            #expect(excluded.isEmpty)
        })
        router.open([url("10.png"), url("2.jpg"), url("1.heic")])
        await router.waitForOpeningRequests()
        #expect(opened == [url("1.heic"), url("2.jpg"), url("10.png")])
    }

    @Test("画像とZIPの選択は除外一覧付きの画像の束として開き警告しない")
    func imagesWithExclusions() async {
        var opened: [URL] = []
        var exclusions: [URL] = []
        let router = router(openBundle: { urls, excluded in
            opened = urls
            exclusions = excluded
        })
        router.open([url("b.zip"), url("a.png")])
        await router.waitForOpeningRequests()
        #expect(opened == [url("a.png")])
        #expect(exclusions == [url("b.zip")])
    }

    @Test("MarkdownとPDFは合本を開いて警告しない")
    func binder() async {
        var opened: [URL] = []
        let router = router(openBinder: { urls, excluded in
            opened = urls
            #expect(excluded.isEmpty)
        })
        router.open([url("b.pdf"), url("a.md")])
        await router.waitForOpeningRequests()
        #expect(opened == [url("a.md"), url("b.pdf")])
    }

    /// A router whose three ways for one file are told apart, with the choice between them left real.
    private func routed(
        _ record: @escaping (String, URL) -> Void, refused: @escaping (any Error) -> Void = { _ in }
    ) -> OpenRouter {
        OpenRouter(
            openDocument: { url, completion in
                record("document", url)
                completion(true)
            },
            openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") },
            hasOpenWindows: { true }, showWelcome: {},
            openAsText: { url in
                record("text", url)
                return true
            },
            refuse: refused)
    }

    private func withFiles(_ files: [String: Data], _ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        try await body(directory.standardizedFileURL)
    }

    private var video: Data {
        var data = Data()
        for _ in 0..<30 { data += Data([0x47, 0x40, 0x00, 0x10]) + Data(repeating: 0, count: 184) }
        return data
    }

    @Test("1 つのファイルは、型のある文書なら文書を開く処理へ、型のないテキストならテキストとして開く処理へ渡す")
    func singleFileWays() async throws {
        let files = [
            "main.ts": Data("let a = 1\n".utf8), "main.go": Data("package main\n".utf8), "notes.md": Data("# a".utf8),
            "Dockerfile": Data("FROM scratch\n".utf8), "tool": Data("#!/bin/sh\necho 1\n".utf8),
            ".env": Data("A=1\n".utf8), "LICENSE": Data("Free.\n".utf8),
        ]
        try await withFiles(files) { directory in
            var ways: [String: String] = [:]
            let router = routed({ way, url in ways[url.lastPathComponent] = way })
            for name in files.keys { router.open([directory.appendingPathComponent(name)]) }
            await router.waitForOpeningRequests()
            #expect(
                ways == [
                    "main.ts": "document", "main.go": "document", "notes.md": "document", "LICENSE": "document",
                    "Dockerfile": "text", "tool": "text", ".env": "text",
                ])
        }
    }

    @Test("動画の .ts・.mts とバイナリの .plist は、どの開く処理にも渡さずに断る")
    func singleFileRefusals() async throws {
        let binary = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
        try await withFiles(["clip.ts": video, "clip.mts": video, "Info.plist": binary]) { directory in
            var opened: [URL] = []
            var refusals: [SourceFileError] = []
            let router = routed(
                { _, url in opened.append(url) }, refused: { refusals.append($0 as? SourceFileError ?? .notText) })
            for name in ["clip.ts", "clip.mts", "Info.plist"] {
                router.open([directory.appendingPathComponent(name)], printing: true)
            }
            await router.waitForOpeningRequests()
            #expect(opened.isEmpty)
            #expect(refusals == [.notText, .notText, .notText])
        }
    }

    @Test("合本を解いて文書を開き直すときも、同じ道の選び方を通る")
    func reopenTakesTheSameWay() async throws {
        try await withFiles(["Dockerfile": Data("FROM scratch\n".utf8), "clip.ts": video]) { directory in
            var ways: [String] = []
            let router = routed({ way, _ in ways.append(way) })
            var results: [Bool] = []
            for name in ["Dockerfile", "clip.ts"] {
                let url = directory.appendingPathComponent(name)
                let origin = BinderOrigin(contents: .document(url), frame: .zero, pageIndex: 0, wasPrinting: false)
                router.reopen(url, restoring: origin) { results.append($0) }
            }
            await router.waitForOpeningRequests()
            #expect(ways == ["text"])
            #expect(results == [true, false])
        }
    }

    @Test("ソースコードと文章の複数選択は合本を開き、拡張子のない Dockerfile とスクリプトを含め、動画を除く")
    func binderOfSourceFiles() async throws {
        let files = [
            "notes.md": Data("# a".utf8), "main.ts": Data("let a = 1\n".utf8), "main.go": Data("package main\n".utf8),
            "Dockerfile": Data("FROM scratch\n".utf8), "tool": Data("#!/bin/sh\n".utf8),
            "LICENSE": Data("Free.\n".utf8),
            "clip.ts": video, "clip.mts": video,
        ]
        try await withFiles(files) { directory in
            func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
            var opened: [URL] = []
            var left: [URL] = []
            let router = router(openBinder: { urls, excluded in
                opened = urls
                left = excluded
            })
            router.open(files.keys.map { file($0) })
            await router.waitForOpeningRequests()
            #expect(opened == ["Dockerfile", "main.go", "main.ts", "notes.md", "tool"].map { file($0) })
            #expect(left == ["clip.mts", "clip.ts", "LICENSE"].map { file($0) })
        }
    }

    @Test("ソースコードだけの複数選択も合本になり、画像の束にはならない")
    func binderOfOnlySourceFiles() async {
        var opened: [URL] = []
        let router = router(openBinder: { urls, _ in opened = urls })
        router.open([url("b.rs"), url("a.swift")])
        await router.waitForOpeningRequests()
        #expect(opened == [url("a.swift"), url("b.rs")])
    }

    @Test("最近使った合本は、画像だけの組でも画像の束にせず合本のまま開く")
    func recentBinderOfImages() {
        var opened: [[URL]] = []
        let router = router(openBinder: { urls, excluded in
            opened.append(urls)
            #expect(excluded.isEmpty)
        })
        router.open(
            recentBinder: RecentBinder(files: [.init(path: "/fixtures/2.png"), .init(path: "/fixtures/1.png")]))
        #expect(opened == [[url("2.png"), url("1.png")]])
    }

    @Test("最近使った合本は、見つからないファイルも含めて開き、警告しない")
    func recentBinderWithMissingFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let present = folder.appendingPathComponent("present.md")
        try Data("本文".utf8).write(to: present)
        let missing = folder.appendingPathComponent("missing.md")
        var opened: [[String]] = []
        let router = router(openBinder: { urls, _ in opened.append(urls.map(\.path)) })
        router.open(recentBinder: RecentBinder(files: [.init(path: missing.path), .init(path: present.path)]))
        #expect(opened == [[missing.path, present.path]])
    }

    @Test("サンドボックスでは最近使った合本をブックマークで探して開き、窓がなければアクセスをすぐ手放す")
    func recentBinderInTheSandbox() {
        let moved = url("moved/a.md")
        var starts = 0
        var active = 0
        var opened: [URL] = []
        let router = router(openBinder: { urls, _ in opened = urls })
        router.recentFiles = RecentBinderFiles(
            backend: FolderAccess.Backend(
                create: { _ in Data() }, resolve: { _ in (moved, false) },
                start: { _ in
                    starts += 1
                    active += 1
                    return true
                }, stop: { _ in active -= 1 }),
            isSandboxed: { true })
        router.open(
            recentBinder: RecentBinder(files: [
                .init(path: "/fixtures/a.md", bookmark: Data([1])), .init(path: "/fixtures/b.md"),
            ]))
        #expect(opened == [moved, url("b.md")])
        #expect(starts == 1)
        #expect(active == 0)
    }

    private func model(_ url: URL?, suite: TestDefaultsSuite, library: URL) -> DocumentViewModel {
        DocumentViewModel(
            data: Data("# a".utf8), fileURL: url, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: library))
    }

    @Test("1つのファイルを印刷モードで開くと、その文書の窓ができたときに刷り台を頼む")
    func singleInPrintMode() async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var opened: [URL] = []
        var windows: [DocumentViewModel] = []
        let router = OpenRouter(
            openDocument: { url, completion in
                opened.append(url)
                // The document's window appears before the open is reported as finished.
                windows = [self.model(url, suite: suite, library: directory)]
                completion(true)
            }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") },
            hasOpenWindows: { false }, showWelcome: { Issue.record("ウェルカム画面は出さない") },
            openWindows: { windows })
        #expect(router.open([url("a.md")], printing: true))
        await router.waitForOpeningRequests()
        defer { for model in windows { model.stop() } }
        #expect(opened == [url("a.md")])
        #expect(windows.first?.isPrintModeRequested == true)
    }

    @Test("同じ URL の先行要求が拒否されても、後続の窓が印刷指定とアクセスを受け取る")
    func refusedBeforePrinting() async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = url("again.ts")
        var closed: [String] = []
        var refusals = 0
        var opened: [URL] = []
        let router = OpenRouter(
            openDocument: { url, completion in
                opened.append(url)
                completion(true)
            }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in },
            hasOpenWindows: { false }, showWelcome: { Issue.record("後続の要求が待っている") },
            refuse: { _ in refusals += 1 })
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { entered in
            router.route = { @Sendable _ in
                entered.resume()
                release.wait()
                return .refuse
            }
            router.open([file], access: [.init(url: file) { closed.append("A") }])
        }
        router.route = { _ in .document }
        router.open([file], printing: true, access: [.init(url: file) { closed.append("B") }])
        release.signal()
        await router.waitForOpeningRequests()
        #expect(refusals == 1)
        #expect(opened == [file])
        #expect(closed == ["A"])
        let new = model(file, suite: suite, library: directory)
        router.handAccess(to: new)
        #expect(new.isPrintModeRequested)
        #expect(closed == ["A"])
        new.stop()
        #expect(closed == ["A", "B"])
    }

    @Test("後続要求の待機中に既存の窓が閉じたら、新しい窓がアクセスを引き継ぐ")
    func closesWhileQueued() async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = url("again.md")
        let old = model(file, suite: suite, library: directory)
        let new = model(file, suite: suite, library: directory)
        var windows = [old]
        var closed = 0
        let router = OpenRouter(
            openDocument: { url, completion in
                if url == file { windows = [new] }
                completion(true)
            }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in },
            hasOpenWindows: { true }, showWelcome: {}, openWindows: { windows })
        router.handAccess(to: old)
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { entered in
            router.route = { @Sendable _ in
                entered.resume()
                release.wait()
                return .document
            }
            router.open([url("first.md")])
        }
        router.route = { _ in .document }
        router.open([file], printing: true, access: [.init(url: file) { closed += 1 }])
        #expect(!old.isPrintModeRequested)
        windows = []
        old.stop()
        #expect(closed == 0)
        release.signal()
        await router.waitForOpeningRequests()
        #expect(new.isPrintModeRequested)
        #expect(closed == 0)
        new.stop()
        #expect(closed == 1)
    }

    @Test("閉じた文書窓を保持していても、同じ URL を開き直す要求の引き渡し先にしない")
    func closedWindowLeavesRegistry() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = model(directory.appendingPathComponent("again.md"), suite: suite, library: directory)
        defer { document.stop() }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        DocumentWindows.shared.register(document, for: window)
        #expect(DocumentWindows.shared.model(for: window) === document)
        window.close()
        #expect(!DocumentWindows.shared.openModels.contains { $0 === document })
    }

    @Test("同じ URL の文書オープンが逆順に完了しても、窓は成功した要求の印刷指定とアクセスをすべて受け取る", arguments: [false, true])
    func outOfOrderCompletions(firstOpens: Bool) async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = url("again.md")
        var completions: [(Bool) -> Void] = []
        var closed: [String] = []
        let router = router(openDocument: { _, done in completions.append(done) })
        router.route = { _ in .document }
        router.open([file], printing: true, access: [.init(url: file) { closed.append("A") }])
        router.open([file], access: [.init(url: file) { closed.append("B") }])
        await router.waitForOpeningRequests()
        guard completions.count == 2 else {
            Issue.record("2 件とも文書を開く処理に届く")
            return
        }
        completions[1](true)
        completions[0](firstOpens)
        #expect(closed == (firstOpens ? [] : ["A"]))
        let new = model(file, suite: suite, library: directory)
        router.handAccess(to: new)
        #expect(new.isPrintModeRequested == firstOpens)
        #expect(closed == (firstOpens ? [] : ["A"]))
        new.stop()
        #expect(closed.sorted() == ["A", "B"])
    }

    @Test("印刷モードを頼まずに開いた文書は表示モードのまま")
    func singleWithoutPrintMode() async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var windows: [DocumentViewModel] = []
        let router = OpenRouter(
            openDocument: { url, completion in
                windows = [self.model(url, suite: suite, library: directory)]
                completion(true)
            }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in },
            hasOpenWindows: { false }, showWelcome: {}, openWindows: { windows })
        router.open([url("a.md")])
        await router.waitForOpeningRequests()
        defer { for model in windows { model.stop() } }
        #expect(windows.first?.isPrintModeRequested == false)
    }

    @Test("複数の画像を印刷モードで開くと、画像の束の窓が刷り台を頼まれる")
    func bundleInPrintMode() async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = model(nil, suite: suite, library: directory)
        defer { bundle.stop() }
        var opened: [URL] = []
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") },
            openBundle: { urls, _ in
                opened = urls
                return bundle
            }, openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { false },
            showWelcome: {})
        router.open([url("2.png"), url("1.jpg")], printing: true)
        await router.waitForOpeningRequests()
        #expect(opened == [url("1.jpg"), url("2.png")])
        #expect(bundle.isPrintModeRequested)
    }

    @Test("対応する文書がない選択を印刷モードで開こうとすると、警告だけを出して何も開かない")
    func unsupportedInPrintMode() async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = model(url("a.md"), suite: suite, library: directory)
        defer { other.stop() }
        var warnings = 0
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") },
            openBundle: { _, _ in
                Issue.record("束は開かない")
                return nil
            },
            openBinder: { _, _ in
                Issue.record("合本は開かない")
                return nil
            }, warn: { _ in warnings += 1 }, hasOpenWindows: { true }, showWelcome: {}, openWindows: { [other] })
        router.open([url("a.zip"), url("b.unknown")], printing: true)
        await router.waitForOpeningRequests()
        #expect(warnings == 1)
        #expect(!other.isPrintModeRequested)
    }

    @Test("すでに開いているファイルを印刷モードで開くと、文書を開く処理が前面に出し、その窓が刷り台を頼まれる")
    func openFileInPrintMode() async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = model(url("a.md"), suite: suite, library: directory)
        defer { existing.stop() }
        var shown: [URL] = []
        let router = OpenRouter(
            openDocument: { url, completion in
                shown.append(url)
                completion(true)
            }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") },
            hasOpenWindows: { true }, showWelcome: {}, openWindows: { [existing] })
        router.open([url("a.md")], printing: true)
        await router.waitForOpeningRequests()
        #expect(shown == [url("a.md")])
        #expect(existing.isPrintModeRequested)
    }

    @Test("対応する文書がないドロップは対象ウィンドウで警告する")
    func sheet() async {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        var parent: NSWindow?
        let router = router(warn: { parent = $0 })
        router.open([url("a.zip"), url("b.unknown")], from: window)
        await router.waitForOpeningRequests()
        #expect(parent === window)
    }

    @Test("対応する文書がなく何も開いていなければウェルカム画面を出す")
    func welcomeAfterRejection() async {
        var events: [String] = []
        let router = router(
            warn: { _ in events.append("warning") }, hasOpenWindows: { false },
            showWelcome: { events.append("welcome") })
        router.open([url("a.zip"), url("b.unknown")])
        #expect(router.pendingOpens == 1)
        router.showWelcomeAfterLaunch()
        #expect(events.isEmpty)
        await router.waitForOpeningRequests()
        #expect(router.pendingOpens == 0)
        #expect(events == ["warning", "welcome"])
    }

    @Test("画像の束や合本の窓を作れなかったときもウェルカム画面に戻る", arguments: [["a.png", "b.jpg"], ["a.md", "b.pdf"]])
    func welcomeWhenNoWindowIsMade(names: [String]) async {
        var events: [String] = []
        let router = router(
            openBundle: { _, _ in events.append("open") }, openBinder: { _, _ in events.append("open") },
            hasOpenWindows: { false }, showWelcome: { events.append("welcome") })
        router.open(names.map { url($0) })
        router.showWelcomeAfterLaunch()
        #expect(events.isEmpty)
        await router.waitForOpeningRequests()
        #expect(router.pendingOpens == 0)
        #expect(events == ["open", "welcome"])
    }

    @Test("文書を開けず何も開いていなければウェルカム画面を出す")
    func welcomeAfterFailure() async {
        var welcomes = 0
        let router = router(
            openDocument: { _, completion in completion(false) }, hasOpenWindows: { false },
            showWelcome: { welcomes += 1 })
        router.open([url("unreadable.pdf")])
        await router.waitForOpeningRequests()
        #expect(welcomes == 1)
    }

    @Test("ほかの文書を開いている途中ならウェルカム画面を出さない")
    func noWelcomeWhilePending() async {
        var completions: [(Bool) -> Void] = []
        let router = router(
            openDocument: { _, completion in completions.append(completion) }, hasOpenWindows: { false })
        router.open([url("a.pdf")])
        router.open([url("unreadable.pdf")])
        await router.waitForOpeningRequests()
        completions[1](false)
        router.showWelcomeIfIdle()
        #expect(router.pendingOpens == 1)
    }

    @Test("文書のウィンドウがあれば開けなかったときもウェルカム画面を出さない")
    func noWelcomeWithWindows() async {
        let router = router(openDocument: { _, completion in completion(false) }, hasOpenWindows: { true })
        router.open([url("unreadable.pdf")])
        await router.waitForOpeningRequests()
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

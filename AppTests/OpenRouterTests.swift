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
        hasOpenWindows: @escaping () -> Bool = { false },
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
                openBinder($0, $1)
                return nil
            },
            warn: warn,
            hasOpenWindows: hasOpenWindows,
            showWelcome: showWelcome, openMemory: openMemory)
    }

    @Test("1つのファイルは文書を開く処理に渡す")
    func single() {
        var opened: [URL] = []
        let router = router(openDocument: { url, _ in opened.append(url) })
        router.open([url("a.pdf")])
        #expect(opened == [url("a.pdf")])
    }

    @Test("同梱の案内は1つのファイルとして文書を開く処理に渡し、2度目も同じファイルを渡す")
    func gettingStarted() {
        var opened: [URL] = []
        let router = router(openDocument: { url, _ in opened.append(url) })
        router.gettingStartedURL = { self.url("Getting Started with Surimono.md") }
        #expect(router.openGettingStarted())
        #expect(router.openGettingStarted())
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
            openAsText: { url, completion in
                record("text", url)
                completion(true)
            },
            refuse: refused)
    }

    private func withFiles(_ files: [String: Data], _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        try body(directory.standardizedFileURL)
    }

    private var video: Data {
        var data = Data()
        for _ in 0..<30 { data += Data([0x47, 0x40, 0x00, 0x10]) + Data(repeating: 0, count: 184) }
        return data
    }

    @Test("1 つのファイルは、型のある文書なら文書を開く処理へ、型のないテキストならテキストとして開く処理へ渡す")
    func singleFileWays() throws {
        let files = [
            "main.ts": Data("let a = 1\n".utf8), "main.go": Data("package main\n".utf8), "notes.md": Data("# a".utf8),
            "Dockerfile": Data("FROM scratch\n".utf8), "tool": Data("#!/bin/sh\necho 1\n".utf8),
            ".env": Data("A=1\n".utf8), "LICENSE": Data("Free.\n".utf8),
        ]
        try withFiles(files) { directory in
            var ways: [String: String] = [:]
            let router = routed({ way, url in ways[url.lastPathComponent] = way })
            for name in files.keys { router.open([directory.appendingPathComponent(name)]) }
            #expect(
                ways == [
                    "main.ts": "document", "main.go": "document", "notes.md": "document", "LICENSE": "document",
                    "Dockerfile": "text", "tool": "text", ".env": "text",
                ])
        }
    }

    @Test("動画の .ts・.mts とバイナリの .plist は、どの開く処理にも渡さずに断る")
    func singleFileRefusals() throws {
        let binary = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
        try withFiles(["clip.ts": video, "clip.mts": video, "Info.plist": binary]) { directory in
            var opened: [URL] = []
            var refusals: [SourceFileError] = []
            let router = routed(
                { _, url in opened.append(url) }, refused: { refusals.append($0 as? SourceFileError ?? .notText) })
            for name in ["clip.ts", "clip.mts", "Info.plist"] {
                router.open([directory.appendingPathComponent(name)], printing: true)
            }
            #expect(opened.isEmpty)
            #expect(refusals == [.notText, .notText, .notText])
        }
    }

    @Test("合本を解いて文書を開き直すときも、同じ道の選び方を通る")
    func reopenTakesTheSameWay() throws {
        try withFiles(["Dockerfile": Data("FROM scratch\n".utf8), "clip.ts": video]) { directory in
            var ways: [String] = []
            let router = routed({ way, _ in ways.append(way) })
            var results: [Bool] = []
            for name in ["Dockerfile", "clip.ts"] {
                let url = directory.appendingPathComponent(name)
                let origin = BinderOrigin(contents: .document(url), frame: .zero, pageIndex: 0, wasPrinting: false)
                router.reopen(url, restoring: origin) { results.append($0) }
            }
            #expect(ways == ["text"])
            #expect(results == [true, false])
        }
    }

    @Test("ソースコードと文章の複数選択は合本を開き、拡張子のない Dockerfile とスクリプトを含め、動画を除く")
    func binderOfSourceFiles() throws {
        let files = [
            "notes.md": Data("# a".utf8), "main.ts": Data("let a = 1\n".utf8), "main.go": Data("package main\n".utf8),
            "Dockerfile": Data("FROM scratch\n".utf8), "tool": Data("#!/bin/sh\n".utf8),
            "LICENSE": Data("Free.\n".utf8),
            "clip.ts": video, "clip.mts": video,
        ]
        try withFiles(files) { directory in
            func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
            var opened: [URL] = []
            var left: [URL] = []
            let router = router(openBinder: { urls, excluded in
                opened = urls
                left = excluded
            })
            router.open(files.keys.map(file))
            #expect(opened == ["Dockerfile", "main.go", "main.ts", "notes.md", "tool"].map(file))
            #expect(left == ["clip.mts", "clip.ts", "LICENSE"].map(file))
        }
    }

    @Test("ソースコードだけの複数選択も合本になり、画像の束にはならない")
    func binderOfOnlySourceFiles() {
        var opened: [URL] = []
        let router = router(openBinder: { urls, _ in opened = urls })
        router.open([url("b.rs"), url("a.swift")])
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
    func singleInPrintMode() {
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
        defer { for model in windows { model.stop() } }
        #expect(opened == [url("a.md")])
        #expect(windows.first?.isPrintModeRequested == true)
    }

    @Test("印刷モードを頼まずに開いた文書は表示モードのまま")
    func singleWithoutPrintMode() {
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
        defer { for model in windows { model.stop() } }
        #expect(windows.first?.isPrintModeRequested == false)
    }

    @Test("複数の画像を印刷モードで開くと、画像の束の窓が刷り台を頼まれる")
    func bundleInPrintMode() {
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
        #expect(opened == [url("1.jpg"), url("2.png")])
        #expect(bundle.isPrintModeRequested)
    }

    @Test("対応する文書がない選択を印刷モードで開こうとすると、警告だけを出して何も開かない")
    func unsupportedInPrintMode() {
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
        #expect(warnings == 1)
        #expect(!other.isPrintModeRequested)
    }

    @Test("すでに開いているファイルを印刷モードで開くと、文書を開く処理が前面に出し、その窓が刷り台を頼まれる")
    func openFileInPrintMode() {
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
        #expect(shown == [url("a.md")])
        #expect(existing.isPrintModeRequested)
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

    @Test("文書のない起動時・文書の開閉・外観変更後にも実メニューから開くと最近使った項目を一つずつ使える", .timeLimit(.minutes(1)))
    func openMenu() async throws {
        let controller = NSDocumentController.shared
        var panels = 0
        let original = OpenRouter.shared.presentOpenPanel
        OpenRouter.shared.presentOpenPanel = { _ in panels += 1 }
        defer { OpenRouter.shared.presentOpenPanel = original }

        func openIndex(in rows: [DebugMenuDump.Row], stage: String, recents: [URL]? = nil) throws -> Int {
            let visible = rows.indices.filter { !rows[$0].hidden }
            let open = visible.filter {
                let row = rows[$0]
                return row.title == String(localized: "Open…")
                    || row.action == #selector(NSDocumentController.openDocument(_:))
                    || (row.key.lowercased() == "o" && row.modifiers == .command)
            }
            let nativeRecent = Bundle(for: NSDocument.self).localizedString(
                forKey: "Open Recent", value: nil, table: "MenuCommands")
            let recent = visible.map { rows[$0] }.filter {
                $0.title == String(localized: "Open Recent") || $0.title == nativeRecent
                    || $0.children.contains { $0.action == #selector(NSDocumentController.clearRecentDocuments(_:)) }
            }
            let diagnostic = "\(stage) File=\(rows.map { ($0.title, $0.hidden, $0.key) })"
            try #require(open.count == 1 && recent.count == 1, "\(diagnostic)")
            let item = rows[open[0]]
            #expect(item.enabled && item.key == "o" && item.modifiers == .command, "\(diagnostic)")
            #expect(item.action != #selector(NSDocumentController.openDocument(_:)), "\(diagnostic)")
            let children = recent[0].children.filter { !$0.hidden && !$0.separator }
            #expect(children.last?.title == String(localized: "Clear Menu"), "\(diagnostic)")
            if let recents {
                #expect(children.dropLast().map(\.title) == recents.map(\.lastPathComponent), "\(diagnostic)")
                #expect(children.last?.enabled == !recents.isEmpty, "\(diagnostic)")
            }
            return open[0]
        }

        func trace(_ step: String) {
            FileHandle.standardError.write(Data("OpenRouterTests.openMenu: \(step)\n".utf8))
        }

        func checkShare(in menu: NSMenu, main: NSMenu, stage: String) throws {
            try #require(main.items.dropFirst().first?.submenu === menu)
            let visible = menu.items.filter { !$0.isHiddenOrHasHiddenAncestor }
            let shares = visible.filter { $0.title == String(localized: "Share") }
            let diagnostic = "\(stage) File=\(visible.map(\.title))"
            try #require(shares.count == 1, "\(diagnostic)")
            let share = shares[0]
            #expect(share.identifier?.rawValue == ViewerMainMenu.shareIdentifier && share.submenu == nil)
            #expect(!controller.allowsAutomaticShareMenu && share.target is ViewerMainMenu && share.action != nil)
            #expect(!visible.contains { $0.title == "NSMenuItem" }, "\(diagnostic)")
            let index = try #require(visible.firstIndex(of: share))
            // Inspect raw adjacent rows: the dump formatter itself coalesces separators.
            #expect(
                visible[..<index].reversed().prefix(while: { $0.isSeparatorItem }).count <= 1,
                "\(diagnostic)")
            #expect(
                visible.dropFirst(index + 1).prefix(while: { $0.isSeparatorItem }).count <= 1,
                "\(diagnostic)")
        }

        func check(_ stage: String) throws {
            let main = try #require(NSApp.mainMenu)
            let file = try #require(main.items.dropFirst().first?.submenu)
            file.delegate?.menuNeedsUpdate?(file)
            try checkShare(in: file, main: main, stage: stage)
            let recent = try #require(
                file.items.first { !$0.isHidden && $0.title == String(localized: "Open Recent") }?.submenu)
            recent.delegate?.menuNeedsUpdate?(recent)
            let items = file.items
            let index = try openIndex(
                in: items.map(DebugMenuDump.Row.init), stage: stage,
                recents: RecentFileHistory.shared?.visibleURLs ?? controller.recentDocumentURLs)
            let item = items[index]
            let equivalents = ShortcutMenuBaselineTests.items(main).filter {
                !$0.isHiddenOrHasHiddenAncestor && $0.keyEquivalent.lowercased() == "o"
                    && $0.keyEquivalentModifierMask == .command
            }
            #expect(equivalents == [item], "\(stage)")
            let before = panels
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            #expect(panels == before + 1, "\(stage)")
            let key = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                    context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31))
            #expect(main.performKeyEquivalent(with: key), "\(stage)")
            #expect(panels == before + 2, "\(stage)")
        }

        func open(_ url: URL) async throws -> NSDocument {
            try #require(controller.document(for: url) == nil)
            let doc: NSDocument = try await withCheckedThrowingContinuation { continuation in
                controller.openDocument(withContentsOf: url, display: true) { doc, _, error in
                    if let doc {
                        continuation.resume(returning: doc)
                    } else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    }
                }
            }
            return doc
        }

        _ = try openIndex(in: #require(DebugMenuDump.testLaunchFile), stage: "ホストの起動完了時")
        try #require(controller.documents.isEmpty)
        try check("文書を開く前")
        let first = try await open(try #require(GettingStarted.sampleURL()))
        defer { if controller.documents.contains(first) { first.close() } }
        try await ShortcutMenuBaselineTests.waitForMenu {
            first.windowControllers.contains { $0.window?.isVisible == true }
        }
        try check("最初の文書ウインドウの表示直後")
        try await Task.sleep(for: .seconds(3))
        try check("最初の文書ウインドウを表示して3秒後")
        let second = try await open(try #require(GettingStarted.url()))
        defer { if controller.documents.contains(second) { second.close() } }
        try await ShortcutMenuBaselineTests.waitForMenu {
            second.windowControllers.contains { $0.window?.isVisible == true }
        }
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        NSApp.appearance = NSAppearance(
            named: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? .darkAqua : .aqua)
        try await Task.sleep(for: .milliseconds(200))
        try check("2枚目の文書と外観変更後")
        trace("closing the second document")
        second.close()
        trace("closing the first document")
        first.close()
        try await ShortcutMenuBaselineTests.waitForMenu { controller.documents.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        try check("文書をすべて閉じた後")
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

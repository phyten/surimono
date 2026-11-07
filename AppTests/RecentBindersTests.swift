import AppKit
import SurimonoCore
import Testing

@testable import Surimono

/// The File menu's Recent Binders: what a binder leaves behind when its window closes, and how its files are found again.
@MainActor
struct RecentBindersTests {
    @MainActor private final class Fixture {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences: AppPreferences
        let windows = BinderWindows()

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            preferences = AppPreferences(defaults: suite.defaults)
            windows.preferences = preferences
            windows.library = UserLibrary(root: root.appendingPathComponent("Library"))
            windows.settingsStore = DocumentSettingsStore(directory: root.appendingPathComponent("Settings"))
        }

        func remove() {
            suite.remove()
            try? FileManager.default.removeItem(at: root)
        }

        func file(_ name: String, _ text: String = "本文") throws -> URL {
            let url = root.appendingPathComponent(name).standardizedFileURL
            try Data(text.utf8).write(to: url)
            return url
        }
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func closedWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: Preferences and the menu's names

    @Test("最近の合本は設定に保存され、読み込み直しても同じで、消去すると保存からも消える")
    func persistence() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.recentBinders.isEmpty)
        preferences.recordRecentBinder(
            RecentBinder(files: [.init(path: "/docs/a.md", bookmark: Data([1, 2])), .init(path: "/docs/b.md")]))
        preferences.recordRecentBinder(RecentBinder(files: [.init(path: "/docs/c.md"), .init(path: "/docs/d.md")]))
        let restored = AppPreferences(defaults: suite.defaults)
        #expect(
            restored.recentBinders.entries.map(\.paths) == [
                ["/docs/c.md", "/docs/d.md"], ["/docs/a.md", "/docs/b.md"],
            ])
        #expect(restored.recentBinders.entries[1].files.map(\.bookmark) == [Data([1, 2]), nil])
        restored.clearRecentBinders()
        #expect(restored.recentBinders.isEmpty)
        #expect(AppPreferences(defaults: suite.defaults).recentBinders.isEmpty)
    }

    @Test("壊れた保存値は、最近の合本が1件もない状態として読み込む")
    func damagedStoredValue() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(Data("壊れた値".utf8), forKey: "recentBinders")
        #expect(AppPreferences(defaults: suite.defaults).recentBinders.isEmpty)
    }

    @Test("メニューの項目名は合本の窓の名前と同じ形で、先頭のファイル名と残りの件数になる")
    func menuTitle() {
        let binder = RecentBinder(files: ["/docs/a.md", "/docs/b.md", "/docs/c.md"].map { .init(path: $0) })
        let model = BinderModel(urls: binder.paths.map(url))
        for language in ["ja", "en", "de"] {
            let title = BinderModel.title(firstName: binder.firstName, count: binder.files.count, language: language)
            #expect(title == model.title(language: language))
        }
        #expect(BinderModel.title(firstName: "a.md", count: 3, language: "ja") == "a.md ほか 2 件")
        #expect(BinderModel.title(firstName: "a.md", count: 2, language: "en") == "a.md and 1 more")
    }

    // MARK: The File menu

    /// The File menu as it is when opened. SwiftUI brings a menu up to date as it is about to open, a moment after
    /// what the menu follows has changed, so this asks again until the menu is as `condition` wants.
    private func openedFileMenu(until condition: (NSMenu) -> Bool) async throws -> NSMenu {
        let file = try #require(NSApp.mainMenu?.items[1].submenu)
        for _ in 0..<300 {
            file.delegate?.menuNeedsUpdate?(file)
            if condition(file) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return file
    }

    @Test("ファイルメニューは、最近の合本があるときだけ「最近使った合本」を出し、メニューを消去すると消える", .timeLimit(.minutes(1)))
    func fileMenuListsRecentBinders() async throws {
        // The running app's own preferences, because the menu follows them; what was there comes back at the end.
        let preferences = try #require(BinderWindows.shared.preferences)
        let saved = preferences.recentBinders
        let wasStored = UserDefaults.standard.object(forKey: "recentBinders") != nil
        defer {
            preferences.clearRecentBinders()
            for entry in saved.entries.reversed() { preferences.recordRecentBinder(entry) }
            if !wasStored { UserDefaults.standard.removeObject(forKey: "recentBinders") }
        }
        let name = Bundle.main.localizedString(forKey: "Recent Binders", value: nil, table: nil)
        let clear = Bundle.main.localizedString(forKey: "Clear Menu", value: nil, table: nil)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        func isListed(_ menu: NSMenu) -> Bool { menu.items.contains { $0.title == name } }

        preferences.clearRecentBinders()
        var file = try await openedFileMenu { !isListed($0) }
        #expect(!isListed(file))

        preferences.recordRecentBinder(RecentBinder(files: [.init(path: "/docs/a.md"), .init(path: "/docs/b.md")]))
        preferences.recordRecentBinder(
            RecentBinder(files: ["x.md", "y.md", "z.md"].map { .init(path: "/docs/" + $0) }))
        file = try await openedFileMenu { isListed($0) }
        let submenu = try #require(file.items.first { $0.title == name }?.submenu)
        let titles = [(first: "x.md", count: 3), (first: "a.md", count: 2)].map {
            BinderModel.title(firstName: $0.first, count: $0.count, language: language)
        }
        #expect(submenu.items.map(\.title) == titles + ["", clear])
        #expect(submenu.items[2].isSeparatorItem)

        submenu.performActionForItem(at: 3)
        #expect(preferences.recentBinders.isEmpty)
        file = try await openedFileMenu { !isListed($0) }
        #expect(!isListed(file))
    }

    // MARK: Closing a binder

    @Test("合本の窓を閉じると、手で並べた順のファイルが最近の合本の先頭に入る", .timeLimit(.minutes(1)))
    func remembersWhenTheWindowCloses() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.file("a.md")
        let second = try fixture.file("b.md")
        let model = fixture.windows.open([first, second])
        try #require(model.binder).move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(fixture.preferences.recentBinders.isEmpty)
        model.window?.close()
        #expect(fixture.preferences.recentBinders.entries.map(\.paths) == [[second.path, first.path]])
        #expect(fixture.preferences.recentBinders.entries[0].files.allSatisfy { $0.bookmark == nil })
    }

    @Test("同じファイルの合本を閉じ直しても1件のまま先頭に残る", .timeLimit(.minutes(1)))
    func closingTheSameBinderAgain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.file("a.md")
        let second = try fixture.file("b.md")
        let third = try fixture.file("c.md")
        fixture.windows.open([first, second]).window?.close()
        fixture.windows.open([second, third]).window?.close()
        fixture.windows.open([second, first]).window?.close()
        #expect(
            fixture.preferences.recentBinders.entries.map { Set($0.paths) }
                == [[first.path, second.path], [second.path, third.path]])
    }

    @Test("親のファイルが名指しした合本と、1文書に減った合本は覚えない", .timeLimit(.minutes(1)))
    func skipsWhatOpeningTheParentOrTheFilesBringsBack() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.file("a.md")
        let second = try fixture.file("b.md")
        let text = "<<[a.md]\n<<[b.md]\n"
        let parent = try fixture.file("index.md", text)
        let plan = try #require(MarkdownIncludes(markdown: text)).plan(parent: parent)
        fixture.windows.open(plan).window?.close()
        #expect(fixture.preferences.recentBinders.isEmpty)

        let model = fixture.windows.open([first, second])
        model.binder?.remove(second)
        #expect(model.binder?.urls == [first])
        model.window?.close()
        #expect(fixture.preferences.recentBinders.isEmpty)
    }

    @Test("合本への変換を取り消したときは、窓が閉じても最近の合本に残らない", .timeLimit(.minutes(1)))
    func undoingTheConversionLeavesNoEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let image = try fixture.file("a.png")
        let other = try fixture.file("b.md")
        try TestFixtures.png(red: 0.2).write(to: image)
        let model = fixture.windows.open([image, other])
        model.binderOrigin = BinderOrigin(
            contents: .images(ImageBundleModel(urls: [image]).listState),
            frame: NSRect(x: 0, y: 0, width: 400, height: 500), pageIndex: 0, wasPrinting: false)
        model.undoBinderConversion()
        defer { DocumentWindows.shared.openModels.first { $0.imageBundle?.urls == [image] }?.window?.close() }
        #expect(fixture.windows.hasWindows == false)
        #expect(fixture.preferences.recentBinders.isEmpty)
    }

    @Test("最近使った合本から開くと同じファイルの合本の窓ができ、閉じるとまた先頭に1件だけ残る", .timeLimit(.minutes(1)))
    func reopeningFromTheList() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.file("a.md")
        let second = try fixture.file("b.md")
        let third = try fixture.file("c.md")
        fixture.windows.open([first, second]).window?.close()
        fixture.windows.open([second, third]).window?.close()
        let entry = try #require(fixture.preferences.recentBinders.entries.last)
        #expect(Set(entry.paths) == [first.path, second.path])

        let windows = fixture.windows
        var reopened: DocumentViewModel?
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") }, openBundle: { _, _ in nil },
            openBinder: { urls, excluded in
                reopened = windows.open(urls, excluded: excluded)
                return reopened
            }, warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { windows.hasWindows },
            showWelcome: { Issue.record("ウェルカム画面は出さない") })
        router.open(recentBinder: entry)
        let model = try #require(reopened)
        #expect(model.binder?.urls == [first, second])
        model.window?.close()
        #expect(
            fixture.preferences.recentBinders.entries.map { Set($0.paths) }
                == [[first.path, second.path], [second.path, third.path]])
    }

    // MARK: Files in the sandbox

    private func recorder(
        resolve: @escaping (Data) throws -> (url: URL, stale: Bool) = { _ in throw CocoaError(.fileReadCorruptFile) },
        create: @escaping (URL) throws -> Data = { Data($0.path.utf8) },
        starts: @escaping (URL) -> Void = { _ in }, stops: @escaping (URL) -> Void = { _ in }
    ) -> FolderAccess.Backend {
        FolderAccess.Backend(
            create: create, resolve: resolve,
            start: { url in
                starts(url)
                return true
            }, stop: stops)
    }

    @Test("サンドボックスの外では、パスだけを覚えてブックマークは作らない")
    func pathsAreEnoughOutsideTheSandbox() {
        var creations = 0
        let files = RecentBinderFiles(
            backend: recorder(create: { _ in
                creations += 1
                return Data()
            }), isSandboxed: { false })
        let binder = files.binder(of: [url("/docs/a.md"), url("/docs/b.md")])
        #expect(binder.paths == ["/docs/a.md", "/docs/b.md"])
        #expect(binder.files.allSatisfy { $0.bookmark == nil })
        #expect(creations == 0)
    }

    @Test("サンドボックスでは、アクセスを取り直して各ファイルのブックマークを作り、作れないファイルはパスだけにする")
    func bookmarksInTheSandbox() {
        var active = 0
        var starts = 0
        let files = RecentBinderFiles(
            backend: recorder(
                create: { url in
                    if url.lastPathComponent == "b.md" { throw CocoaError(.fileReadNoPermission) }
                    #expect(active == 1)
                    return Data(url.path.utf8)
                },
                starts: { _ in
                    starts += 1
                    active += 1
                }, stops: { _ in active -= 1 }),
            isSandboxed: { true })
        let binder = files.binder(of: [url("/docs/a.md"), url("/docs/b.md"), url("/docs/c.md")])
        #expect(binder.paths == ["/docs/a.md", "/docs/b.md", "/docs/c.md"])
        #expect(binder.files.map(\.bookmark) == [Data("/docs/a.md".utf8), nil, Data("/docs/c.md".utf8)])
        #expect(starts == 3)
        #expect(active == 0)
    }

    @Test("サンドボックスで開くときは、動いたファイルをブックマークで探し、探せないファイルはパスで開く")
    func locatesByBookmark() {
        let moved = url("/moved/a.md")
        let files = RecentBinderFiles(
            backend: recorder(resolve: { data in
                guard data == Data([1]) else { throw CocoaError(.fileReadNoSuchFile) }
                return (moved, false)
            }), isSandboxed: { true })
        let located = files.locate(
            RecentBinder(files: [
                .init(path: "/docs/a.md", bookmark: Data([1])), .init(path: "/docs/b.md", bookmark: Data([2])),
                .init(path: "/docs/c.md"),
            ]))
        #expect(located.urls == [moved, url("/docs/b.md"), url("/docs/c.md")])
        #expect(located.leases.count == 1)
        located.keep(until: nil)
    }

    @Test("サンドボックスの外では、ブックマークがあってもパスから開く")
    func locatesByPathOutsideTheSandbox() {
        let files = RecentBinderFiles(
            backend: recorder(resolve: { _ in
                Issue.record("ブックマークは使わない")
                return (URL(fileURLWithPath: "/elsewhere"), false)
            }), isSandboxed: { false })
        let located = files.locate(
            RecentBinder(files: [.init(path: "/docs/a.md", bookmark: Data([1])), .init(path: "/docs/b.md")]))
        #expect(located.urls == [url("/docs/a.md"), url("/docs/b.md")])
        #expect(located.leases.isEmpty)
    }

    @Test("読み込みのアクセスは、窓を閉じる処理が終わるまで持ち、そのあとで手放す", .timeLimit(.minutes(1)))
    func accessLastsThroughTheWindowsClosing() async throws {
        var active = 0
        let files = RecentBinderFiles(
            backend: recorder(
                resolve: { _ in (URL(fileURLWithPath: "/docs/a.md"), false) },
                starts: { _ in active += 1 }, stops: { _ in active -= 1 }),
            isSandboxed: { true })
        let binder = RecentBinder(files: [
            .init(path: "/docs/a.md", bookmark: Data([1])), .init(path: "/docs/b.md", bookmark: Data([1])),
        ])
        // The window's own closing makes the bookmarks of its files, whichever of the two hears of it first.
        for closingHearsFirst in [true, false] {
            let window = closedWindow()
            let closing = ClosingProbe()
            var seen = -1
            closing.onClose = { seen = active }
            if closingHearsFirst { window.delegate = closing }
            files.locate(binder).keep(until: window)
            if !closingHearsFirst { window.delegate = closing }
            #expect(active == 2)
            window.close()
            #expect(seen == 2)
            for _ in 0..<100 where active > 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(active == 0)
        }
    }

    @Test("窓がなければ、読み込みのアクセスはすぐ手放す")
    func accessIsReleasedWithoutAWindow() {
        var starts = 0
        var active = 0
        let files = RecentBinderFiles(
            backend: recorder(
                resolve: { _ in (URL(fileURLWithPath: "/docs/a.md"), false) },
                starts: { _ in
                    starts += 1
                    active += 1
                }, stops: { _ in active -= 1 }),
            isSandboxed: { true })
        files.locate(RecentBinder(files: [.init(path: "/docs/a.md", bookmark: Data([1])), .init(path: "/docs/b.md")]))
            .keep(until: nil)
        #expect(starts == 1)
        #expect(active == 0)
    }

    @Test("動いたファイルの合本を開いて閉じても、最近の合本は新しいパスの1件のまま", .timeLimit(.minutes(1)))
    func reopeningAfterAFileMoved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let moved = try fixture.file("moved.md")
        let second = try fixture.file("b.md")
        let entry = RecentBinder(files: [
            .init(path: "/gone/a.md", bookmark: Data([1])), .init(path: second.path, bookmark: Data([2])),
        ])
        fixture.preferences.recordRecentBinder(entry)
        let windows = fixture.windows
        var reopened: DocumentViewModel?
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") }, openBundle: { _, _ in nil },
            openBinder: { urls, excluded in
                reopened = windows.open(urls, excluded: excluded)
                return reopened
            }, warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { windows.hasWindows },
            showWelcome: { Issue.record("ウェルカム画面は出さない") })
        router.recentFiles = RecentBinderFiles(
            backend: recorder(resolve: { $0 == Data([1]) ? (moved, false) : (second, false) }),
            isSandboxed: { true })
        router.replaceRecentBinder = { fixture.preferences.replaceRecentBinder($0, with: $1) }
        router.open(recentBinder: entry)
        #expect(fixture.preferences.recentBinders.entries.map(\.paths) == [[moved.path, second.path]])
        try #require(reopened).window?.close()
        let closed = fixture.preferences.recentBinders.entries
        #expect(closed.map { Set($0.paths) } == [[moved.path, second.path]])
        let bookmarks = Dictionary(uniqueKeysWithValues: closed[0].files.map { ($0.path, $0.bookmark) })
        #expect(bookmarks == [moved.path: Data([1]), second.path: Data([2])])
    }

    @Test("読めないファイルのある合本を閉じても、覚えていたブックマークは読み込み直しても残る", .timeLimit(.minutes(1)))
    func closingKeepsTheBookmarkOfAnAbsentFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let present = try fixture.file("a.md")
        let absent = fixture.root.appendingPathComponent("away.md").standardizedFileURL
        fixture.preferences.recordRecentBinder(
            RecentBinder(files: [
                .init(path: present.path, bookmark: Data([1])), .init(path: absent.path, bookmark: Data([2])),
            ]))
        fixture.windows.recentFiles = RecentBinderFiles(
            backend: recorder(create: { url in
                guard url == present else { throw CocoaError(.fileNoSuchFile) }
                return Data([3])
            }), isSandboxed: { true })
        fixture.windows.open([present, absent]).window?.close()
        let restored = AppPreferences(defaults: fixture.suite.defaults)
        #expect(restored.recentBinders.entries.map { $0.files.map(\.bookmark) } == [[Data([3]), Data([2])]])
    }

    @Test("システムのブックマークで作ったファイルは、同じファイルとして探し直せる", .timeLimit(.minutes(1)))
    func systemBookmarksFindTheSameFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.file("a.md")
        let second = try fixture.file("b.md")
        let files = RecentBinderFiles(isSandboxed: { true })
        let binder = files.binder(of: [first, second])
        #expect(binder.files.allSatisfy { $0.bookmark != nil })
        let located = files.locate(binder)
        #expect(
            located.urls.map { $0.resolvingSymlinksInPath().path }
                == [first, second].map { $0.resolvingSymlinksInPath().path })
        located.keep(until: nil)
    }
}

/// What a window controller is to its window: it hears that the window is about to close.
@MainActor
private final class ClosingProbe: NSObject, NSWindowDelegate {
    var onClose: () -> Void = {}

    func windowWillClose(_ notification: Notification) { onClose() }
}

import AppKit
import SurimonoCore
import Testing

@testable import Surimono

/// This store never writes a preferences file; UserDefaults synchronizes its volatile domains.
private final class BinderExitDefaults: UserDefaults, @unchecked Sendable {
    private let domain = UUID().uuidString
    override func object(forKey key: String) -> Any? { volatileDomain(forName: domain)[key] }
    override func set(_ value: Any?, forKey key: String) {
        var values = volatileDomain(forName: domain)
        values[key] = value
        setVolatileDomain(values, forName: domain)
    }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
}

@MainActor
struct BinderExitTests {
    /// Model tests drive rendering explicitly; an invisible SwiftUI tree must not schedule extra renders.
    @MainActor
    private final class WindowController: NSWindowController, NSWindowDelegate {
        let model: DocumentViewModel
        let onClose: () -> Void
        private let history = UndoManager()

        init(model: DocumentViewModel, onClose: @escaping () -> Void) {
            self.model = model
            self.onClose = onClose
            let window = NSWindow(
                contentRect: NSRect(x: 160, y: 180, width: 600, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            super.init(window: window)
            model.window = window
            window.delegate = self
        }

        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history }

        required init?(coder: NSCoder) { nil }

        override func close() {
            model.stop()
            onClose()
            super.close()
        }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let defaults = BinderExitDefaults()
        let preferences: AppPreferences
        let library: UserLibrary
        let store: DocumentSettingsStore
        var controllers: [WindowController] = []
        var closed: Set<ObjectIdentifier> = []
        var target: DocumentViewModel?
        var task: Task<Void, Never>?
        var questions = 0
        var answer: ((BinderExit.Answer) -> Void)?
        var front: NSWindow?
        var opens = 0
        var failsToOpen = false
        private var pending: ((OpenRouter.OpenedFile?) -> Void)?
        private func finish(_ opened: OpenRouter.OpenedFile?) {
            let completion = pending
            pending = nil
            completion?(opened)
        }
        lazy var router = OpenRouter(
            openDocument: { [unowned self] url, completion in
                opens += 1
                if failsToOpen {
                    completion(nil)
                    return
                }
                // The callback is not Sendable, so the task reaches it through the fixture instead of capturing it.
                pending = completion
                task = Task { @MainActor [unowned self] in
                    do {
                        let model = try document(url)
                        target = model
                        await render(model)
                        finish(.testWindow(model))
                    } catch {
                        Issue.record("テスト用文書を開けませんでした: \(error)")
                        finish(nil)
                    }
                }
            }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in },
            hasOpenWindows: { false }, showWelcome: {},
            openWindows: { [unowned self] in
                controllers.map(\.model).filter { !closed.contains(ObjectIdentifier($0)) }
            }, isActive: { false })

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            preferences = AppPreferences(defaults: defaults)
            library = UserLibrary(root: root.appendingPathComponent("Library"))
            store = DocumentSettingsStore(directory: root.appendingPathComponent("Settings"))
        }

        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try TestFixtures.pdf(name, pages: 4).write(to: url)
            return url
        }

        func attach(_ model: DocumentViewModel) -> DocumentViewModel {
            model.printerListSource = { .init(names: [], defaultName: nil) }
            model.printSubmit = { _, _, _ in Issue.record("印刷送信を要求しました") }
            model.outputOverride = { _, _ in Issue.record("出力を要求しました") }
            let controller = WindowController(model: model) { [weak self, weak model] in
                if let model { self?.closed.insert(ObjectIdentifier(model)) }
            }
            controllers.append(controller)
            controller.window?.setFrame(NSRect(x: 160, y: 180, width: 600, height: 720), display: false)
            model.binderExit.router = router
            model.binderExit.ask = { [unowned self] _, completion in
                questions += 1
                answer = completion
            }
            model.binderExit.bringForward = { [unowned self] in front = $0 }
            model.binderExit.openMemory = { [unowned self] data, format, title in
                let target = attach(
                    DocumentViewModel(
                        data: data, fileURL: nil, format: format, preferences: preferences, library: library,
                        settingsStore: store, title: title))
                self.target = target
                task = Task { @MainActor in await render(target) }
                return target
            }
            return model
        }

        func document(_ url: URL) throws -> DocumentViewModel {
            attach(
                DocumentViewModel(
                    data: try Data(contentsOf: url), fileURL: url, format: .pdf, preferences: preferences,
                    library: library, settingsStore: store))
        }

        func binder(_ urls: [URL], memory: Data? = nil) -> DocumentViewModel {
            let binder =
                memory.map { BinderModel(memory: $0, format: .pdf, title: "Clipboard", urls: urls) }
                ?? BinderModel(orderedURLs: urls)
            let model = attach(
                DocumentViewModel(
                    data: Data(), fileURL: nil, format: .pdf, preferences: preferences, library: library,
                    settingsStore: store, binder: binder))
            model.isDrawerOpen = true
            return model
        }

        func render(_ model: DocumentViewModel) async {
            await withCheckedContinuation { continuation in
                let previous = model.onFirstRender
                model.onFirstRender = { succeeded in
                    previous?(succeeded)
                    #expect(succeeded)
                    continuation.resume()
                }
                model.start()
            }
            // A first render can precede the detached hash and saved-settings load.
            // With no SwiftUI observers, the fixture explicitly drives that second layout.
            await BinderExitTests.waitUntil { model.contentHash != nil }
            #expect(model.contentHash != nil)
            if !model.isUpToDate && !model.isRendering { model.renderForChangedSettings() }
            await BinderExitTests.waitUntil { !model.isRendering }
            #expect(!model.isRendering)
            #expect(model.isUpToDate)
            #expect(model.error == nil)
        }

        func clean() {
            for controller in controllers { controller.close() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func waitUntil(_ ready: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while !ready(), clock.now < deadline { await Task.yield() }
    }

    @Test(
        "取り除いて一文書になったときだけ三つの方針に従う", .timeLimit(.minutes(1)),
        arguments: SingleDocumentBinderPolicy.allCases)
    func policies(_ policy: SingleDocumentBinderPolicy) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.preferences.singleDocumentBinderPolicy = policy
        let a = try f.file("a.pdf")
        let b = try f.file("b.pdf")
        let original = try Data(contentsOf: b)
        let model = f.binder([a, b])
        #expect(!model.binderExit.canLeave(model))
        model.removeFromBinder(b)
        await f.router.waitForOpeningRequests()
        await f.task?.value
        #expect(f.questions == (policy == .ask ? 1 : 0))
        #expect(f.opens == (policy == .leave ? 1 : 0))
        #expect(f.closed.contains(ObjectIdentifier(model)) == (policy == .leave))
        #expect(try Data(contentsOf: b) == original)
    }

    @Test(
        "確認の両回答と次回から確認しない指定を保存する", .timeLimit(.minutes(1)),
        arguments: [false, true], [false, true])
    func answers(leave: Bool, suppress: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let model = f.binder([try f.file("a.pdf"), try f.file("b.pdf")])
        model.removeFromBinder(try #require(model.binder?.urls.last))
        let answer = try #require(f.answer)
        answer(.init(leave: leave, suppress: suppress))
        await f.router.waitForOpeningRequests()
        await f.task?.value
        #expect(f.closed.contains(ObjectIdentifier(model)) == leave)
        let saved = AppPreferences(defaults: f.defaults).singleDocumentBinderPolicy
        #expect(saved == (suppress ? (leave ? .leave : .stay) : .ask))
        if !leave {
            #expect(model.showsSideList)
            #expect(model.binderExit.canLeave(model))
        }
        f.preferences.singleDocumentBinderPolicy = .ask
        #expect(AppPreferences(defaults: f.defaults).singleDocumentBinderPolicy == .ask)
    }

    @Test(
        "解除すると元の文書の設定と読書位置とウインドウの原点を戻す", .timeLimit(.minutes(1)),
        arguments: [false, true])
    func settingsAndPosition(printing: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.file("a.pdf")
        let b = try f.file("b.pdf")
        var saved = DocumentSettings()
        saved.layoutID = "b5Single"
        // An exact page is meaningful in single-page mode; a spread reports its first page instead.
        saved.view = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        try f.store.save(saved, for: ContentHash.of(Data(contentsOf: a)).hex)
        let model = f.binder([a, b])
        await f.render(model)
        model.currentPageIndex = 2
        if printing {
            model.mode = .print
            model.currentPageIndex = 0
            model.binderTrayPageIndex = 2
        }
        let frame = try #require(model.window?.frame)
        model.removeFromBinder(b)
        let answer = try #require(f.answer)
        answer(.init(leave: true, suppress: false))
        await f.router.waitForOpeningRequests()
        await f.task?.value
        let target = try #require(f.target)
        await Self.waitUntil { !target.isRendering }
        #expect(!target.isRendering, "解除後の描画が完了する")
        #expect(target.isUpToDate, "保存設定に対応する描画が完了する")
        #expect(target.error == nil)
        #expect(target.fileURL == a)
        #expect(target.binder == nil)
        #expect(!target.showsSideList)
        #expect(target.displayName == "a.pdf")
        #expect(target.window?.frame.origin == frame.origin, "合本のウインドウ原点を引き継ぐ")
        #expect(target.layoutID == "b5Single", "単独文書自身の保存設定を戻す")
        #expect(target.viewOptions == saved.view, "単独文書自身の表示設定を戻す")
        #expect(target.currentPageIndex == 2, "残った文書内の読書位置を戻す")
        #expect(target.mode == (printing ? .print : .view))
        if printing {
            let tray = try #require(target.printTray)
            let page = try #require(tray.bodyPage(at: 2))
            let row = try #require(tray.rowID(containing: page))
            #expect(target.requestedTrayRow == row, "印刷画面でも対応する用紙へ移る")
        }
        #expect(f.closed.contains(ObjectIdentifier(model)))
    }

    @Test("同じ文書が開いていれば読書位置と原点を保って前面に出す", .timeLimit(.minutes(1)))
    func alreadyOpen() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.file("a.pdf")
        let existing = try f.document(a)
        await f.render(existing)
        existing.currentPageIndex = 3
        let frame = existing.window?.frame
        // The test host is the active app on a CI runner and a background app on a developer's Mac, so the check is
        // that bringing the window forward leaves the app's activation as it was.
        let wasActive = NSApp.isActive
        let model = f.binder([a, try f.file("b.pdf")])
        f.preferences.singleDocumentBinderPolicy = .leave
        model.removeFromBinder(try #require(model.binder?.urls.last))
        #expect(f.front === existing.window)
        #expect(f.opens == 0)
        #expect(existing.currentPageIndex == 3)
        #expect(existing.window?.frame == frame)
        #expect(f.closed.contains(ObjectIdentifier(model)))
        #expect(NSApp.isActive == wasActive)
    }

    @Test(
        "合本解除の判定中に開いた単独窓はページと位置を保ち、元が印刷中なら刷り台を頼む",
        .timeLimit(.minutes(1)), arguments: [false, true])
    func windowOpenedWhileLeaving(wasPrinting: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let url = try f.file("same.pdf")
        var existing: DocumentViewModel?
        let router = OpenRouter(
            openDocument: { _, done in done(.testWindow(existing, reused: true)) }, openBundle: { _, _ in nil },
            openBinder: { _, _ in nil },
            warn: { _ in }, hasOpenWindows: { true }, showWelcome: {}, openWindows: { existing.map { [$0] } ?? [] })
        let release = DispatchSemaphore(value: 0)
        let origin = BinderOrigin(
            contents: .document(url), frame: NSRect(x: 10, y: 20, width: 400, height: 500),
            pageIndex: 1, wasPrinting: wasPrinting, leavingBinder: true)
        await withCheckedContinuation { entered in
            router.route = { @Sendable _ in
                entered.resume()
                release.wait()
                return .document
            }
            router.reopen(url, restoring: origin) { opened in #expect(opened) }
        }
        let model: DocumentViewModel
        let frame: NSRect
        do {
            defer { release.signal() }
            model = try f.document(url)
            await f.render(model)
            model.currentPageIndex = 3
            existing = model
            frame = try #require(model.window?.frame)
        }
        await router.waitForOpeningRequests()
        #expect(model.currentPageIndex == 3)
        #expect(model.window?.frame == frame)
        #expect((model.isPrintModeRequested || model.mode == .print) == wasPrinting)
    }

    @Test("残ったメモリ文書も保存先を作らず単独文書に戻す", .timeLimit(.minutes(1)))
    func memory() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let bytes = TestFixtures.pdf("memory")
        let b = try f.file("b.pdf")
        try f.store.save(DocumentSettings(layoutID: "b5Single"), for: ContentHash.of(bytes).hex)
        let model = f.binder([b], memory: bytes)
        f.preferences.singleDocumentBinderPolicy = .leave
        model.removeFromBinder(b)
        await f.router.waitForOpeningRequests()
        await f.task?.value
        let target = try #require(f.target)
        #expect(!target.isRendering)
        #expect(target.isUpToDate)
        #expect(target.contentHash != nil)
        #expect(target.memoryContent == bytes)
        #expect(target.fileURL == nil)
        #expect(target.binder == nil)
        #expect(target.displayName == "Clipboard")
        #expect(target.layoutID == "b5Single")
        #expect(f.opens == 0)
        #expect(f.closed.contains(ObjectIdentifier(model)))
    }

    @Test("開く復元と追加の取り消しでは確認せず後から一覧で解除できる", .timeLimit(.minutes(1)))
    func noPromptOnRestoreOrUndo() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.file("a.pdf")
        let b = try f.file("b.pdf")
        let digest = ContentHash.of(try Data(contentsOf: a))
        try f.store.save(
            DocumentSettings(binderOrder: [digest.hex], binderStartsOnFront: true),
            for: ContentHash.binderSet([digest]).hex)
        let model = f.binder([a])
        await f.render(model)
        #expect(model.binderStartsOnFront)
        #expect(f.questions == 0)
        #expect(model.binderExit.canLeave(model))
        let undo = try #require(model.window?.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.add([b])
        undo.endUndoGrouping()
        #expect(!model.binderExit.canLeave(model))
        undo.undo()
        #expect(model.binder?.items.count == 1)
        #expect(f.questions == 0)
        model.binderExit.leave(model)
        await f.router.waitForOpeningRequests()
        await f.task?.value
        #expect(f.opens == 1)
        #expect(f.questions == 0)
    }
    @Test("取り除きの取り消しは確認せずやり直しは新たに確認する")
    func undoRemoval() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.file("a.pdf")
        let b = try f.file("b.pdf")
        let model = f.binder([a, b])
        let undo = try #require(model.window?.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.removeFromBinder(b)
        undo.endUndoGrouping()
        let answer = try #require(f.answer)
        answer(.init(leave: false, suppress: false))
        undo.undo()
        #expect(f.questions == 1)
        #expect(model.binder?.items.count == 2)
        undo.redo()
        #expect(f.questions == 2)
        #expect(model.binder?.items.count == 1)
    }

    @Test("閉じた合本への遅れた回答は設定も文書も変えない")
    func closedQuestion() throws {
        let f = try Fixture()
        defer { f.clean() }
        let model = f.binder([try f.file("a.pdf"), try f.file("b.pdf")])
        model.removeFromBinder(try #require(model.binder?.urls.last))
        model.window?.windowController?.close()
        let answer = try #require(f.answer)
        answer(.init(leave: true, suppress: true))
        #expect(f.opens == 0)
        #expect(f.preferences.singleDocumentBinderPolicy == .ask)
    }

    @Test("単独文書を開けなければ合本を残して解除を再試行できる")
    func failedOpen() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let model = f.binder([try f.file("a.pdf"), try f.file("b.pdf")])
        f.failsToOpen = true
        f.preferences.singleDocumentBinderPolicy = .leave
        model.removeFromBinder(try #require(model.binder?.urls.last))
        await f.router.waitForOpeningRequests()
        #expect(!f.closed.contains(ObjectIdentifier(model)))
        #expect(model.binderExit.canLeave(model))
        #expect(model.showsSideList)
    }

}

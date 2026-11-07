import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct AddDocumentsTests {
    @MainActor
    private final class Fixture {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences: AppPreferences
        let library: UserLibrary
        let store: DocumentSettingsStore
        let windows = BinderWindows()

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            preferences = AppPreferences(defaults: suite.defaults)
            library = UserLibrary(root: root.appendingPathComponent("Library"))
            store = DocumentSettingsStore(directory: root.appendingPathComponent("Settings"))
            windows.preferences = preferences
            windows.library = library
            windows.settingsStore = store
        }

        func file(_ name: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(name).standardizedFileURL
            try data.write(to: url)
            return url
        }

        func document(_ url: URL, data: Data, format: DocumentFormat) -> DocumentViewModel {
            let model = DocumentViewModel(
                data: data, fileURL: url, format: format, preferences: preferences, library: library,
                settingsStore: store)
            let window = NSWindow(
                contentRect: NSRect(x: 400, y: 200, width: 500, height: 600),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
            // The window is closed in place of the document's own controller, and this test still holds it.
            window.isReleasedWhenClosed = false
            model.window = window
            return model
        }

        func binder(_ urls: [URL]) -> DocumentViewModel {
            let model = DocumentViewModel(
                data: Data(), fileURL: nil, format: .pdf, preferences: preferences, library: library,
                binder: BinderModel(urls: urls))
            model.window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered,
                defer: true)
            return model
        }

        deinit {
            suite.remove()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixture/" + name) }

    /// One step of the reader's, which the undo manager otherwise groups by the event they came from.
    private func step(_ undo: UndoManager, _ action: () -> Void) {
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    @Test("窓の種類で受け手が決まり、ファイルのない文書と見比べ台は足せない")
    func receivers() throws {
        let fixture = try Fixture()
        let file = url("a.md")
        let document = fixture.document(file, data: Data("# A".utf8), format: .markdown)
        defer { document.stop() }
        #expect(document.dropReceiver == .document(file))
        document.mode = .compare
        #expect(document.dropReceiver == .closed(own: file))
        let binder = fixture.binder([url("a.md"), url("b.pdf")])
        defer { binder.stop() }
        #expect(binder.dropReceiver == .binder([url("a.md"), url("b.pdf")]))
        let memory = DocumentViewModel(
            data: Data("x".utf8), fileURL: nil, format: .plainText, preferences: fixture.preferences,
            library: fixture.library, title: "Clipboard")
        defer { memory.stop() }
        #expect(memory.dropReceiver == .closed(own: nil))
        memory.chooseDocumentsToAdd()
        #expect(memory.toast?.detail == String(localized: "A document without a file cannot join a binder"))
    }

    @Test("足す物だけを自然順に並べて指定の位置へ入れ、今の並びは変えない")
    func addAtPosition() throws {
        let model = BinderModel(orderedURLs: [url("b.md"), url("a.md")])
        let added = model.add([url("10.md"), url("2.md"), url("a.md")], at: 1)
        #expect(added == [url("2.md"), url("10.md")])
        #expect(model.urls == [url("b.md"), url("2.md"), url("10.md"), url("a.md")])
    }

    @Test("1 回の追加は 1 回の取り消しで戻り、やり直せる")
    func undoAdding() throws {
        let fixture = try Fixture()
        let model = fixture.binder([url("a.md"), url("b.md")])
        defer { model.stop() }
        let undo = try #require(model.window?.undoManager)
        model.add([url("d.md"), url("c.md")])
        #expect(model.binder?.urls == [url("a.md"), url("b.md"), url("c.md"), url("d.md")])
        undo.undo()
        #expect(model.binder?.urls == [url("a.md"), url("b.md")])
        undo.redo()
        #expect(model.binder?.urls == [url("a.md"), url("b.md"), url("c.md"), url("d.md")])
    }

    @Test("足す取り消しはそのあとの並べ替えを戻さず、足した物だけを外す")
    func undoKeepsLaterOrder() throws {
        let fixture = try Fixture()
        let model = fixture.binder([url("a.md"), url("b.md")])
        defer { model.stop() }
        let undo = try #require(model.window?.undoManager)
        model.add([url("c.md")])
        model.binder?.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(model.binder?.urls == [url("b.md"), url("a.md"), url("c.md")])
        undo.undo()
        #expect(model.binder?.urls == [url("b.md"), url("a.md")])
    }

    @Test("足したあとに元の文書を外しても、取り消しの順に戻せて空にならない")
    func undoAfterRemovals() throws {
        let fixture = try Fixture()
        let model = fixture.binder([url("a.md"), url("b.md")])
        defer { model.stop() }
        let undo = try #require(model.window?.undoManager)
        step(undo) { model.add([url("c.md")]) }
        step(undo) { model.removeFromBinder(url("a.md")) }
        step(undo) { model.removeFromBinder(url("b.md")) }
        #expect(model.binder?.urls == [url("c.md")])
        undo.undo()
        #expect(model.binder?.urls == [url("b.md"), url("c.md")])
        undo.undo()
        #expect(model.binder?.urls == [url("a.md"), url("b.md"), url("c.md")])
        undo.undo()
        #expect(model.binder?.urls == [url("a.md"), url("b.md")])
        undo.redo()
        #expect(model.binder?.urls == [url("a.md"), url("b.md"), url("c.md")])
    }

    @Test("足せなかった物の記録は、足したときの分だけ取り消しで消え、前からの記録は残る")
    func undoLeftOut() throws {
        let fixture = try Fixture()
        let model = fixture.binder([url("a.md")])
        defer { model.stop() }
        let undo = try #require(model.window?.undoManager)
        step(undo) { model.add([url("b.md"), url("old.zip")]) }
        step(undo) { model.add([url("c.md"), url("old.zip"), url("new.zip")]) }
        #expect(model.binder?.excludedURLs == [url("old.zip"), url("new.zip")])
        undo.undo()
        #expect(model.binder?.excludedURLs == [url("old.zip")])
        undo.redo()
        #expect(model.binder?.excludedURLs == [url("old.zip"), url("new.zip")])
    }

    @Test("画像の束を呼び戻すと、読んでいた画像の選択も戻る")
    func bundleStateKeepsSelection() {
        let model = ImageBundleModel(urls: [url("1.png"), url("2.png")])
        model.selection = url("2.png")
        let state = model.listState
        let reopened = ImageBundleModel(urls: [url("1.png"), url("2.png")])
        reopened.restore(state)
        #expect(reopened.selection == url("2.png"))
    }

    @Test("組版の前に失敗しても最初の組版の知らせが届く")
    func firstRenderReportsEarlyFailure() throws {
        let fixture = try Fixture()
        let model = fixture.document(url("a.md"), data: Data(), format: .markdown)
        defer { model.stop() }
        model.failToOpen("x")
        var reported: Bool?
        model.onFirstRender = { reported = $0 }
        model.render()
        #expect(reported == false)
    }

    @Test("画像の前に足しても読んでいた画像のまま")
    func imagesKeepReading() async throws {
        let fixture = try Fixture()
        let first = try fixture.file("1.png", TestFixtures.png(red: 0.1))
        let second = try fixture.file("2.png", TestFixtures.png(red: 0.2))
        let added = try fixture.file("0.png", TestFixtures.png(red: 0.3))
        let bundle = ImageBundleModel(urls: [first, second])
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image, preferences: fixture.preferences, library: fixture.library,
            imageBundle: bundle)
        defer { model.stop() }
        model.render()
        try await wait { !model.isRendering && model.result != nil }
        model.paperDidChangePage(1)
        #expect(bundle.selection == second)
        bundle.add([added], at: 0)
        model.render()
        try await wait { !model.isRendering }
        #expect(model.currentPageIndex == 2)
    }

    @Test("すでに入っている物は足さず、その行を光らせて知らせる")
    func alreadyIn() throws {
        let fixture = try Fixture()
        let model = fixture.binder([url("a.md"), url("b.md")])
        defer { model.stop() }
        model.add([url("b.md")])
        #expect(model.binder?.urls == [url("a.md"), url("b.md")])
        #expect(model.binder?.flashedURLs == [url("b.md")])
        #expect(model.toast?.title == String(localized: "Already in this window"))
    }

    @Test("足せない物は足せる物と一緒に落としても一覧の下に残る")
    func leftOut() throws {
        let fixture = try Fixture()
        let model = fixture.binder([url("a.md")])
        defer { model.stop() }
        model.add([url("b.md"), url("c.zip")])
        #expect(model.binder?.urls == [url("a.md"), url("b.md")])
        #expect(model.binder?.excludedURLs == [url("c.zip")])
    }

    @Test("画像の束に足すと名前順の基準も増え、取り消すと戻る")
    func bundleAdds() {
        let model = ImageBundleModel(urls: [url("1.png"), url("3.png")])
        let state = model.listState
        #expect(model.add([url("2.png")]) == [url("2.png")])
        #expect(model.urls == [url("1.png"), url("3.png"), url("2.png")])
        #expect(!model.isSortedByName)
        model.sortByName()
        #expect(model.urls == [url("1.png"), url("2.png"), url("3.png")])
        model.restore(state)
        #expect(model.urls == [url("1.png"), url("3.png")])
        #expect(model.isSortedByName)
    }

    @Test("単独の文書を合本に変えると今の文書が先頭で今の形を引き継ぎ、組版のあとで元の窓を閉じる")
    func conversion() async throws {
        let fixture = try Fixture()
        let own = try fixture.file("z.pdf", TestFixtures.pdf("own", pages: 2))
        let other = try fixture.file("a.pdf", TestFixtures.pdf("other", pages: 1))
        let source = fixture.document(own, data: TestFixtures.pdf("own", pages: 2), format: .pdf)
        defer { source.stop() }
        source.layoutID = PrintLayout.a4Duplex.id
        source.currentPageIndex = 1
        let closing = try #require(source.window)
        closing.orderFront(nil)
        fixture.windows.turnIntoBinder(source, adding: [other], leftOut: [])
        try await wait { fixture.windows.hasWindows }
        let binder = try #require(DocumentWindows.shared.openModels.first { $0.binder?.urls.contains(own) == true })
        defer { binder.window?.close() }
        #expect(binder.binder?.urls == [own, other])
        #expect(binder.layoutID == PrintLayout.a4Duplex.id)
        #expect(binder.currentPageIndex == 1)
        #expect(binder.isDrawerOpen)
        #expect(!closing.isVisible)
        #expect(binder.toast?.action == .undoBinder)
        #expect(binder.binderOrigin?.pageIndex == 1)
    }

    @Test("合本の組版を待つ間、元の窓は出力できず、同じ変換をもう一度始めない")
    func waitingForTheBinder() async throws {
        let fixture = try Fixture()
        let bytes = TestFixtures.pdf("own")
        let own = try fixture.file("own.pdf", bytes)
        let other = try fixture.file("other.pdf", TestFixtures.pdf("other"))
        let source = fixture.document(own, data: bytes, format: .pdf)
        defer { source.stop() }
        source.window?.orderFront(nil)
        source.mode = .print
        source.render()
        try await wait { !source.isRendering && source.canOutput }
        fixture.windows.turnIntoBinder(source, adding: [other], leftOut: [])
        #expect(!source.canOutput)
        fixture.windows.turnIntoBinder(source, adding: [other], leftOut: [])
        #expect(fixture.windows.pending.count == 1)
        try await wait { fixture.windows.pending.isEmpty }
        DocumentWindows.shared.openModels.first { $0.binder?.urls.contains(own) == true }?.window?.close()
    }

    @Test("組版の間に元の窓を閉じたら合本を出さず、何も残さない")
    func sourceClosedWhileWaiting() async throws {
        let fixture = try Fixture()
        let bytes = TestFixtures.pdf("own")
        let own = try fixture.file("own.pdf", bytes)
        let other = try fixture.file("other.pdf", TestFixtures.pdf("other"))
        let source = fixture.document(own, data: bytes, format: .pdf)
        defer { source.stop() }
        source.window?.orderFront(nil)
        fixture.windows.turnIntoBinder(source, adding: [other], leftOut: [])
        source.window?.close()
        try await wait { fixture.windows.pending.isEmpty }
        #expect(!fixture.windows.hasWindows)
    }

    @Test("表示用の用紙の系列も引き継ぐ")
    func takesOverPaperSeries() throws {
        let fixture = try Fixture()
        let source = fixture.document(url("a.md"), data: Data("# A".utf8), format: .markdown)
        defer { source.stop() }
        source.paperSeries = .b
        let binder = fixture.binder([url("a.md"), url("b.md")])
        defer { binder.stop() }
        binder.takeOver(from: source)
        #expect(binder.paperSeries == .b)
    }

    @Test("引き継いだ形が既定と同じでも、同じ組の古い記録を置き換える")
    func conversionReplacesOldRecord() async throws {
        let fixture = try Fixture()
        let bytes = TestFixtures.pdf("own")
        let otherBytes = TestFixtures.pdf("other")
        let own = try fixture.file("own.pdf", bytes)
        let other = try fixture.file("other.pdf", otherBytes)
        let key = ContentHash.binderSet([.of(bytes), .of(otherBytes)])
        var saved = DocumentSettings()
        saved.layoutID = PrintLayout.a4Duplex.id
        try fixture.store.save(saved, for: key.hex)
        let source = fixture.document(own, data: bytes, format: .pdf)
        defer { source.stop() }
        source.window?.orderFront(nil)
        fixture.windows.turnIntoBinder(source, adding: [other], leftOut: [])
        try await wait { fixture.windows.hasWindows }
        let binder = try #require(DocumentWindows.shared.openModels.first { $0.binder?.urls.contains(own) == true })
        defer { binder.window?.close() }
        try await wait { fixture.store.record(for: key.hex)?.layoutID == source.layoutID }
    }

    @Test("一覧が変わったら待っていた出力は動かない")
    func listChangeCancelsWaitingOutput() async throws {
        let fixture = try Fixture()
        let first = try fixture.file("a.pdf", TestFixtures.pdf("a"))
        let model = fixture.binder([first])
        defer { model.stop() }
        model.render()
        try await wait { !model.isRendering }
        model.layoutID = PrintLayout.a4Duplex.id
        model.exportPDF()
        #expect(model.hasWaitingOutput)
        model.listDidChange()
        #expect(!model.hasWaitingOutput)
    }

    @Test("同じ組の合本が開いていればその窓を前へ出し、元の窓は残す")
    func conversionFindsOpenBinder() async throws {
        let fixture = try Fixture()
        let own = try fixture.file("own.pdf", TestFixtures.pdf("own"))
        let other = try fixture.file("other.pdf", TestFixtures.pdf("other"))
        let open = fixture.windows.open([own, other])
        defer { open.window?.close() }
        let source = fixture.document(own, data: TestFixtures.pdf("own"), format: .pdf)
        defer { source.stop() }
        let window = try #require(source.window)
        window.orderFront(nil)
        defer { window.close() }
        fixture.windows.turnIntoBinder(source, adding: [other], leftOut: [])
        #expect(window.isVisible)
        #expect(source.toast == nil)
    }

    @Test("どの文書も読めなければ元の窓のままで理由を出す")
    func conversionFails() async throws {
        let fixture = try Fixture()
        let own = fixture.root.appendingPathComponent("gone.pdf").standardizedFileURL
        let other = fixture.root.appendingPathComponent("gone2.pdf").standardizedFileURL
        let source = fixture.document(own, data: TestFixtures.pdf("own"), format: .pdf)
        defer { source.stop() }
        let window = try #require(source.window)
        window.orderFront(nil)
        defer { window.close() }
        fixture.windows.turnIntoBinder(source, adding: [other], leftOut: [])
        try await wait { source.toast != nil }
        #expect(source.toast?.title == String(localized: "Could not make the binder"))
        #expect(window.isVisible)
        #expect(!fixture.windows.hasWindows)
    }

    @Test("引き継いだ形は同じ組の保存済みの設定より優先し、元の文書の記録は変えない")
    func conversionKeepsLook() async throws {
        let fixture = try Fixture()
        let bytes = TestFixtures.pdf("own")
        let otherBytes = TestFixtures.pdf("other")
        let own = try fixture.file("own.pdf", bytes)
        let other = try fixture.file("other.pdf", otherBytes)
        let key = ContentHash.binderSet([.of(bytes), .of(otherBytes)])
        var saved = DocumentSettings()
        saved.layoutID = PrintLayout.a4Single.id
        try fixture.store.save(saved, for: key.hex)
        let source = fixture.document(own, data: bytes, format: .pdf)
        defer { source.stop() }
        source.layoutID = PrintLayout.a4Duplex.id
        source.window?.orderFront(nil)
        fixture.windows.turnIntoBinder(source, adding: [other], leftOut: [])
        try await wait { fixture.windows.hasWindows }
        let binder = try #require(DocumentWindows.shared.openModels.first { $0.binder?.urls.contains(own) == true })
        defer { binder.window?.close() }
        try await wait { binder.contentHash == key }
        #expect(binder.layoutID == PrintLayout.a4Duplex.id)
        try await wait { fixture.store.record(for: key.hex)?.layoutID == PrintLayout.a4Duplex.id }
        #expect(fixture.store.record(for: ContentHash.of(bytes).hex) == nil)
    }

    @Test("組み直しの間は古い内容で出力させない")
    func noOutputWhileRelaying() async throws {
        let fixture = try Fixture()
        let first = try fixture.file("a.pdf", TestFixtures.pdf("a"))
        let second = try fixture.file("b.pdf", TestFixtures.pdf("b"))
        let model = fixture.binder([first])
        defer { model.stop() }
        model.mode = .print
        model.render()
        try await wait { !model.isRendering && model.canOutput }
        model.add([second])
        #expect(!model.canOutput)
        model.listDidChange()
        #expect(!model.canOutput)
        try await wait { !model.isRendering }
        #expect(model.canOutput)
    }
}

@MainActor
struct DropSessionTests {
    private func plan(_ receiver: DropPlan.Receiver) -> DropPlan {
        DropPlan(urls: [URL(fileURLWithPath: "/fixture/new.md")], receiver: receiver)
    }

    @Test("単独の文書では左の 38% が合本にする領域になる")
    func zones() {
        let session = DropSession()
        session.size = CGSize(width: 1000, height: 800)
        session.begin(plan(.document(URL(fileURLWithPath: "/fixture/own.md"))), rows: [], at: CGPoint(x: 370, y: 10))
        #expect(session.zone == .join)
        session.move(to: CGPoint(x: 390, y: 10))
        #expect(session.zone == .open)
        session.end()
        #expect(!session.isActive)
    }

    @Test("受け付けないときは領域がなく、落とせない")
    func refused() {
        let session = DropSession()
        let own = URL(fileURLWithPath: "/fixture/own.md")
        session.begin(DropPlan(urls: [own], receiver: .document(own)), rows: [], at: .zero)
        #expect(session.zone == nil)
        #expect(!session.move(to: CGPoint(x: 10, y: 10)))
    }

    @Test("一覧の行の間にポインタがあるとその位置に入り、一覧の外では末尾になる")
    func insertion() {
        let session = DropSession()
        let rows = ["a", "b"].map { URL(fileURLWithPath: "/fixture/\($0).md") }
        session.rowFrames = [
            rows[0]: CGRect(x: 0, y: 100, width: 200, height: 50),
            rows[1]: CGRect(x: 0, y: 150, width: 200, height: 50),
        ]
        session.listFrame = CGRect(x: 0, y: 100, width: 200, height: 300)
        session.begin(plan(.binder(rows)), rows: rows, at: CGPoint(x: 50, y: 140))
        #expect(session.insertion == 1)
        #expect(session.insertionY == 150)
        session.move(to: CGPoint(x: 50, y: 110))
        #expect(session.insertion == 0)
        session.move(to: CGPoint(x: 50, y: 300))
        #expect(session.insertion == nil)
        #expect(session.insertionY == 200)
        session.move(to: CGPoint(x: 500, y: 140))
        #expect(session.insertion == nil)
        #expect(session.insertionY == nil)
    }

    @Test("一覧の部品に 0.5 秒とどまると一覧が開き、離れると開かない")
    func spring() async throws {
        let session = DropSession()
        var opened = 0
        session.onSpring = { opened += 1 }
        session.listButtonFrame = CGRect(x: 0, y: 0, width: 50, height: 20)
        let rows = [URL(fileURLWithPath: "/fixture/a.md")]
        session.begin(plan(.binder(rows)), rows: rows, at: CGPoint(x: 100, y: 100))
        session.move(to: CGPoint(x: 10, y: 10))
        session.move(to: CGPoint(x: 100, y: 100))
        try await Task.sleep(for: .milliseconds(650))
        #expect(opened == 0)
        session.move(to: CGPoint(x: 10, y: 10))
        try await Task.sleep(for: .milliseconds(650))
        #expect(opened == 1)
    }

    @Test("落とす前の文章は同じ判定から作る")
    func copy() {
        let own = URL(fileURLWithPath: "/fixture/own.md")
        let plan = plan(.document(own))
        let join = DropCopy.join(.newBinder, plan: plan, ownName: "own.md", position: nil)
        #expect(join.title == String(localized: "Make a Binder"))
        #expect(join.detail.contains("own.md"))
        #expect(
            DropCopy.join(.newBinder, plan: plan, ownName: nil, position: nil).title
                == String(localized: "Make a Binder and Add"))
        #expect(
            DropCopy.open(plan: plan, isOpenElsewhere: true, isComparing: false).title
                == String(localized: "Show Its Window"))
        #expect(
            DropCopy.open(plan: plan, isOpenElsewhere: false, isComparing: true).detail
                == String(localized: "Not added to the comparison"))
        #expect(DropCopy.refusal(.alreadyIn) == String(localized: "Already in this window"))
    }
}

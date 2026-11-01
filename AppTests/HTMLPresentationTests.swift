import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct HTMLPresentationTests {
    private struct Environment {
        let preferences: AppPreferences
        let library: UserLibrary
        let store: DocumentSettingsStore
        let directory: URL
        let suite: TestDefaultsSuite

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
    }

    private func environment() throws -> Environment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = TestDefaultsSuite()
        return Environment(
            preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory.appendingPathComponent("Library")),
            store: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")),
            directory: directory, suite: suite)
    }

    private func model(
        _ environment: Environment, format: DocumentFormat = .html, hasFile: Bool = true,
        contents: String = "<p>Presentation fixture</p>"
    ) throws -> DocumentViewModel {
        let data = Data(contents.utf8)
        var url: URL?
        if hasFile {
            let file = environment.directory.appendingPathComponent("page.html")
            try data.write(to: file)
            url = file
        }
        let pages = TestFixtures.pdf("html", pages: 2)
        return DocumentViewModel(
            data: data, fileURL: url, format: format, preferences: environment.preferences,
            library: environment.library,
            renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pages) ?? PDFDocument() }),
            settingsStore: environment.store)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test("紙面のHTMLはページ余白ゼロでもアプリの余白で内容を切り取らない", .timeLimit(.minutes(1)))
    func htmlMarginsAreNotKnownBlank() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        // Pagination is stubbed: this tests the model's conservative policy, not WebKit's CSS parsing.
        let model = try model(
            environment, hasFile: false,
            contents: "<style>@page { margin: 0 }</style><p>Edge content</p>")
        model.start()
        try await waitUntil { model.result != nil && !model.isRendering }
        #expect(!model.isWebPresentation)
        #expect(model.renderedSettings != nil)
        #expect(model.viewLogicalMargin == nil)
        let source = try #require(model.paperDocument)
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        let plan = ViewPageLayout(
            pageCount: source.pageCount, options: options,
            hasLogicalMargins: model.viewLogicalMargin != nil, showsNumbers: false)
        #expect(!plan.cropsMargins)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 42))
        for index in 0..<source.pageCount {
            #expect(copy.page(at: index)?.bounds(for: .cropBox) == source.page(at: index)?.bounds(for: .cropBox))
        }
    }

    @Test("HTML はウェブで開き、変えなければ何も保存しない", .timeLimit(.minutes(1)))
    func opensOnTheWeb() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let model = try model(environment)
        model.start()
        try await waitUntil { model.contentHash != nil && model.result != nil && !model.isRendering }
        #expect(model.htmlPresentation == .web)
        #expect(model.showsWeb)
        model.rememberedSettingsDidChange()
        model.stop()
        #expect(environment.store.keys().isEmpty)
    }

    @Test("紙面にすると内容のハッシュで覚え、次に開くと紙面で開き、既定に戻すとウェブになる", .timeLimit(.minutes(1)))
    func remembersPaper() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let first = try model(environment)
        first.start()
        try await waitUntil { first.contentHash != nil && first.result != nil && !first.isRendering }
        first.setHTMLPresentation(.paper)
        first.rememberedSettingsDidChange()
        try await waitUntil { first.hasSavedSettings }
        first.stop()
        let key = try #require(first.contentHash?.hex)
        #expect(environment.store.record(for: key)?.htmlPresentation == .paper)

        let reopened = try model(environment)
        reopened.start()
        try await waitUntil { reopened.contentHash != nil && reopened.result != nil && !reopened.isRendering }
        #expect(reopened.htmlPresentation == .paper)
        #expect(reopened.hasSavedSettings)
        #expect(reopened.toast == nil)
        #expect(!reopened.showsWeb)
        reopened.resetDocumentSettings()
        #expect(reopened.htmlPresentation == .web)
        reopened.stop()
    }

    @Test("ウェブの帯は切り替えと印刷に絞り窓の道具は常にその他に置く")
    func bandOnTheWeb() throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let model = try model(environment)
        #expect(
            BandLayout.Item.applicable(for: model, stage: .full) == [
                .formatBadge, .presentation, .print,
            ])
        #expect(SecondaryViewControl.applicable(for: model) == [.floatOnTop, .keepMenuVisible])
        model.setHTMLPresentation(.paper)
        let paper = BandLayout.Item.applicable(for: model, stage: .full)
        #expect(paper.contains(.presentation))
        #expect(paper.contains(.style))
        #expect(paper.contains(.layout))
        #expect(paper.contains(.transition))
        #expect(SecondaryViewControl.applicable(for: model).contains(.selectText))
    }

    @Test("HTML 以外と、ファイルのない HTML は紙面だけで見せる", arguments: [(DocumentFormat.markdown, true), (.html, false)])
    func paperOnly(format: DocumentFormat, hasFile: Bool) throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let model = try model(environment, format: format, hasFile: hasFile)
        #expect(!model.usesHTMLPresentation)
        #expect(!model.showsWeb)
        model.setHTMLPresentation(.web)
        #expect(!BandLayout.Item.applicable(for: model, stage: .full).contains(.presentation))
        #expect(model.rememberedSettings.htmlPresentation == nil)
    }
}

/// A live page whose copy arrives only when the test says so.
@MainActor
private final class DelayedSnapshots {
    private var waiting: [CheckedContinuation<WebPageController.Snapshot, Never>] = []
    private(set) var requestCount = 0

    func take() async -> WebPageController.Snapshot {
        requestCount += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    func resolve(_ snapshot: WebPageController.Snapshot) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: snapshot)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WebCaptureTests {
    @MainActor private struct Fixture {
        let model: DocumentViewModel
        let snapshots: DelayedSnapshots
        let window: NSWindow
        let directory: URL
        let suite: TestDefaultsSuite
        /// The HTML of every copy the renderer was asked to lay out.
        let laidOut: () -> [String]
        /// Every layout the renderer was asked for, in order.
        let requests: () -> [PaginationRequest]

        func close() {
            model.stop()
            window.close()
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
    }

    /// - Parameter html: Written before the document opens; rewriting the file later would reach the file watcher at
    ///   an unpredictable moment and reload the document in the middle of a test.
    private func fixture(html: String = "<p>File</p>") async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("page.html")
        let data = Data(html.utf8)
        try data.write(to: file)
        let suite = TestDefaultsSuite()
        let pages = TestFixtures.pdf("html", pages: 2)
        final class Log {
            var html: [String] = []
            var requests: [PaginationRequest] = []
        }
        let log = Log()
        let model = DocumentViewModel(
            data: data, fileURL: file, format: .html, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory.appendingPathComponent("Library")),
            renderer: DocumentRenderer(paginate: { request in
                log.requests.append(request)
                if case .snapshot(let html, _) = request.source { log.html.append(html) }
                return PDFDocument(data: pages) ?? PDFDocument()
            }))
        let snapshots = DelayedSnapshots()
        model.snapshotSource = { await snapshots.take() }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 848),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        model.window = window
        model.start()
        try await waitUntil { model.result != nil && !model.isRendering }
        return Fixture(
            model: model, snapshots: snapshots, window: window, directory: directory, suite: suite,
            laidOut: { log.html }, requests: { log.requests })
    }

    private func waitUntil(seconds: Int = 5, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 100) where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test("紙面にすると写しを待つ間は出力できず、写しから組み終えてから出力できる")
    func outputWaitsForTheCopy() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.setHTMLPresentation(.paper)
        #expect(model.isCapturingWeb)
        #expect(!model.canOutput)
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        fixture.snapshots.resolve(.captured(HTMLSnapshot(html: "<p>Now</p>")))
        try await waitUntil { !model.isCapturingWeb && model.result != nil && !model.isRendering }
        #expect(fixture.laidOut() == ["<p>Now</p>"])
        #expect(model.canOutput)
    }

    @Test("写しの途中でファイルが変わったら、届いた古い写しは使わない")
    func reloadDiscardsTheCopyInFlight() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.setHTMLPresentation(.paper)
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        model.reload()
        #expect(!model.isCapturingWeb)
        fixture.snapshots.resolve(.captured(HTMLSnapshot(html: "<p>Old</p>")))
        try await waitUntil { model.result != nil && !model.isRendering }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.laidOut().isEmpty)
    }

    @Test("写しの途中の出力は同じ写しを待ち、写しに失敗したら知らせて出力しない")
    func failedCopyStopsTheOutput() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        var outcomes: [DocumentViewModel.CaptureOutcome] = []
        model.captureWeb { outcomes.append($0) }
        model.exportPDF()
        model.captureWeb { outcomes.append($0) }
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        #expect(model.isCapturingWeb)
        fixture.snapshots.resolve(.failed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.snapshots.requestCount == 1)
        try await waitUntil { outcomes.count == 2 }
        #expect(outcomes == [.failed, .failed])
        #expect(!model.isExporting)
        #expect(model.toast?.systemImage == "exclamationmark.triangle")
        #expect(fixture.laidOut().isEmpty)
    }

    @Test("写しに失敗したら紙面のまま出力を止め、出力を頼むと写し直し、写し直せたら出力できる")
    func failedCopyBlocksOutputUntilRecaptured() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.setHTMLPresentation(.paper)
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        fixture.snapshots.resolve(.failed)
        try await waitUntil { !model.isCapturingWeb }
        #expect(model.htmlPresentation == .paper)
        #expect(model.webCaptureFailed)
        #expect(!model.canOutput)
        #expect(model.toast?.action == .retryWebCapture)

        model.exportPDF()
        try await waitUntil { fixture.snapshots.requestCount == 2 }
        fixture.snapshots.resolve(.failed)
        try await waitUntil { !model.isCapturingWeb }
        #expect(!model.isExporting)
        #expect(!model.canOutput)

        model.retryWebCapture()
        try await waitUntil { fixture.snapshots.requestCount == 3 }
        fixture.snapshots.resolve(.captured(HTMLSnapshot(html: "<p>Retry</p>")))
        try await waitUntil { !model.isCapturingWeb && model.result != nil && !model.isRendering }
        #expect(!model.webCaptureFailed)
        #expect(model.canOutput)
        #expect(fixture.laidOut() == ["<p>Retry</p>"])
    }

    @Test("紙面を見ている間に JavaScript を止めると、残しておいたページも止めて、次は止めた設定で開く")
    func javaScriptSettingReachesTheKeptPage() async throws {
        let fixture = try await fixture(html: "<!doctype html><body><script>window.ran = true</script></body>")
        defer { fixture.close() }
        let model = fixture.model
        let file = try #require(model.fileURL)
        // As in the app, the page first loads on screen (Web), then leaves the window while paper shows.
        model.web.container.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        fixture.window.contentView = model.web.container
        fixture.window.orderFrontRegardless()
        model.web.show(file, allowsJavaScript: true)
        // A web content process may start slowly on a busy machine.
        try await waitUntil(seconds: 20) { model.web.webView?.url != nil && model.web.webView?.isLoading == false }
        let ranBefore = try await model.web.webView?.evaluateJavaScript("typeof window.ran") as? String
        #expect(ranBefore == "boolean")
        model.setHTMLPresentation(.paper)
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        fixture.snapshots.resolve(.notLoaded)
        try await waitUntil { !model.isCapturingWeb }
        fixture.window.contentView = nil

        model.preferences.allowsJavaScript = false
        model.javaScriptSettingDidChange()
        #expect(model.web.webView == nil)

        fixture.window.contentView = model.web.container
        model.web.show(file, allowsJavaScript: model.preferences.allowsJavaScript)
        try await waitUntil(seconds: 20) { model.web.webView?.url != nil && model.web.webView?.isLoading == false }
        let ran = try await model.web.webView?.evaluateJavaScript("typeof window.ran") as? String
        #expect(ran == "undefined")
    }

    private func isFile(_ request: PaginationRequest?) -> Bool {
        if case .file? = request?.source { return true }
        return false
    }

    @Test("ウェブから刷り台に入ると今の状態を刷り、最初の状態に切り替えるとファイルから組み、戻ると今の状態に戻る")
    func originalOrCurrentState() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        #expect(!model.offersOriginalPage)
        model.enterPrintMode()
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        fixture.snapshots.resolve(.captured(HTMLSnapshot(html: "<p>Now</p>")))
        try await waitUntil { model.mode == .print && model.canOutput }
        #expect(model.offersOriginalPage)
        #expect(model.rendersSnapshot)
        #expect(fixture.laidOut() == ["<p>Now</p>"])

        model.setPrintsOriginalPage(true)
        #expect(!model.canOutput)
        try await waitUntil { model.canOutput }
        #expect(!model.rendersSnapshot)
        #expect(isFile(fixture.requests().last))

        model.exitPrintMode()
        #expect(!model.printsOriginalPage)
        try await waitUntil { model.mode == .view && model.isUpToDate }
        #expect(model.rendersSnapshot)
        #expect(fixture.laidOut() == ["<p>Now</p>", "<p>Now</p>"])
    }

    @Test("写しに閉じた折りたたみがあると数を知らせ、開いて刷ると写しの組版だけで開き、刷り台を出ると閉じたままに戻る")
    func openClosedDetails() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.setHTMLPresentation(.paper)
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        fixture.snapshots.resolve(
            .captured(HTMLSnapshot(html: "<details><summary>Q</summary>A</details>", closedDetailsCount: 3)))
        try await waitUntil { !model.isCapturingWeb && model.canOutput }
        #expect(model.closedDetailsCount == 3)
        model.enterPrintMode()
        try await waitUntil { model.mode == .print }
        let before = fixture.requests().count

        model.setOpensClosedDetails(true)
        #expect(model.renderSettings?.opensDetails == true)
        #expect(!model.isUpToDate)
        model.render()
        try await waitUntil { model.canOutput }
        let request = try #require(fixture.requests().last)
        #expect(fixture.requests().count == before + 1)
        #expect(request.preparationScript?.hasPrefix(HTMLSnapshotScript.openDetailsJavaScript) == true)
        if case .snapshot = request.source {} else { Issue.record("開くのは写しの組版") }

        // The original page has its own details; the count is that of the copy.
        model.setPrintsOriginalPage(true)
        #expect(model.closedDetailsCount == 0)
        #expect(model.renderSettings?.opensDetails == false)
        model.setPrintsOriginalPage(false)

        model.exitPrintMode()
        #expect(!model.opensClosedDetails)
        #expect(model.renderSettings?.opensDetails == false)
    }

    @Test("ウェブで文書が印刷を頼むと刷り台を開き、紙面のときは何もしない")
    func pagePrintRequest() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.windowActiveOverride = true
        model.setHTMLPresentation(.paper)
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        fixture.snapshots.resolve(.notLoaded)
        try await waitUntil { !model.isCapturingWeb }
        model.pageDidRequestPrint()
        #expect(model.mode == .view)
        #expect(fixture.snapshots.requestCount == 1)

        model.setHTMLPresentation(.web)
        model.pageDidRequestPrint()
        try await waitUntil { fixture.snapshots.requestCount == 2 }
        fixture.snapshots.resolve(.notLoaded)
        try await waitUntil { model.mode == .print }
        #expect(model.mode == .print)
    }

    @Test("後ろの窓の文書が印刷を頼んでも刷り台を開かない")
    func backgroundWindowCannotPrint() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.windowActiveOverride = false
        model.pageDidRequestPrint()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.mode == .view)
        #expect(!model.isCapturingWeb)
        #expect(fixture.snapshots.requestCount == 0)
    }

    @Test("写しの途中と刷り台での印刷の依頼は重ねず、刷り台は 1 回だけ開く")
    func repeatedRequestsDuringCapture() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.windowActiveOverride = true
        for _ in 0..<5 { model.pageDidRequestPrint() }
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        var outcomes: [DocumentViewModel.CaptureOutcome] = []
        model.captureWeb { outcomes.append($0) }
        fixture.snapshots.resolve(.notLoaded)
        try await waitUntil { model.mode == .print }
        // Only the tray's own wait and this one were queued for the copy.
        #expect(outcomes == [.ready])
        for _ in 0..<5 { model.pageDidRequestPrint() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.snapshots.requestCount == 1)
        #expect(model.mode == .print)
    }

    @Test("刷り台を閉じている途中に文書が印刷を頼んでも、刷り台へ戻さない")
    func requestRightAfterReturning() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.windowActiveOverride = true
        model.enterPrintMode()
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        fixture.snapshots.resolve(.notLoaded)
        try await waitUntil { model.mode == .print }
        model.exitPrintMode()
        // While the tray is closing, the page cannot send the reader back.
        model.pageDidRequestPrint()
        #expect(fixture.snapshots.requestCount == 1)
        try await waitUntil { model.mode == .view }
        #expect(model.mode == .view)
    }

    @Test("⌃⌘P はウェブと紙面を入れ替え、刷り台では何もしない")
    func toggleShortcut() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.toggleHTMLPresentation()
        #expect(model.htmlPresentation == .paper)
        try await waitUntil { fixture.snapshots.requestCount == 1 }
        fixture.snapshots.resolve(.notLoaded)
        try await waitUntil { !model.isCapturingWeb }
        model.toggleHTMLPresentation()
        #expect(model.htmlPresentation == .web)
        model.toggleHTMLPresentation()
        try await waitUntil { fixture.snapshots.requestCount == 2 }
        fixture.snapshots.resolve(.notLoaded)
        try await waitUntil { !model.isCapturingWeb }
        model.enterPrintMode()
        try await waitUntil { model.mode == .print }
        model.toggleHTMLPresentation()
        #expect(model.htmlPresentation == .paper)
    }
}

@MainActor
struct HTMLPresentationMenuTests {
    @Test("表示メニューに ⌃⌘P のウェブ / 紙面の切り替えが 1 つある")
    func menuItem() throws {
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
        let toggles = items.filter { $0.keyEquivalent == "p" && $0.keyEquivalentModifierMask == [.control, .command] }
        #expect(toggles.count == 1)
        let item = try #require(toggles.first)
        #expect(item.isEnabled)
    }
}

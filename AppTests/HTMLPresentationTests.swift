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
        _ environment: Environment, format: DocumentFormat = .html, hasFile: Bool = true
    ) throws -> DocumentViewModel {
        let data = Data("<p>Presentation fixture</p>".utf8)
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
        #expect(!reopened.showsWeb)
        reopened.resetDocumentSettings()
        #expect(reopened.htmlPresentation == .web)
        reopened.stop()
    }

    @Test("ウェブの帯には「ウェブ / 紙面」と窓の道具だけを出し、紙面では紙の道具も出す")
    func bandOnTheWeb() throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let model = try model(environment)
        #expect(
            BandLayout.Item.applicable(for: model, stage: .full) == [
                .formatBadge, .presentation, .floatOnTop, .keepMenuVisible, .print,
            ])
        model.setHTMLPresentation(.paper)
        let paper = BandLayout.Item.applicable(for: model, stage: .full)
        #expect(paper.contains(.presentation))
        #expect(paper.contains(.style))
        #expect(paper.contains(.layout))
        #expect(paper.contains(.selectText))
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
        final class Log { var html: [String] = [] }
        let log = Log()
        let model = DocumentViewModel(
            data: data, fileURL: file, format: .html, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory.appendingPathComponent("Library")),
            renderer: DocumentRenderer(paginate: { request in
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
            laidOut: { log.html })
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
        fixture.snapshots.resolve(.captured("<p>Now</p>"))
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
        fixture.snapshots.resolve(.captured("<p>Old</p>"))
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
        fixture.snapshots.resolve(.captured("<p>Retry</p>"))
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
}

import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing
import UniformTypeIdentifiers
import os

@testable import Surimono

private final class ViewerFileFixture {}

@MainActor
@Suite(.serialized)
struct ViewerFileDocumentTests {
    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: ViewerFileFixture.self)
        let url = try #require(bundle.url(forResource: "ViewerFileDocument", withExtension: "png"))
        // Documents inside the host app are excluded from both system and app recent-file history.
        try #require(GettingStarted.isInsideApp(url))
        try #require(NSDocumentController.shared.document(for: url) == nil)
        return url
    }

    private func open(_ url: URL) async throws -> (NSDocument, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, wasOpen, error in
                if let document {
                    continuation.resume(returning: (document, wasOpen))
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    @Test("同じファイルをもう一度開くと、既存の文書の窓が別の窓より手前に戻る", .timeLimit(.minutes(1)))
    func openingAgainBringsExistingWindowForward() async throws {
        let url = try fixtureURL()
        defer { NSDocumentController.shared.document(for: url)?.close() }
        let (document, wasOpen) = try await open(url)
        try #require(!wasOpen)
        let window = try #require(document.windowControllers.first?.window)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 180), styleMask: [.titled],
            backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.level = window.level
        other.order(.above, relativeTo: window.windowNumber)
        func frontOfPair() -> NSWindow? { NSApp.orderedWindows.first { $0 === window || $0 === other } }
        try #require(frontOfPair() === other)

        let (reopened, alreadyOpen) = try await open(url)
        #expect(alreadyOpen)
        #expect(reopened === document)
        #expect(reopened.windowControllers.count == 1)
        #expect(reopened.windowControllers.first?.window === window)
        #expect(frontOfPair() === window)
    }

    enum WindowKind: CaseIterable {
        case document
        case imageBundle
    }

    @Test("窓を閉じると紙面を保持していても表示を終了し、モデル・描画器・PDFを解放する", .timeLimit(.minutes(1)), arguments: WindowKind.allCases)
    func closingWindowReleasesContent(kind: WindowKind) async throws {
        try await checkClosedContent(in: kind, holdingPaper: true)
    }

    @Test("窓を閉じると、タイル描画用のPDFが解放される前に紙面が文書を手放す", .timeLimit(.minutes(1)), arguments: WindowKind.allCases)
    func closingWindowDetachesPaperContentBeforePDFRelease(kind: WindowKind) async throws {
        try await checkClosedContent(in: kind, holdingPaper: false)
    }

    @Test("共有用PDFの生成中に文書の窓を閉じると、遅れて戻る生成処理を待たずにモデルを解放する", .timeLimit(.minutes(1)))
    func closeDuringReadingShare() async throws {
        let url = try fixtureURL()
        defer { NSDocumentController.shared.document(for: url)?.close() }
        weak var released: DocumentViewModel?
        let share: ReadingPDFShare
        var resume: CheckedContinuation<Void, Never>?
        defer { resume?.resume() }
        var producerWasCancelled: Bool?
        var results: [Result<URL, Error>] = []
        do {
            let (document, _) = try await open(url)
            let window = try #require(document.windowControllers.first?.window)
            let model = try #require(DocumentWindows.shared.model(for: window))
            try await ShortcutMenuBaselineTests.waitForMenu { model.canExportReadingPDF }
            share = try #require(
                model.makeReadingShare { produce in
                    await withCheckedContinuation { resume = $0 }
                    producerWasCancelled = Task.isCancelled
                    return try await produce()
                })
            model.readingShare = share
            released = model
            share.load(Progress(totalUnitCount: 1)) { results.append($0) }
            try await ShortcutMenuBaselineTests.waitForMenu { resume != nil }
            window.performClose(nil)
        }
        try await ShortcutMenuBaselineTests.waitForMenu { released == nil }
        try #require(results.count == 1)
        #expect(throws: CancellationError.self) { try results[0].get() }
        resume?.resume()
        resume = nil
        try await ShortcutMenuBaselineTests.waitForMenu { producerWasCancelled != nil }
        #expect(producerWasCancelled == true)
        #expect(results.count == 1)
        var late: Result<URL, Error>?
        share.load(Progress(totalUnitCount: 1)) { late = $0 }
        let response = try #require(late)
        #expect(throws: CancellationError.self) { try response.get() }
    }

    private func checkClosedContent(in kind: WindowKind, holdingPaper: Bool) async throws {
        let url = try fixtureURL()
        let content: ClosedContent
        switch kind {
        case .document:
            defer { NSDocumentController.shared.document(for: url)?.close() }
            content = try await closeFile(at: url, holdingPaper: holdingPaper)
            #expect(NSDocumentController.shared.document(for: url) == nil)
            try await content.checkReleaseOrder(holdingPaper: holdingPaper)
        case .imageBundle:
            let suite = TestDefaultsSuite()
            defer { suite.remove() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let bundles = ImageBundleWindows()
            bundles.preferences = AppPreferences(defaults: suite.defaults)
            bundles.library = UserLibrary(root: directory)
            content = try await closeBundle(at: url, in: bundles, holdingPaper: holdingPaper)
            #expect(!bundles.hasWindows)
            try await content.checkReleaseOrder(holdingPaper: holdingPaper)
            withExtendedLifetime(bundles) {}
        }
    }

    private func closeBundle(at url: URL, in bundles: ImageBundleWindows, holdingPaper: Bool) async throws
        -> ClosedContent
    {
        let model = bundles.open([url])
        let window = try #require(model.window)
        defer { if !model.isWindowClosed { window.close() } }
        let content = try await ClosedContent(window: window, model: model, holdingPaper: holdingPaper)
        try await content.drawAndSwitchLayout(of: model)
        autoreleasepool { window.performClose(nil) }
        #expect(model.result == nil)
        return content
    }

    // Return from the async setup before testing weak references. Only ClosedContent's deliberate owners
    // should survive the document-open completion, the registry lookup and performClose.
    private func closeFile(at url: URL, holdingPaper: Bool) async throws -> ClosedContent {
        let (document, _) = try await open(url)
        let window = try #require(document.windowControllers.first?.window)
        // NSMapTable returns the model through Objective-C. Drain the lookup's temporary
        // ownership separately from the Swift reference that ends before the release checks.
        let model = try autoreleasepool { try #require(DocumentWindows.shared.model(for: window)) }
        let content = try await ClosedContent(window: window, model: model, holdingPaper: holdingPaper)
        content.fileDocument = document
        // Exercise a second display generation without saving layout settings for the bundled fixture.
        try autoreleasepool {
            let paper = try #require(content.paper)
            var options = model.viewOptions
            let spread = paper.displayMode == .twoUp || paper.displayMode == .twoUpContinuous
            options.layout = spread ? .single : .spread
            options.showsCoverAlone = false
            paper.apply(options)
            let displayed: PDFDocument = try #require(paper.document)
            try #require(displayed !== content.pdf)
            content.lastDisplay = displayed
        }
        autoreleasepool { window.performClose(nil) }
        return content
    }

    @Test("画像の読み込みが戻る前に束を閉じても、表示モデルと描画器を解放する", .timeLimit(.minutes(1)))
    func closingWhileHashingImageReleasesRenderer() async throws {
        try await closeWhileHashing(keepModel: false)
    }

    @Test("閉じた束のモデルを保持したまま画像の読み込みを再開しても、結果を公開せず描画も印刷も再開しない", .timeLimit(.minutes(1)))
    func closingWhileHashingDiscardsLateResult() async throws {
        try await closeWhileHashing(keepModel: true)
    }

    private func closeWhileHashing(keepModel: Bool) async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = TestFixtures.png(red: 0.5)
        let reading = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchGroup()
        gate.enter()
        var render: Task<Void, Never>?
        var resumed = false
        // The Xcode 26.6 compiler rejects `await` in a defer body, so a failure is settled in the catch below:
        // the render must finish before the defaults suite and the directory above are removed.
        do {
            let bundle = ImageBundleModel(urls: [directory.appendingPathComponent("image.png")]) { _ in
                reading.withLock { $0 = true }
                gate.wait()
                return bytes
            }
            weak var releasedModel: DocumentViewModel?
            weak var releasedRenderer: DocumentRenderer?
            var retainedModel: DocumentViewModel?
            let starts: Int
            var prints = 0
            do {
                let model = DocumentViewModel(
                    data: Data(), fileURL: nil, format: .image, preferences: AppPreferences(defaults: suite.defaults),
                    library: UserLibrary(root: directory), imageBundle: bundle)
                releasedModel = model
                releasedRenderer = model.renderer
                if keepModel { retainedModel = model }
                model.printerListSource = { PrinterList(names: ["Test"], defaultName: "Test") }
                model.printSubmit = { _, _, _ in prints += 1 }
                defer { model.closeWindow() }
                model.start()
                if keepModel { model.printDocument(quick: true) }
                let activeRender: Task<Void, Never> = try #require(model.renderTask)
                render = activeRender
                if keepModel { try #require(model.hasWaitingOutput) }
                try await ShortcutMenuBaselineTests.waitForMenu { reading.withLock { $0 } }
                starts = model.renderStartCount
            }
            if retainedModel == nil {
                try await ShortcutMenuBaselineTests.waitForMenu { releasedModel == nil && releasedRenderer == nil }
            }
            #expect(render?.isCancelled == true)
            gate.leave()
            resumed = true
            await render?.value
            if let model = retainedModel {
                #expect(bundle.setHash == nil && model.contentHash == nil)
                #expect(model.renderer.logicalRenderCount == 0)
                #expect(model.result == nil && model.printResult == nil && model.error == nil)
                #expect(model.renderTask == nil && model.renderStartCount == starts)
                #expect(!model.isRendering && !model.isPrinting && !model.hasWaitingOutput)
            }
            #expect(prints == 0)
        } catch {
            if !resumed {
                gate.leave()
                resumed = true
            }
            await render?.value
            throw error
        }
    }

    // AppKit gets a default-mode turn with a local pool, then SwiftUI and other main-actor tasks can resume.
    private static func drainCloseTurn() async {
        autoreleasepool {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        await Task.yield()
    }

    /// Hold the objects AppKit can cache. Keep a native picker selection alive as well, as in the closing-window trace.
    @MainActor
    private final class ClosedContent {
        private let window: NSWindow
        private var host: NSViewController?
        private var hostingView: NSView?
        private let dropCatcher: DropCatcherView
        private let layoutSelection: Binding<ViewOptions.Layout>
        let tileClock: ManualPaperTileClock
        private let publishedPage: PageTextElement
        let retainedPaper: PaperPDFView?
        weak var fileDocument: NSDocument?
        weak var model: DocumentViewModel?
        weak var renderer: DocumentRenderer?
        weak var trialRenderer: DocumentRenderer?
        weak var paper: PaperPDFView?
        weak var pdf: PDFDocument?
        weak var logicalPDF: PDFDocument?
        weak var lastDisplay: PDFDocument?

        init(window: NSWindow, model: DocumentViewModel, holdingPaper: Bool) async throws {
            self.window = window
            layoutSelection = model.viewOption(\.layout)
            let controller = try #require(window.contentViewController)
            host = controller
            let root = controller.view
            hostingView = root
            try await ShortcutMenuBaselineTests.waitForMenu { model.paper.view?.document != nil }
            func dropTarget(in view: NSView) -> DropCatcherView? {
                if let target = view as? DropCatcherView { return target }
                return view.subviews.lazy.compactMap { dropTarget(in: $0) }.first
            }
            let target = try #require(dropTarget(in: root))
            try #require(target.model === model)
            dropCatcher = target
            self.model = model
            renderer = model.renderer
            trialRenderer = model.themeTrial.renderer
            let view = try #require(model.paper.view)
            try await ShortcutMenuBaselineTests.waitForMenu { !view.visiblePages.isEmpty }
            let page = try #require(view.accessibilityChildren()?.first as? PageTextElement)
            try #require(page.accessibilityParent() as? NSView === view)
            publishedPage = page
            let displayed: PDFDocument = try #require(view.document)
            let logical = try #require(model.result?.logicalDocument)
            tileClock = ManualPaperTileClock()
            view.tileClock = tileClock
            retainedPaper = holdingPaper ? view : nil
            paper = view
            lastDisplay = displayed
            pdf = displayed
            logicalPDF = logical
        }

        func drawAndSwitchLayout(of model: DocumentViewModel) async throws {
            // The bitmap and the drawing call's temporary AppKit objects are not owners in the closed window.
            try autoreleasepool {
                let view = try #require(paper)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            let spread = model.viewOptions.layout == .single
            model.updateViewOptions {
                $0.layout = spread ? .spread : .single
                $0.showsCoverAlone = false
            }
            try await ShortcutMenuBaselineTests.waitForMenu {
                guard let paper, let displayed = paper.document else { return false }
                let twoUp = paper.displayMode == .twoUp || paper.displayMode == .twoUpContinuous
                return twoUp == spread && displayed !== pdf
            }
            let displayed: PDFDocument = try #require(paper?.document)
            lastDisplay = displayed
        }

        private func waitForRelease(
            _ phase: String, until deadline: ContinuousClock.Instant = .now + .seconds(6), _ stillAlive: () -> [String?]
        ) async throws {
            var remaining = autoreleasepool { stillAlive().compactMap { $0 } }
            while !remaining.isEmpty, ContinuousClock.now < deadline {
                await ViewerFileDocumentTests.drainCloseTurn()
                remaining = autoreleasepool { stillAlive().compactMap { $0 } }
            }
            try #require(remaining.isEmpty, "\(phase): \(remaining)")
        }

        // On macOS 26 we observed AppKit's tracking-area hit test autorelease the paper into XCTest's
        // outer pool when the window opened under the pointer. Here we check retirement and content
        // release. dismantledPaperDeallocatesInHiddenWindow checks that the view itself deallocates.
        private var remainingPaperContent: String? {
            guard let paper else { return nil }
            if !paper.isRetired { return "active paper" }
            if paper.window != nil { return "paper.window" }
            if paper.superview != nil { return "paper.superview" }
            if paper.document != nil { return "paper.document" }
            #if DEBUG
                if paper.shownDocumentCount != 0 { return "paper.shownDocuments" }
            #endif
            return nil
        }

        func checkReleaseOrder(holdingPaper: Bool) async throws {
            try autoreleasepool {
                if holdingPaper {
                    let paper = try #require(retainedPaper)
                    #expect(paper.isRetired)
                    #expect(paper.document == nil)
                    #expect(publishedPage.accessibilityParent() == nil)
                    #expect(publishedPage.accessibilityFrame() == .zero)
                }
                #expect(DocumentWindows.shared.model(for: window) == nil)
            }

            let closeDeadline = ContinuousClock.now + .seconds(6)
            try await waitForRelease("ホスト切り離し", until: closeDeadline) {
                [
                    window.contentViewController === host ? "attached host" : nil,
                    window.contentView === hostingView || hostingView?.window != nil ? "attached hostingView" : nil,
                    dropCatcher.model != nil ? "dropCatcher.model" : nil,
                    remainingPaperContent, fileDocument == nil ? nil : "document",
                ]
            }

            if #available(macOS 26, *) {
                try #require(hostingView != nil)
            } else {
                // On macOS 15, NSHostingView keeps the old root's state after root replacement.
                // Closing the window releases the view itself once the fixture lets go of it and its controller.
                weak let releasedView = hostingView
                autoreleasepool {
                    host = nil
                    hostingView = nil
                }
                try await waitForRelease("ホスティングビューの解放", until: closeDeadline) {
                    [releasedView == nil ? nil : "hostingView"]
                }
            }
            try await waitForRelease("タイルの猶予中", until: closeDeadline) {
                [
                    model == nil ? nil : "model", renderer == nil ? nil : "renderer",
                    trialRenderer == nil ? nil : "trialRenderer",
                ]
            }
            autoreleasepool {
                tileClock.advance(by: .milliseconds(999))
                #expect(pdf != nil)
                #expect(lastDisplay != nil)
                tileClock.advance(by: .milliseconds(1))
            }
            try await waitForRelease("タイルの猶予終了後") {
                [
                    pdf == nil ? nil : "pdf", lastDisplay == nil ? nil : "lastDisplay",
                    logicalPDF == nil ? nil : "logicalPDF",
                ]
            }
            withExtendedLifetime((retainedPaper, host, hostingView, window)) {}
        }
    }

    @Test("文書はメインスレッドで作る（別スレッドで作らせると初期化で落ちる）")
    func createsDocumentsOnTheMainThread() {
        for type in ViewerFileDocument.readableTypes {
            #expect(!ViewerFileDocument.canConcurrentlyReadDocuments(ofType: type))
        }
    }

    @Test("保存、自動保存、移動を直接頼んでも、元ファイルの内容・更新日時・隣のファイルは変わらない")
    func neverWritesSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("original.txt")
        let bytes = Data("read only".utf8)
        try bytes.write(to: file)
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let type = UTType.plainText.identifier
        let document = try ViewerFileDocument(contentsOf: file, ofType: type)
        defer { document.close() }
        document.updateChangeCount(.changeDone)
        #expect(!document.isDocumentEdited)
        #expect(!document.hasUnautosavedChanges)
        #expect(!ViewerFileDocument.autosavesInPlace)
        #expect(!ViewerFileDocument.autosavesDrafts)
        #expect(document.autosavingFileType == nil)
        #expect(throws: CocoaError.self) { try document.write(to: file, ofType: type) }
        let operations: [NSDocument.SaveOperationType] = [
            .saveOperation, .saveAsOperation, .saveToOperation, .autosaveInPlaceOperation, .autosaveElsewhereOperation,
            .autosaveAsOperation,
        ]
        for operation in operations {
            #expect(throws: CocoaError.self) { try document.writeSafely(to: file, ofType: type, for: operation) }
        }
        let elsewhere = directory.appendingPathComponent("copy.txt")
        await #expect(throws: (any Error).self) {
            try await document.save(to: elsewhere, ofType: type, for: .saveAsOperation)
        }
        await #expect(throws: CocoaError.self) { try await document.move(to: elsewhere) }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["original.txt"])
    }

    @Test("ウインドウ復元は組版前のページを保持し、文書が短くなっていれば末尾を開く", .timeLimit(.minutes(1)))
    func restoresPageAfterPagination() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DocumentViewModel(
            data: TestFixtures.pdf("Restore", pages: 3), fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            settingsStore: nil)
        model.restoreReadingPage(9)
        #expect(model.pageForWindowRestoration == 9)
        model.start()
        defer { model.stop() }
        for _ in 0..<500 where !model.isUpToDate || model.contentHash == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.pageCount == 3)
        #expect(model.logicalReadingPage == 2)
        #expect(model.pageForWindowRestoration == 2)
        model.updateViewOptions {
            $0.layout = .spread
            $0.showsCoverAlone = false
        }
        model.restoreReadingPage(1)
        #expect(model.currentPageIndex == 0)
        #expect(model.logicalReadingPage == 1)
        #expect(model.pageForWindowRestoration == 1)
        #expect(!model.pageHistory.canGoBack)
    }

    @Test("AppKit が復元する文書に窓を一つだけ用意し、保存した識別子をその窓に引き継ぐ")
    func restoresOneWindowWithoutDisplayingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("restore.pdf")
        try TestFixtures.pdf("Restore").write(to: file)
        let document = try ViewerFileDocument(for: file, withContentsOf: file, ofType: UTType.pdf.identifier)
        defer { document.close() }
        let oldID = NSUserInterfaceItemIdentifier("surimono.file.v1.1234")
        let data = try NSKeyedArchiver.archivedData(withRootObject: [], requiringSecureCoding: true)
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        defer { coder.finishDecoding() }
        #expect(document.windowControllers.isEmpty)
        let window = try await document.restoreWindow(withIdentifier: oldID, state: coder)
        #expect(!window.isVisible)
        #expect(window.identifier == oldID)
        #expect(window.representedURL == file)
        #expect(window.restorationClass === ViewerDocumentController.self)
        let reused = try await document.restoreWindow(withIdentifier: oldID, state: coder)
        #expect(reused === window)
        #expect(document.windowControllers.count == 1)
    }

    @Test("旧シーンと設定の識別子を起動時に復元しない", arguments: ["SwiftUI.DocumentGroup", "surimono.settings.v1"])
    func ignoresLegacyWindows(identifier: String) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        let handled = NSApp.restoreWindow(withIdentifier: .init(identifier), state: coder) { _, _ in
            Issue.record("未知の識別子の復元を引き受けた")
        }
        #expect(!handled)
    }

    @Test("システムの履歴が残っている場合も、選んだファイルは保存済みブックマークから再度開く")
    func bookmarkOnSelection() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("before.md")
        let moved = directory.appendingPathComponent("after.md")
        try Data("test".utf8).write(to: original)
        let history = RecentFileHistory(preferences: AppPreferences(defaults: suite.defaults))
        history.systemLimit = { 10 }
        history.record(original)
        try FileManager.default.moveItem(at: original, to: moved)
        let reloaded = RecentFileHistory(preferences: AppPreferences(defaults: suite.defaults))
        reloaded.systemURLs = { [original] }
        let selected = try #require(reloaded.visibleURLs.first)
        #expect(reloaded.urlForOpening(selected).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
    }

    // MARK: - The window's size before and without pages

    /// Holds an async step open until the test lets it go, so that real time never decides order.
    @MainActor private final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private(set) var enterCount = 0
        private(set) var exitCount = 0
        var isWaiting: Bool { !waiting.isEmpty }

        func wait() async {
            enterCount += 1
            if !isOpen {
                await withCheckedContinuation { waiting.append($0) }
            }
            exitCount += 1
        }

        func open() {
            isOpen = true
            let held = waiting
            waiting = []
            for continuation in held { continuation.resume() }
        }
    }

    /// A file's window as the document controller makes it, without adding the file to the recent documents.
    /// `configure` runs before the size observer is attached and before the window is ordered front, so tests can
    /// install gates or initial window state before `start()` runs.
    private func fileWindow(
        at url: URL, type: UTType, configure: (NSWindow, DocumentViewModel) -> Void = { _, _ in }
    ) throws -> (ViewerFileDocument, NSWindow, DocumentViewModel, ContentSizes) {
        let document = ViewerFileDocument()
        try document.read(from: url, ofType: type.identifier)
        document.fileURL = url
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        let model = try #require(DocumentWindows.shared.model(for: window))
        configure(window, model)
        let sizes = ContentSizes(of: window)
        // Shown, so that the content appears and starts the model, but not seen.
        window.alphaValue = 0
        window.orderFrontRegardless()
        return (document, window, model, sizes)
    }

    private func waitUntil(
        _ detail: @autoclosure () -> String, timeout: Duration = .seconds(15),
        sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "\(detail())", sourceLocation: sourceLocation)
    }

    /// The content sizes the window passes through, from now on.
    @MainActor private final class ContentSizes {
        private(set) var sizes: [CGSize] = []
        private var observer: (any NSObjectProtocol)?

        init(of window: NSWindow) {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    self?.sizes.append(window.contentRect(forFrameRect: window.frame).size)
                }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    private static let plainSize = CGSize(width: 760, height: 760)

    private func expectPapersShape(_ window: NSWindow, _ model: DocumentViewModel, _ detail: String) throws {
        let unit = try #require(model.paperUnitSize, "\(detail)")
        let content = window.contentRect(forFrameRect: window.frame).size
        let paper = CGSize(width: content.width - model.sideInset, height: content.height - model.bandInset)
        #expect(abs(paper.width / paper.height - unit.width / unit.height) < 0.02, "\(detail)")
        #expect(content != Self.plainSize, "\(detail)")
    }

    @Test("読めない PDF のファイルの窓は 1×1 に縮まず、エラーのあと 760×760 で開く", .timeLimit(.minutes(1)))
    func unreadableFileKeepsItsWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.7 broken".utf8).write(to: url)
        // Kept closed so that only the error can give the window its size.
        let waitGate = Gate()
        defer { waitGate.open() }
        let (document, window, model, sizes) = try fileWindow(at: url, type: .pdf) { _, model in
            model.awaitRoomWithoutPages = { await waitGate.wait() }
        }
        defer {
            sizes.stop()
            document.close()
        }
        func state() -> String {
            "content=\(window.contentRect(forFrameRect: window.frame).size) sizes=\(sizes.sizes) "
                + "error=\(model.error ?? "nil") rendering=\(model.isRendering) result=\(model.result != nil) "
                + "wait=(\(waitGate.enterCount),\(waitGate.exitCount))"
        }
        try await waitUntil(state()) { model.error != nil && !model.isRendering }
        #expect(model.result == nil, "\(state())")
        #expect(window.contentRect(forFrameRect: window.frame).size == Self.plainSize, "\(state())")
        #expect(!model.hasSizedWindow, "\(state())")
        #expect(waitGate.exitCount == 0, "\(state())")
    }

    @Test("組版が待ち時間より早く終わるファイルの窓は、760×760 を経ずに紙の形になる", .timeLimit(.minutes(1)))
    func readableFileTakesThePapersShape() async throws {
        let url = try fixtureURL()
        let waitGate = Gate()
        defer { waitGate.open() }
        let (document, window, model, sizes) = try fileWindow(at: url, type: .png) { _, model in
            model.awaitRoomWithoutPages = { await waitGate.wait() }
        }
        defer {
            sizes.stop()
            document.close()
        }
        func state() -> String {
            "content=\(window.contentRect(forFrameRect: window.frame).size) sizes=\(sizes.sizes) "
                + "unit=\(String(describing: model.paperUnitSize)) band=\(model.bandInset) side=\(model.sideInset) "
                + "sized=\(model.hasSizedWindow) error=\(model.error ?? "nil") "
                + "wait=(\(waitGate.enterCount),\(waitGate.exitCount))"
        }
        try await waitUntil(state()) {
            model.result != nil && !model.isRendering && model.hasSizedWindow && waitGate.isWaiting
        }
        // Let the wait finish after the pages have sized the window, so a late fallback would be caught too.
        waitGate.open()
        try await waitUntil(state()) { waitGate.exitCount == 1 }
        await Task.yield()
        #expect(!sizes.sizes.contains(Self.plainSize), "\(state())")
        try expectPapersShape(window, model, state())
    }

    @Test("組版が待ち時間を過ぎるファイルの窓は、760×760 で見せたあと紙の形になる", .timeLimit(.minutes(1)))
    func slowFileShowsItsWindowThenThePaper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("slow.md")
        try Data("# Heading\n\nA paragraph.\n".utf8).write(to: url)
        let waitGate = Gate()
        defer { waitGate.open() }
        let renderGate = Gate()
        defer { renderGate.open() }
        let (document, window, model, sizes) = try fileWindow(
            at: url, type: try #require(UTType(filenameExtension: "md"))
        ) { _, model in
            model.awaitRoomWithoutPages = { await waitGate.wait() }
            model.beforePrepare = { await renderGate.wait() }
        }
        defer {
            sizes.stop()
            document.close()
        }
        func state() -> String {
            "content=\(window.contentRect(forFrameRect: window.frame).size) sizes=\(sizes.sizes) "
                + "unit=\(String(describing: model.paperUnitSize)) sized=\(model.hasSizedWindow) "
                + "error=\(model.error ?? "nil") wait=(\(waitGate.enterCount),\(waitGate.exitCount)) "
                + "render=(\(renderGate.enterCount),\(renderGate.exitCount))"
        }
        try await waitUntil(state()) { waitGate.isWaiting && renderGate.isWaiting }
        #expect(!sizes.sizes.contains(Self.plainSize), "\(state())")
        #expect(!model.hasSizedWindow, "\(state())")

        // Release the wait while pagination is still held, so the plain size is observed before any pages arrive.
        waitGate.open()
        try await waitUntil(state()) { waitGate.exitCount == 1 && sizes.sizes.contains(Self.plainSize) }
        #expect(window.contentRect(forFrameRect: window.frame).size == Self.plainSize, "\(state())")
        #expect(!model.hasSizedWindow, "\(state())")
        #expect(model.result == nil, "\(state())")

        renderGate.open()
        try await waitUntil(state()) { model.result != nil && !model.isRendering && model.hasSizedWindow }
        try expectPapersShape(window, model, state())
    }

    @Test("待ち時間のあいだに窓を閉じると、あとから待ちが終わっても大きさと位置は変わらない", .timeLimit(.minutes(1)))
    func closingDuringWaitLeavesWindowUntouched() async throws {
        let url = try fixtureURL()
        let waitGate = Gate()
        defer { waitGate.open() }
        let renderGate = Gate()
        defer { renderGate.open() }
        let (document, window, model, sizes) = try fileWindow(at: url, type: .png) { _, model in
            model.awaitRoomWithoutPages = { await waitGate.wait() }
            model.beforePrepare = { await renderGate.wait() }
        }
        var closed = false
        defer {
            sizes.stop()
            if !closed { document.close() }
        }
        func state() -> String {
            "frame=\(window.frame) sizes=\(sizes.sizes) closed=\(model.isWindowClosed) "
                + "wait=(\(waitGate.enterCount),\(waitGate.exitCount)) "
                + "render=(\(renderGate.enterCount),\(renderGate.exitCount))"
        }
        try await waitUntil(state()) { waitGate.isWaiting && renderGate.isWaiting }
        let frameBeforeClose = window.frame
        let sizesBeforeClose = sizes.sizes
        document.close()
        closed = true
        waitGate.open()
        renderGate.open()
        try await waitUntil(state()) { waitGate.exitCount == 1 && renderGate.exitCount == 1 }
        await Task.yield()
        #expect(model.isWindowClosed, "\(state())")
        #expect(window.frame == frameBeforeClose, "\(state())")
        #expect(sizes.sizes == sizesBeforeClose, "\(state())")
        #expect(!sizes.sizes.contains(Self.plainSize), "\(state())")
    }

    @Test("刷り台にいる間にエラーになった窓は、表示へ戻ると 760×760 になる", .timeLimit(.minutes(1)))
    func errorOnTrayResizesWindowAfterReturningToViewMode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.7 broken".utf8).write(to: url)
        let waitGate = Gate()
        defer { waitGate.open() }
        let renderGate = Gate()
        defer { renderGate.open() }
        let (document, window, model, sizes) = try fileWindow(at: url, type: .pdf) { _, model in
            model.awaitRoomWithoutPages = { await waitGate.wait() }
            model.beforePrepare = { await renderGate.wait() }
        }
        defer {
            sizes.stop()
            document.close()
        }
        func state() -> String {
            "mode=\(model.mode) content=\(window.contentRect(forFrameRect: window.frame).size) "
                + "sizes=\(sizes.sizes) error=\(model.error ?? "nil") rendering=\(model.isRendering) "
                + "sized=\(model.hasSizedWindow) wait=(\(waitGate.enterCount),\(waitGate.exitCount)) "
                + "render=(\(renderGate.enterCount),\(renderGate.exitCount))"
        }
        try await waitUntil(state()) { waitGate.isWaiting && renderGate.isWaiting }
        model.enterPrintMode()
        try #require(model.mode == .print, "\(state())")
        renderGate.open()
        try await waitUntil(state()) { model.error != nil && !model.isRendering }
        #expect(model.mode == .print, "\(state())")
        #expect(!model.hasSizedWindow, "\(state())")
        #expect(window.contentRect(forFrameRect: window.frame).size != Self.plainSize, "\(state())")
        #expect(waitGate.exitCount == 0, "\(state())")

        model.exitPrintMode()
        try await waitUntil(state()) { model.mode == .view }
        #expect(window.contentRect(forFrameRect: window.frame).size == Self.plainSize, "\(state())")
        #expect(!model.hasSizedWindow, "\(state())")
    }

    @Test("仮の大きさを求めない窓は、エラーになっても大きさと位置を変えない", .timeLimit(.minutes(1)))
    func windowNotNeedingRoomWithoutPagesStaysUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.7 broken".utf8).write(to: url)
        let waitGate = Gate()
        defer { waitGate.open() }
        var keptFrame = NSRect.zero
        let (document, window, model, sizes) = try fileWindow(at: url, type: .pdf) { window, model in
            model.needsRoomWithoutPages = false
            model.awaitRoomWithoutPages = { await waitGate.wait() }
            window.setContentSize(NSSize(width: 420, height: 310))
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.minY + 40))
            }
            keptFrame = window.frame
        }
        defer {
            sizes.stop()
            document.close()
        }
        func state() -> String {
            "frame=\(window.frame) kept=\(keptFrame) sizes=\(sizes.sizes) error=\(model.error ?? "nil") "
                + "rendering=\(model.isRendering) wait=(\(waitGate.enterCount),\(waitGate.exitCount))"
        }
        try #require(window.contentRect(forFrameRect: keptFrame).size != Self.plainSize, "\(state())")
        try await waitUntil(state()) { model.error != nil && !model.isRendering }
        #expect(model.result == nil, "\(state())")
        #expect(waitGate.enterCount == 0, "\(state())")
        #expect(window.frame == keptFrame, "\(state())")
        #expect(sizes.sizes.isEmpty, "\(state())")
    }
}

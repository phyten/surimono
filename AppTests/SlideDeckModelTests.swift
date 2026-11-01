import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SlideDeckModelTests {
    @MainActor private struct Fixture {
        let model: DocumentViewModel
        let store: DocumentSettingsStore
        let window: NSWindow
        let directory: URL
        let suite: TestDefaultsSuite

        func close() {
            model.stop()
            window.close()
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
    }

    private let deck = SlideDeck(size: CGSize(width: 1280, height: 720), count: 6, currentIndex: 2)

    private func fixture(directory existing: URL? = nil) throws -> Fixture {
        let directory = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("<section>Slide</section>".utf8)
        let file = directory.appendingPathComponent("deck.html")
        try data.write(to: file)
        let suite = TestDefaultsSuite()
        let store = DocumentSettingsStore(directory: directory.appendingPathComponent("Settings"))
        let pages = TestFixtures.pdf("html", pages: 2)
        let model = DocumentViewModel(
            data: data, fileURL: file, format: .html, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory.appendingPathComponent("Library")),
            renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pages) ?? PDFDocument() }),
            settingsStore: store)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 848),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        model.window = window
        return Fixture(model: model, store: store, window: window, directory: directory, suite: suite)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func aspect(of window: NSWindow) -> Double {
        Double(window.contentAspectRatio.width / window.contentAspectRatio.height)
    }

    @Test("ウェブでスライドと分かると窓を 16:9 にして 1 枚を合わせ、「スライドとして扱わない」で縦横比を外す")
    func aspectLock() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.slideDeckDidChange(deck)
        #expect(abs(aspect(of: fixture.window) - 16.0 / 9.0) < 0.01)
        let content = fixture.window.contentRect(forFrameRect: fixture.window.frame).size
        #expect(abs(Double(content.width / content.height) - 16.0 / 9.0) < 0.01)
        #expect(model.web.fitSize == CGSize(width: 1280, height: 720))

        model.setIgnoresSlides(true)
        #expect(model.slideDeck == nil)
        #expect(model.detectedSlideDeck == deck)
        #expect(fixture.window.resizeIncrements == NSSize(width: 1, height: 1))
        #expect(model.web.fitSize == nil)

        model.setIgnoresSlides(false)
        #expect(abs(aspect(of: fixture.window) - 16.0 / 9.0) < 0.01)
    }

    @Test("自分で拡大縮小するスライドは窓の形だけを合わせ、ページの拡大は変えない")
    func selfScalingDeck() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        var scaling = deck
        scaling.scalesItself = true
        fixture.model.slideDeckDidChange(scaling)
        #expect(abs(aspect(of: fixture.window) - 16.0 / 9.0) < 0.01)
        #expect(fixture.model.web.fitSize == nil)
    }

    @Test("スライドを送っても窓の形は変えず、帯にはスライドの番号を出し、ふつうのページには出さない")
    func indicator() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let model = fixture.model
        #expect(model.pageIndicator == nil)
        #expect(!BandLayout.Item.applicable(for: model).contains(.pageIndicator))
        model.slideDeckDidChange(deck)
        let frame = fixture.window.frame
        var turned = deck
        turned.currentIndex = 4
        model.slideDeckDidChange(turned)
        #expect(fixture.window.frame == frame)
        let indicator = try #require(model.pageIndicator)
        #expect(indicator.contains("5"))
        #expect(indicator.contains("6"))
        #expect(BandLayout.Item.applicable(for: model).contains(.pageIndicator))
    }

    @Test("「スライドとして扱わない」は内容のハッシュで覚え、次に開くと戻り、触らなければ保存しない")
    func remembersIgnoring() async throws {
        let first = try fixture()
        first.model.start()
        try await waitUntil { first.model.contentHash != nil && first.model.result != nil && !first.model.isRendering }
        first.model.slideDeckDidChange(deck)
        first.model.rememberedSettingsDidChange()
        #expect(first.store.keys().isEmpty)
        first.model.setIgnoresSlides(true)
        first.model.rememberedSettingsDidChange()
        try await waitUntil { first.model.hasSavedSettings }
        let key = try #require(first.model.contentHash?.hex)
        #expect(first.store.record(for: key)?.ignoresSlides == true)
        first.model.stop()
        first.window.close()

        let reopened = try fixture(directory: first.directory)
        defer { reopened.close() }
        reopened.model.start()
        try await waitUntil { reopened.model.contentHash != nil && reopened.model.ignoresSlides }
        reopened.model.slideDeckDidChange(deck)
        #expect(reopened.model.slideDeck == nil)
        reopened.model.resetDocumentSettings()
        #expect(!reopened.model.ignoresSlides)
        first.suite.remove()
    }

    @Test("刷り台ではスライドを全部刷るのが既定で、「今の 1 枚」で今のスライドだけを組み、刷り台を出ると全部に戻る")
    func trayChoice() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.window = nil
        model.slideDeckDidChange(deck)
        #expect(
            model.renderSettings?.slides == SlidePrintRequest(slideSize: CGSize(width: 1280, height: 720), count: 6))
        model.setHTMLPresentation(.paper, capturesWeb: false)
        model.enterPrintMode()
        #expect(model.mode == .print)
        model.setPrintsCurrentSlideOnly(true)
        #expect(model.renderSettings?.slides?.onlyIndex == 2)
        model.exitPrintMode()
        #expect(!model.printsCurrentSlideOnly)
        #expect(model.renderSettings?.slides?.onlyIndex == nil)
    }

    @Test("スライドでない文書と「スライドとして扱わない」文書は、スライドとして組まない")
    func noSlides() throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.setPrintsCurrentSlideOnly(true)
        #expect(!model.printsCurrentSlideOnly)
        #expect(model.renderSettings?.slides == nil)
        model.slideDeckDidChange(deck)
        model.setIgnoresSlides(true)
        #expect(model.renderSettings?.slides == nil)
    }
}

/// The live page's slide observer, with the slides' width switched between a fixed length and the window's width
/// while they keep one size and shape.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SlideObserverTests {
    private let page = """
        <!doctype html><meta charset="utf-8"><style>
        body { margin: 0; }
        .slide { height: 720px; background: #eee; }
        .slide + .slide { display: none; }
        .fixed .slide { width: 1280px; }
        .fluid .slide { width: 100%; }
        </style><body class="fixed"><div class="deck">
        <section class="slide">1</section><section class="slide">2</section><section class="slide">3</section>
        </div></body>
        """

    private func waitUntil(_ condition: () -> Bool) async throws {
        // Up to 20 seconds: a web content process may start slowly on a busy machine.
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test("同じ区画が固定の幅から窓の幅になるとスライドでなくなり、固定の幅に戻るとまたスライドになる")
    func followsStyleChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("deck.html")
        try Data(page.utf8).write(to: file)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 1280, height: 720), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = WebPageController()
        controller.container.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        window.contentView = controller.container
        window.orderFrontRegardless()
        defer {
            controller.close()
            window.contentView = nil
            window.close()
        }
        controller.show(file, allowsJavaScript: true)
        let deck = SlideDeck(size: CGSize(width: 1280, height: 720), count: 3)
        try await waitUntil { controller.slideDeck == deck }

        _ = try await controller.webView?.evaluateJavaScript("document.body.className = 'fluid'")
        try await waitUntil { controller.slideDeck == nil }
        let width =
            try await controller.webView?.evaluateJavaScript(
                "document.querySelector('.slide').offsetWidth") as? Double
        #expect(width == 1280)

        _ = try await controller.webView?.evaluateJavaScript("document.body.className = 'fixed'")
        try await waitUntil { controller.slideDeck == deck }
    }
}

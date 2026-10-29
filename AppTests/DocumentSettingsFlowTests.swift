import AppKit
import CoreGraphics
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct DocumentSettingsFlowTests {
    @MainActor private struct Environment {
        let preferences: AppPreferences
        let library: UserLibrary
        let store: DocumentSettingsStore
        let directory: URL
        let suite: TestDefaultsSuite

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }

        func model(_ data: Data, url: URL? = nil) -> DocumentViewModel {
            DocumentViewModel(
                data: data, fileURL: url, format: .pdf, preferences: preferences, library: library,
                settingsStore: store)
        }
    }

    private func environment() throws -> Environment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = TestDefaultsSuite()
        return Environment(
            preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory.appendingPathComponent("Library")),
            store: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")),
            directory: directory, suite: suite)
    }

    private func pdf(_ label: String, pages: Int = 4) -> Data { TestFixtures.pdf(label, pages: pages) }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    private func open(_ model: DocumentViewModel) async throws {
        model.start()
        try await waitUntil { model.contentHash != nil && model.result != nil && !model.isRendering }
    }

    @Test("何も変えずに閉じた文書の設定は保存しない", .timeLimit(.minutes(1)))
    func untouchedDocumentIsNotSaved() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let model = environment.model(pdf("a"))
        try await open(model)
        model.rememberedSettingsDidChange()
        model.stop()
        #expect(environment.store.keys().isEmpty)
        #expect(!model.hasSavedSettings)
    }

    @Test("変えた設定は内容のハッシュで保存し、名前の違うコピーでも戻す", .timeLimit(.minutes(1)))
    func restoresSettingsByContent() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let data = pdf("a")
        let first = environment.model(data, url: URL(fileURLWithPath: "/fixtures/README.pdf"))
        try await open(first)
        first.setLayout(.single)
        first.viewOptions.direction = .rightToLeft
        first.layoutID = PrintLayout.a3BookletA4.id
        first.rememberedSettingsDidChange()
        first.stop()
        #expect(environment.store.keys() == [ContentHash.of(data).hex])

        let copy = environment.model(data, url: URL(fileURLWithPath: "/fixtures/README のコピー.pdf"))
        try await open(copy)
        #expect(copy.viewOptions.layout == .single)
        #expect(copy.viewOptions.direction == .rightToLeft)
        #expect(copy.layoutID == PrintLayout.a3BookletA4.id)
        #expect(copy.hasSavedSettings)
        #expect(copy.toast?.action == .resetDocumentSettings)
        copy.stop()
    }

    @Test("内容が違う文書は既定値で開き、戻した知らせを出さない", .timeLimit(.minutes(1)))
    func differentContentOpensWithDefaults() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let first = environment.model(pdf("a"))
        try await open(first)
        first.setLayout(.single)
        first.rememberedSettingsDidChange()
        first.stop()

        let edited = environment.model(pdf("b"))
        try await open(edited)
        #expect(edited.viewOptions.layout == .spread)
        #expect(!edited.hasSavedSettings)
        #expect(edited.toast == nil)
        edited.stop()
    }

    @Test("既定に戻すと保存を消し、表示と印刷の設定を既定値にする", .timeLimit(.minutes(1)))
    func resetRemovesSavedSettings() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let model = environment.model(pdf("a"))
        try await open(model)
        model.setLayout(.single)
        model.layoutID = PrintLayout.a4BookletA5.id
        model.printOptions.showsPageNumbers = true
        model.rememberedSettingsDidChange()
        try await waitUntil { model.hasSavedSettings }
        model.resetDocumentSettings()
        #expect(environment.store.keys().isEmpty)
        #expect(model.viewOptions.layout == .spread)
        #expect(model.layoutID == PrintLayout.a4Single.id)
        #expect(!model.printOptions.showsPageNumbers)
        #expect(!model.hasSavedSettings)
        model.rememberedSettingsDidChange()
        model.stop()
        #expect(environment.store.keys().isEmpty)
    }

    @Test("開いている間にファイルが変わったら、表示中の設定を新しいハッシュへ引き継ぐ", .timeLimit(.minutes(1)))
    func carriesSettingsToEditedContent() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        try FileManager.default.createDirectory(at: environment.directory, withIntermediateDirectories: true)
        let url = environment.directory.appendingPathComponent("doc.pdf")
        let original = pdf("a")
        try original.write(to: url)
        let model = environment.model(original, url: url)
        try await open(model)
        model.setLayout(.single)
        model.rememberedSettingsDidChange()
        try await waitUntil { model.hasSavedSettings }

        let edited = pdf("b")
        try edited.write(to: url)
        model.reload()
        try await waitUntil { model.contentHash == ContentHash.of(edited) }
        try await waitUntil { environment.store.record(for: ContentHash.of(edited).hex) != nil }
        #expect(environment.store.record(for: ContentHash.of(edited).hex)?.view?.layout == .single)
        model.stop()
    }

    @Test("最初の描画を待つ間に選んだ表示の型は、描画後の既定値で上書きしない", .timeLimit(.minutes(1)))
    func userChoiceDuringFirstRenderSurvives() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let pages = pdf("pages", pages: 3)
        let renderer = DocumentRenderer(paginate: { _ in
            try await Task.sleep(for: .milliseconds(400))
            return PDFDocument(data: pages) ?? PDFDocument()
        })
        let model = DocumentViewModel(
            data: Data("# 見出し".utf8), fileURL: nil, format: .markdown, preferences: environment.preferences,
            library: environment.library, renderer: renderer, settingsStore: environment.store)
        model.start()
        model.setLayout(.spread)
        model.rememberedSettingsDidChange()
        try await waitUntil { model.result != nil && !model.isRendering }
        #expect(model.viewOptions.layout == .spread)
        model.stop()
        let key = try #require(model.contentHash).hex
        #expect(environment.store.record(for: key)?.view?.layout == .spread)

        let reopened = DocumentViewModel(
            data: Data("# 見出し".utf8), fileURL: nil, format: .markdown, preferences: environment.preferences,
            library: environment.library, renderer: renderer, settingsStore: environment.store)
        try await open(reopened)
        #expect(reopened.viewOptions.layout == .spread)
        reopened.stop()
    }

    @Test("最初の描画が終わる前に閉じても、その間に選んだ表示の型を保存して次に戻す", .timeLimit(.minutes(1)))
    func choiceBeforeFirstRenderIsSavedOnEarlyClose() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let pages = pdf("pages", pages: 3)
        let slow = DocumentRenderer(paginate: { _ in
            try await Task.sleep(for: .seconds(5))
            return PDFDocument(data: pages) ?? PDFDocument()
        })
        let data = Data("# 見出し".utf8)
        let model = DocumentViewModel(
            data: data, fileURL: nil, format: .markdown, preferences: environment.preferences,
            library: environment.library, renderer: slow, settingsStore: environment.store)
        model.start()
        model.setLayout(.spread)
        model.rememberedSettingsDidChange()
        try await waitUntil { model.contentHash != nil }
        #expect(model.isRendering)
        model.stop()
        #expect(environment.store.record(for: ContentHash.of(data).hex)?.view?.layout == .spread)

        let fast = DocumentRenderer(paginate: { _ in PDFDocument(data: pages) ?? PDFDocument() })
        let reopened = DocumentViewModel(
            data: data, fileURL: nil, format: .markdown, preferences: environment.preferences,
            library: environment.library, renderer: fast, settingsStore: environment.store)
        try await open(reopened)
        #expect(reopened.viewOptions.layout == .spread)
        reopened.stop()
    }

    @Test("保存した並び順の ZIP は、開いて閉じるだけでは設定を書き換えない", .timeLimit(.minutes(1)))
    func restoringZipOrderDoesNotSave() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let zip = TestFixtures.storedZip([
            ("1.png", TestFixtures.png(red: 0.1)), ("2.png", TestFixtures.png(red: 0.5)),
            ("3.png", TestFixtures.png(red: 0.9)),
        ])
        func openZip() throws -> DocumentViewModel {
            let archive = try ZipArchive(data: zip)
            let bundle = ImageBundleModel(
                archive: archive, selection: ZipImageSelection(archive: archive),
                archiveURL: URL(fileURLWithPath: "/fixtures/写真.zip"))
            return DocumentViewModel(
                data: zip, fileURL: nil, format: .zipArchive, preferences: environment.preferences,
                library: environment.library, imageBundle: bundle, settingsStore: environment.store)
        }
        let first = try openZip()
        try await open(first)
        first.imageBundle?.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        first.rememberedSettingsDidChange()
        first.stop()
        let key = ContentHash.of(zip).hex
        let saved = try #require(environment.store.record(for: key))
        #expect(saved.imageOrder?.count == 3)

        let second = try openZip()
        try await open(second)
        try await waitUntil { second.imageBundle?.urls.first?.lastPathComponent == "3.png" && !second.isRendering }
        // A sentinel survives only if opening wrote nothing.
        var sentinel = saved
        sentinel.zoom = 1.23
        try environment.store.save(sentinel, for: key)
        second.rememberedSettingsDidChange()
        try await Task.sleep(for: .milliseconds(700))
        second.stop()
        #expect(environment.store.record(for: key)?.zoom == 1.23)
    }

    @Test("画像の束を読み直している間に、保存した並び順を欠けた状態で上書きしない", .timeLimit(.minutes(1)))
    func reloadingBundleKeepsSavedOrder() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let source = SlowImages(["a.png": TestFixtures.png(red: 0.1), "b.png": TestFixtures.png(red: 0.6)])
        let urls = ["a.png", "b.png"].map { URL(fileURLWithPath: "/fixtures/" + $0) }
        let bundle = ImageBundleModel(urls: urls, readImage: { try source.read($0) })
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image, preferences: environment.preferences,
            library: environment.library, imageBundle: bundle, settingsStore: environment.store)
        try await open(model)
        bundle.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        model.rememberedSettingsDidChange()
        try await waitUntil { model.hasSavedSettings }
        let key = try #require(model.contentHash).hex
        let order = try #require(environment.store.record(for: key)?.imageOrder)

        source.delay = .milliseconds(800)
        model.reload()
        model.rememberedSettingsDidChange()
        try await Task.sleep(for: .milliseconds(600))
        #expect(environment.store.record(for: key)?.imageOrder == order)
        try await waitUntil { !model.isRendering }
        #expect(environment.store.record(for: key)?.imageOrder == order)
        model.stop()
    }

    @Test("開いたあとに画像が編集されたら、描き直す前にハッシュを取り直して新しい組として扱う", .timeLimit(.minutes(1)))
    func editedImageIsRehashedBeforeDrawing() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let source = SlowImages(["a.png": TestFixtures.png(red: 0.1), "b.png": TestFixtures.png(red: 0.6)])
        let urls = ["a.png", "b.png"].map { URL(fileURLWithPath: "/fixtures/" + $0) }
        let bundle = ImageBundleModel(urls: urls, readImage: { try source.read($0) })
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image, preferences: environment.preferences,
            library: environment.library, imageBundle: bundle, settingsStore: environment.store)
        try await open(model)
        let before = try #require(model.contentHash)

        // Edited outside the app; a print option change then needs the pages drawn again.
        source.replace("b.png", with: TestFixtures.png(red: 0.9))
        model.printOptions.marginsInMillimeters = 20
        model.render()
        try await waitUntil { !model.isRendering && model.contentHash != before }
        #expect(model.error == nil)
        #expect(model.contentHash == bundle.setHash)
        #expect(model.renderedSettings?.options.marginsInMillimeters == 20)
        model.stop()
    }

    @Test("中身の変わった画像の束を読み直すと、並び順とキーを同時に切り替え、前の記録は書き換えない", .timeLimit(.minutes(1)))
    func reloadingChangedBundleSwitchesKeyWithDigests() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let source = SlowImages(["a.png": TestFixtures.png(red: 0.1), "b.png": TestFixtures.png(red: 0.6)])
        let urls = ["a.png", "b.png"].map { URL(fileURLWithPath: "/fixtures/" + $0) }
        let bundle = ImageBundleModel(urls: urls, readImage: { try source.read($0) })
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image, preferences: environment.preferences,
            library: environment.library, imageBundle: bundle, settingsStore: environment.store)
        try await open(model)
        bundle.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        model.rememberedSettingsDidChange()
        try await waitUntil { model.hasSavedSettings }
        let oldKey = try #require(model.contentHash).hex
        let oldRecord = try #require(environment.store.record(for: oldKey))
        let oldDigests = try #require(bundle.orderDigests)

        source.replace("b.png", with: TestFixtures.png(red: 0.9))
        model.reload()
        // Whenever the new digests are visible, the key must already be the new set's.
        for _ in 0..<1000 where bundle.orderDigests == oldDigests {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(bundle.orderDigests != oldDigests)
        #expect(model.contentHash == bundle.setHash)
        model.rememberedSettingsDidChange()
        try await waitUntil { !model.isRendering }
        model.stop()
        #expect(environment.store.record(for: oldKey) == oldRecord)
        let newKey = try #require(model.contentHash).hex
        #expect(newKey != oldKey)
        #expect(environment.store.record(for: newKey)?.imageOrder == bundle.orderDigests)
    }

    @Test("印刷モードで設定を変えて閉じても、表示モードの窓の大きさを覚えておく", .timeLimit(.minutes(1)))
    func printModeKeepsViewWindowSize() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let data = pdf("a")
        let model = environment.model(data)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 848),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        model.window = window
        try await open(model)
        model.enterPrintMode()
        #expect(window.contentRect(forFrameRect: window.frame).size != NSSize(width: 600, height: 848))
        model.printOptions.showsPageNumbers = true
        model.rememberedSettingsDidChange()
        model.stop()
        let saved = try #require(environment.store.record(for: ContentHash.of(data).hex))
        #expect(saved.windowSize == CGSize(width: 600, height: 848))
        #expect(saved.printOptions?.showsPageNumbers == true)
        withExtendedLifetime(window) {}
    }
}
/// Image data for a bundle whose reads can be slowed down, as when files sit on a slow disk.
private final class SlowImages: @unchecked Sendable {
    // Only the test sets these, before the reads it slows down start; the lock keeps reads from other threads safe.
    private let lock = NSLock()
    private var images: [String: Data]
    private var _delay: Duration = .zero
    var delay: Duration {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    init(_ images: [String: Data]) { self.images = images }

    func replace(_ name: String, with data: Data) { lock.withLock { images[name] = data } }

    func read(_ url: URL) throws -> Data {
        let delay = delay
        if delay > .zero {
            Thread.sleep(
                forTimeInterval: Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
        }
        guard let data = lock.withLock({ images[url.lastPathComponent] }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }
}

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

    @Test("文字サイズと用紙の向きの既定値は開くだけでは保存せず文書の操作を優先する", .timeLimit(.minutes(1)))
    func textAndOrientationDefaults() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        environment.preferences.defaultTextScale = 1.25
        environment.preferences.defaultPaperOrientation = .landscape
        let data = Data("# Viewer defaults".utf8)
        let pageData = pdf("Theme", pages: 1)
        func model() -> DocumentViewModel {
            DocumentViewModel(
                data: data, fileURL: nil, format: .markdown,
                preferences: environment.preferences, library: environment.library,
                renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pageData)! }),
                settingsStore: environment.store)
        }
        let first = model()
        defer { first.stop() }
        #expect(first.textScale == 1.25)
        #expect(first.paperOrientation == .landscape)
        environment.preferences.defaultTextScale = 1.5
        environment.preferences.defaultPaperOrientation = .portrait
        try await open(first)
        #expect(first.rememberedSettings.textScale == 1.25)
        #expect(first.rememberedSettings.paperOrientation == .landscape)
        first.rememberedSettingsDidChange()
        try await Task.sleep(for: .milliseconds(550))
        #expect(!first.hasSavedSettings)
        #expect(environment.store.keys().isEmpty)
        first.setTextScale(1.75)
        first.paperOrientation = .auto
        first.rememberedSettingsDidChange()
        try await waitUntil { first.hasSavedSettings }
        let reopened = model()
        defer { reopened.stop() }
        try await open(reopened)
        #expect(reopened.textScale == 1.75)
        #expect(reopened.paperOrientation == .auto)
        reopened.resetDocumentSettings()
        #expect(reopened.textScale == 1.5)
        #expect(reopened.paperOrientation == .portrait)
        reopened.rememberedSettingsDidChange()
        try await Task.sleep(for: .milliseconds(550))
        #expect(!reopened.hasSavedSettings)
        #expect(environment.store.keys().isEmpty)
    }

    @Test("新しい窓は最前面と帯の出し方の既定値を使い帯の場所を初期サイズに含める", .timeLimit(.minutes(1)))
    func openingWindowDefaults() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        environment.preferences.defaultAlwaysOnTop = true
        environment.preferences.defaultBandVisibility = .always
        let model = environment.model(pdf("Pinned"))
        defer { model.stop() }
        #expect(model.isAlwaysOnTop && model.isBandAlwaysVisible)
        #expect(model.loneCoverWidth == .onePage)
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        let window = try #require(controller.window)
        defer { controller.close() }
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        try await waitUntil { window.level == .floating }
        let unit = try #require(model.paperUnitSize)
        let paper = ViewerWindow.initialPaperSize(unit: unit, on: window.screen)
        let content = window.contentRect(forFrameRect: window.frame).size
        #expect(abs(content.height - paper.height - 2 * ViewerWindow.bandHeight) <= 1)
        #expect(abs(content.width - paper.width) <= 1)
        environment.preferences.defaultAlwaysOnTop = false
        environment.preferences.defaultBandVisibility = .onHover
        #expect(model.isAlwaysOnTop && model.isBandAlwaysVisible)
        model.toggleAlwaysOnTop()
        model.rememberedSettingsDidChange()
        try await Task.sleep(for: .milliseconds(550))
        #expect(!model.hasSavedSettings)
        #expect(environment.store.keys().isEmpty)
    }

    @Test("表紙では窓を 1 ページ幅にし、めくると綴じ側の端を動かさずに見開きの幅へ広げ、自動の大きさは保存しない", .timeLimit(.minutes(1)))
    func coverWindowWidth() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let model = environment.model(pdf("Cover", pages: 6))
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        let window = try #require(controller.window)
        defer { controller.close() }
        try await open(model)
        // A PDF of six portrait pages opens as a left-to-right book with its cover alone.
        #expect(model.viewOptions.layout == .spread && model.viewOptions.showsCoverAlone)
        model.sizeWindowToPaper(initialOnly: true)
        #expect(model.showsNarrowCover)
        func paperRatio() -> CGFloat {
            let content = window.contentRect(forFrameRect: window.frame).size
            return content.width / (content.height - 2 * ViewerWindow.bandHeight)
        }
        let page: CGFloat = 595.0 / 842.0
        #expect(abs(paperRatio() - page) < 0.02)
        // Leave room on the left: a window at the edge of the screen is kept on it rather than at its right edge.
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameTopLeftPoint(NSPoint(x: visible.midX, y: window.frame.maxY))
        let rightEdge = window.frame.maxX

        // Turn the paper itself, so that PDFKit's page change and the window's reaction to it are what move.
        try await waitUntil { model.paper.isConnected }
        model.paper.turnPage(forward: true)
        try await waitUntil { model.currentPageIndex == 1 && abs(paperRatio() - 2 * page) < 0.02 }
        #expect(!model.showsNarrowCover)
        #expect(abs(window.frame.maxX - rightEdge) <= 1)

        model.paper.turnPage(forward: false)
        try await waitUntil { model.currentPageIndex == 0 && abs(paperRatio() - page) < 0.02 }
        #expect(abs(window.frame.maxX - rightEdge) <= 1)
        try await Task.sleep(for: .milliseconds(550))
        #expect(!model.hasSavedSettings)
    }

    @Test("既定に戻すと現在の表示の既定値を使いウィンドウの固定状態は変えない", .timeLimit(.minutes(1)))
    func resetViewerDefaults() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let model = environment.model(pdf("Reset"))
        defer { model.stop() }
        try await open(model)
        environment.preferences.defaultReadingDirection = .rightToLeft
        environment.preferences.defaultScrollAxis = .vertical
        environment.preferences.defaultShowsCoverAlone = false
        model.isAlwaysOnTop = true
        model.bandVisibility = .always
        model.resetDocumentSettings()
        #expect(model.viewOptions.direction == .rightToLeft)
        #expect(model.viewOptions.scrollAxis == .vertical)
        #expect(!model.viewOptions.showsCoverAlone)
        #expect(model.isAlwaysOnTop && model.isBandAlwaysVisible)
        model.rememberedSettingsDidChange()
        try await Task.sleep(for: .milliseconds(550))
        #expect(environment.store.keys().isEmpty)
    }

    @Test("合本のHTMLを外で変更しても再読み込みまでは組版内容と保存の集合キーが一致する", .timeLimit(.minutes(1)))
    func binderHTMLSnapshot() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        try FileManager.default.createDirectory(at: environment.directory, withIntermediateDirectories: true)
        let htmlURL = environment.directory.appendingPathComponent("a.html")
        let pdfURL = environment.directory.appendingPathComponent("b.pdf")
        let before = "<p>Before</p>"
        let after = "<p>After</p>"
        let pdfData = pdf("PDF", pages: 1)
        try Data(before.utf8).write(to: htmlURL)
        try pdfData.write(to: pdfURL)
        var inputs: [String] = []
        let renderer = DocumentRenderer(paginate: { request in
            guard case .sandboxed(let html?, _) = request.source else {
                Issue.record("合本のHTMLは読み込み済み本文で組版する")
                return PDFDocument(data: pdfData)!
            }
            inputs.append(html)
            return PDFDocument(data: pdfData)!
        })
        let binder = BinderModel(urls: [htmlURL, pdfURL])
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf,
            preferences: environment.preferences, library: environment.library, renderer: renderer,
            settingsStore: environment.store, binder: binder)
        defer { model.stop() }
        try await open(model)
        let originalKey = ContentHash.binderSet([.of(Data(before.utf8)), .of(pdfData)])
        let updatedKey = ContentHash.binderSet([.of(Data(after.utf8)), .of(pdfData)])
        #expect(model.contentHash == originalKey)
        #expect(inputs == [before])
        try Data(after.utf8).write(to: htmlURL)
        model.printOptions.marginsInMillimeters = 11
        model.render()
        try await waitUntil { !model.isRendering }
        model.rememberedSettingsDidChange()
        #expect(inputs == [before, before])
        #expect(model.contentHash == originalKey && binder.setHash == originalKey)
        try await waitUntil { environment.store.record(for: originalKey.hex)?.printOptions?.marginsInMillimeters == 11 }
        #expect(environment.store.record(for: updatedKey.hex) == nil)
        model.reload()
        try await waitUntil { !model.isRendering && model.contentHash == updatedKey }
        #expect(inputs == [before, before, after])
        #expect(binder.setHash == updatedKey)
        #expect(environment.store.record(for: updatedKey.hex)?.printOptions?.marginsInMillimeters == 11)
    }

    @Test("合本の並び順と表面開始を集合の鍵で保存し開き直して復元する", .timeLimit(.minutes(1)))
    func binderSettings() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let a = URL(fileURLWithPath: "/fixture/a.pdf")
        let b = URL(fileURLWithPath: "/fixture/b.pdf")
        let bytes = [a: pdf("A", pages: 1), b: pdf("B", pages: 2)]
        func makeModel() -> DocumentViewModel {
            DocumentViewModel(
                data: Data(), fileURL: nil, format: .pdf,
                preferences: environment.preferences, library: environment.library,
                settingsStore: environment.store,
                binder: BinderModel(urls: [a, b], read: { bytes[$0]! }))
        }
        let first = makeModel()
        defer { first.stop() }
        try await open(first)
        #expect(!first.hasSavedSettings)
        first.binder?.moveSelection(by: 1)
        first.binderStartsOnFront = true
        first.render()
        try await waitUntil { !first.isRendering }
        first.rememberedSettingsDidChange()
        first.stop()
        let key = try #require(first.contentHash)
        let saved = try #require(environment.store.record(for: key.hex))
        #expect(saved.binderOrder == [ContentHash.of(bytes[b]!).hex, ContentHash.of(bytes[a]!).hex])
        #expect(saved.binderStartsOnFront == true)
        let second = makeModel()
        defer { second.stop() }
        try await open(second)
        #expect(second.contentHash == key)
        #expect(second.binder?.urls == [b, a])
        #expect(second.binderStartsOnFront)
        #expect(second.renderSettings?.layout == .a4Single)
        // The fixture labels are PDF metadata; its pages intentionally contain no text.
        #expect(second.binder?.orderDigests == [ContentHash.of(bytes[b]!).hex, ContentHash.of(bytes[a]!).hex])
        #expect(second.result?.logicalDocument.pageCount == 3)
        second.resetDocumentSettings()
        #expect(second.binder?.urls == [a, b])
        #expect(!second.binderStartsOnFront)
        #expect(environment.store.keys().isEmpty)
    }

    @Test("冊子を覚えた文書を開き直しても表示は A4 片面で、刷り台には冊子を復元する", .timeLimit(.minutes(1)))
    func rememberedBookletOnlyAffectsPrinting() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let data = pdf("Remembered booklet")
        let first = environment.model(data)
        try await open(first)
        first.layoutID = PrintLayout.a4BookletA5.id
        first.rememberedSettingsDidChange()
        first.stop()

        let reopened = environment.model(data)
        defer { reopened.stop() }
        try await open(reopened)
        #expect(reopened.mode == .view)
        #expect(reopened.layoutID == "a4BookletA5")
        #expect(reopened.renderedSettings?.layout == .a4Single)
        #expect(reopened.renderSettings?.layout == .a4Single)
        reopened.enterPrintMode()
        #expect(reopened.renderSettings?.layout == .a4BookletA5)
        #expect(!reopened.canOutput)
        reopened.render()
        try await waitUntil { !reopened.isRendering }
        #expect(reopened.canOutput)
        #expect(reopened.printResult?.layout == .a4BookletA5)
    }

    @Test("新しい文書だけが表示の既定値を取り込み、保存した表示は優先する", .timeLimit(.minutes(1)))
    func newViewDefaults() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        environment.preferences.defaultViewLayout = .single
        environment.preferences.defaultPageTurn = .fade
        environment.preferences.defaultJoinsPages = false
        let data = pdf("View defaults")
        let first = environment.model(data)
        defer { first.stop() }
        // Defaults are captured at opening, even if pagination finishes after the preference changes.
        environment.preferences.defaultViewLayout = .spread
        environment.preferences.defaultPageTurn = .wipe
        environment.preferences.defaultJoinsPages = true
        try await open(first)
        #expect(first.viewOptions.layout == .single)
        #expect(first.viewOptions.transition == .fade)
        #expect(!first.viewOptions.joinsPages)
        #expect(!first.hasSavedSettings)
        first.setLayout(.spread)
        first.rememberedSettingsDidChange()
        try await waitUntil { first.hasSavedSettings }
        let reopened = environment.model(data)
        defer { reopened.stop() }
        try await open(reopened)
        #expect(reopened.viewOptions.layout == .spread)
        #expect(reopened.viewOptions.transition == .fade)
        #expect(!reopened.viewOptions.joinsPages)
        let fresh = environment.model(pdf("Fresh defaults"))
        defer { fresh.stop() }
        try await open(fresh)
        #expect(fresh.viewOptions.layout == .spread)
        #expect(fresh.viewOptions.transition == .wipe)
        #expect(fresh.viewOptions.joinsPages)
    }

    @Test("用紙の向きは操作したときだけ保存して復元し既定に戻すと自動になる", .timeLimit(.minutes(1)))
    func paperOrientationPersistence() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let data = pdf("Orientation")
        let first = environment.model(data)
        defer { first.stop() }
        try await open(first)
        #expect(first.paperOrientation == .auto)
        first.rememberedSettingsDidChange()
        #expect(environment.store.keys().isEmpty)
        first.paperOrientation = .landscape
        first.render()
        try await waitUntil { !first.isRendering }
        #expect(first.canOutput)
        #expect(first.printTray?.layout.landscapeContent == true)
        first.rememberedSettingsDidChange()
        try await waitUntil { first.hasSavedSettings }
        first.stop()
        let reopened = environment.model(data)
        defer { reopened.stop() }
        try await open(reopened)
        #expect(reopened.paperOrientation == .landscape)
        reopened.resetDocumentSettings()
        #expect(reopened.paperOrientation == .auto)
        #expect(environment.store.keys().isEmpty)
    }

    @Test("文字の大きさを内容ごとに保存して復元し、既定に戻すと消える", .timeLimit(.minutes(1)))
    func textScalePersistence() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let data = Data("# Text scale fixture".utf8)
        func model(_ content: Data) -> DocumentViewModel {
            DocumentViewModel(
                data: content, fileURL: nil, format: .markdown, preferences: environment.preferences,
                library: environment.library,
                renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: self.pdf("Text"))! }),
                settingsStore: environment.store)
        }
        let first = model(data)
        try await open(first)
        #expect(first.textScale == 1)
        first.rememberedSettingsDidChange()
        #expect(environment.store.keys().isEmpty)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 848),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        first.window = window
        first.sizeWindowToPaper()
        let originalFrame = window.frame
        first.setTextScale(1.5)
        first.render()
        try await waitUntil { !first.isRendering }
        first.sizeWindowToPaper()
        #expect(window.frame == originalFrame)
        #expect(first.renderSettings?.textScale == 1.5)
        #expect(first.styleName.hasSuffix(" · 150%"))
        first.rememberedSettingsDidChange()
        try await waitUntil { first.hasSavedSettings }
        first.stop()
        #expect(environment.store.record(for: ContentHash.of(data).hex)?.textScale == 1.5)

        let reopened = model(data)
        try await open(reopened)
        #expect(reopened.textScale == 1.5)
        reopened.stop()
        let other = model(Data("Different content".utf8))
        try await open(other)
        #expect(other.textScale == 1)
        other.stop()
        reopened.resetDocumentSettings()
        #expect(reopened.textScale == 1)
        reopened.rememberedSettingsDidChange()
        reopened.stop()
        #expect(environment.store.keys().isEmpty)
    }

    @Test("文字倍率の等号ショートカットはOptionとCommandの組だけを扱う")
    func textSizeKeyboardAlias() throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown, preferences: environment.preferences,
            library: environment.library, settingsStore: environment.store)
        func event(_ flags: NSEvent.ModifierFlags, key: String = "=") throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                    context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 24))
        }
        #expect(model.handleTextSizeKey(try event([.option, .command])))
        #expect(model.textScale == 1.1)
        #expect(!model.handleTextSizeKey(try event(.command)))
        #expect(!model.handleTextSizeKey(try event([.option, .command, .control])))
        #expect(!model.handleTextSizeKey(try event([.option, .command], key: "x")))
        #expect(model.textScale == 1.1)
        model.mode = .print
        #expect(model.handleTextSizeKey(try event([.option, .command])))
        #expect(model.textScale == 1.25)
        model.setTextScale(.infinity)
        #expect(model.textScale == 1.25)
    }

    @Test("テーマのない文書では文字の大きさの操作を無視する", .timeLimit(.minutes(1)))
    func textScaleIgnoresPDF() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let model = environment.model(pdf("PDF"))
        try await open(model)
        model.setTextScale(1.5)
        model.increaseTextSize()
        model.decreaseTextSize()
        model.resetTextSize()
        #expect(model.textScale == 1)
        #expect(model.rememberedSettings.textScale == nil)
        model.stop()
        #expect(environment.store.keys().isEmpty)
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

    @Test("変えた設定は内容のハッシュで保存し、名前の違うコピーでも知らせずに戻す", .timeLimit(.minutes(1)))
    func restoresSettingsByContent() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let data = pdf("a")
        // Real files keep the missing-file notice from obscuring whether restoration stays silent.
        try FileManager.default.createDirectory(at: environment.directory, withIntermediateDirectories: true)
        let original = environment.directory.appending(path: "README.pdf")
        let renamed = environment.directory.appending(path: "README のコピー.pdf")
        try data.write(to: original)
        try data.write(to: renamed)
        let first = environment.model(data, url: original)
        try await open(first)
        first.setLayout(.single)
        first.viewOptions.direction = .rightToLeft
        first.layoutID = PrintLayout.a3BookletA4.id
        first.rememberedSettingsDidChange()
        first.stop()
        #expect(environment.store.keys() == [ContentHash.of(data).hex])

        let copy = environment.model(data, url: renamed)
        try await open(copy)
        #expect(copy.viewOptions.layout == .single)
        #expect(copy.viewOptions.direction == .rightToLeft)
        #expect(copy.layoutID == PrintLayout.a3BookletA4.id)
        #expect(copy.hasSavedSettings)
        #expect(copy.toast == nil)
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
        model.printOptions.furniture = .pageNumber
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

    @Test("開いたまま 3 回書き換えた文書の記録は最新のハッシュの 1 件だけで、ほかの文書の記録には触れない", .timeLimit(.minutes(1)))
    func editedDocumentLeavesOneRecord() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        try FileManager.default.createDirectory(at: environment.directory, withIntermediateDirectories: true)
        let otherKey = ContentHash.of(pdf("other")).hex
        let other = DocumentSettings(textScale: 1.5)
        try environment.store.save(other, for: otherKey)
        let url = environment.directory.appendingPathComponent("doc.pdf")
        let original = pdf("a")
        try original.write(to: url)
        let model = environment.model(original, url: url)
        try await open(model)
        model.setLayout(.single)
        model.rememberedSettingsDidChange()
        try await waitUntil { model.hasSavedSettings }

        // The fixture's bytes differ from one call to the next, so each edit is made once and kept.
        let edits = [pdf("b"), pdf("c"), pdf("d")]
        for edited in edits {
            try edited.write(to: url)
            model.reload()
            try await waitUntil { model.contentHash == ContentHash.of(edited) }
            // Asked without reading the record: a read is a use by someone else, which makes the window keep it.
            try await waitUntil { environment.store.token(for: ContentHash.of(edited).hex) != nil }
        }
        model.stop()
        let newest = ContentHash.of(edits[2]).hex
        #expect(Set(environment.store.keys()) == [newest, otherKey])
        #expect(environment.store.record(for: newest)?.view?.layout == .single)
        #expect(environment.store.record(for: otherKey) == other)
    }

    /// Two files with the same content in different places; the first window creates their shared record.
    private func sharedRecord(_ environment: Environment) async throws -> (
        first: DocumentViewModel, firstURL: URL, copyURL: URL, data: Data
    ) {
        try FileManager.default.createDirectory(at: environment.directory, withIntermediateDirectories: true)
        let data = pdf("a")
        let firstURL = environment.directory.appendingPathComponent("doc.pdf")
        let copyURL = environment.directory.appendingPathComponent("copy.pdf")
        try data.write(to: firstURL)
        try data.write(to: copyURL)
        let first = environment.model(data, url: firstURL)
        try await open(first)
        first.setLayout(.single)
        first.rememberedSettingsDidChange()
        try await waitUntil { first.hasSavedSettings }
        return (first, firstURL, copyURL, data)
    }

    private func edit(_ model: DocumentViewModel, at url: URL, in environment: Environment) async throws -> String {
        let edited = pdf("b")
        try edited.write(to: url)
        model.reload()
        let key = ContentHash.of(edited).hex
        try await waitUntil { model.contentHash?.hex == key && environment.store.token(for: key) != nil }
        return key
    }

    @Test("同じ内容の別のファイルが記録を読んで開いたあとは、元の窓の文書が書き換えられてもその記録を消さない", .timeLimit(.minutes(1)))
    func recordRestoredByAnotherWindowSurvives() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let shared = try await sharedRecord(environment)
        let copy = environment.model(shared.data, url: shared.copyURL)
        try await open(copy)
        #expect(copy.viewOptions.layout == .single)
        copy.stop()

        let newKey = try await edit(shared.first, at: shared.firstURL, in: environment)
        shared.first.stop()
        let oldKey = ContentHash.of(shared.data).hex
        #expect(Set(environment.store.keys()) == [oldKey, newKey])
        #expect(environment.store.record(for: oldKey)?.view?.layout == .single)
    }

    @Test("同じ内容の別のファイルの窓が設定を変えて保存した記録は、元の窓の文書が書き換えられても消さない", .timeLimit(.minutes(1)))
    func recordSavedByAnotherWindowSurvives() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let shared = try await sharedRecord(environment)
        let copy = environment.model(shared.data, url: shared.copyURL)
        try await open(copy)
        copy.viewOptions.direction = .rightToLeft
        copy.rememberedSettingsDidChange()
        copy.stop()

        let newKey = try await edit(shared.first, at: shared.firstURL, in: environment)
        shared.first.stop()
        let oldKey = ContentHash.of(shared.data).hex
        #expect(Set(environment.store.keys()) == [oldKey, newKey])
        #expect(environment.store.record(for: oldKey)?.view?.direction == .rightToLeft)
        #expect(environment.store.record(for: newKey)?.view?.direction == .leftToRight)
    }

    @Test("別の窓が既定に戻してから保存し直した記録は、元の窓の文書が書き換えられても消さない", .timeLimit(.minutes(1)))
    func recordResetAndSavedByAnotherWindowSurvives() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let shared = try await sharedRecord(environment)
        let copy = environment.model(shared.data, url: shared.copyURL)
        try await open(copy)
        copy.resetDocumentSettings()
        let oldKey = ContentHash.of(shared.data).hex
        #expect(environment.store.record(for: oldKey) == nil)
        copy.viewOptions.direction = .rightToLeft
        copy.rememberedSettingsDidChange()
        copy.stop()
        // Not read here: reading the record would itself take the first window's claim away.

        let newKey = try await edit(shared.first, at: shared.firstURL, in: environment)
        shared.first.stop()
        #expect(Set(environment.store.keys()) == [oldKey, newKey])
        #expect(environment.store.record(for: oldKey)?.view?.direction == .rightToLeft)
    }

    @Test("設定を変えていない文書は、開いたまま書き換えられても何も保存しない", .timeLimit(.minutes(1)))
    func untouchedEditedDocumentIsNotSaved() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        try FileManager.default.createDirectory(at: environment.directory, withIntermediateDirectories: true)
        let url = environment.directory.appendingPathComponent("doc.pdf")
        let original = pdf("a")
        try original.write(to: url)
        let model = environment.model(original, url: url)
        try await open(model)
        for edited in [pdf("b"), pdf("c"), pdf("d")] {
            try edited.write(to: url)
            model.reload()
            try await waitUntil { model.contentHash == ContentHash.of(edited) && !model.isRendering }
        }
        model.stop()
        #expect(environment.store.keys().isEmpty)
        #expect(!model.hasSavedSettings)
    }

    @Test("窓を開く前からあった記録は、開いたまま書き換えられても消さない", .timeLimit(.minutes(1)))
    func recordFromBeforeTheWindowSurvivesEditing() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        try FileManager.default.createDirectory(at: environment.directory, withIntermediateDirectories: true)
        let url = environment.directory.appendingPathComponent("doc.pdf")
        let original = pdf("a")
        try original.write(to: url)
        let first = environment.model(original, url: url)
        try await open(first)
        first.setLayout(.single)
        first.rememberedSettingsDidChange()
        first.stop()

        // A copy of the file elsewhere may still have this content, so only this window's own records go away.
        let model = environment.model(original, url: url)
        try await open(model)
        let edits = [pdf("b"), pdf("c")]
        for edited in edits {
            try edited.write(to: url)
            model.reload()
            try await waitUntil { model.contentHash == ContentHash.of(edited) }
            // Asked without reading the record: a read is a use by someone else, which makes the window keep it.
            try await waitUntil { environment.store.token(for: ContentHash.of(edited).hex) != nil }
        }
        model.stop()
        #expect(Set(environment.store.keys()) == [ContentHash.of(original).hex, ContentHash.of(edits[1]).hex])
        #expect(environment.store.record(for: ContentHash.of(edits[1]).hex)?.view?.layout == .single)
    }

    @Test("設定を変えた直後にアプリを終了しても、待っていた保存を終了の前に書き込む", .timeLimit(.minutes(1)))
    func terminationFlushesPendingSave() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let data = pdf("a")
        let model = environment.model(data)
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        try await open(model)
        model.setLayout(.single)
        model.rememberedSettingsDidChange()
        #expect(environment.store.keys().isEmpty)
        AppDelegate().applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(environment.store.record(for: ContentHash.of(data).hex)?.view?.layout == .single)
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

    @Test("最初の描画が終わる前に設定を変えても、紙に合わせる前の窓の大きさは保存しない", .timeLimit(.minutes(1)))
    func unsizedWindowIsNotRemembered() async throws {
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
        // The window as it opens, before the first pages fit it to the paper.
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 450),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        model.window = window
        model.start()
        model.setLayout(.spread)
        model.rememberedSettingsDidChange()
        let key = ContentHash.of(data).hex
        // The save shortly after the change, while the pages are still being laid out.
        try await waitUntil { environment.store.record(for: key) != nil }
        #expect(model.isRendering)
        #expect(environment.store.record(for: key)?.windowSize == nil)
        // And the save as the window closes.
        model.stop()
        let saved = try #require(environment.store.record(for: key))
        #expect(saved.view?.layout == .spread)
        #expect(saved.windowSize == nil)
        withExtendedLifetime(window) {}
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

    @Test("中身の変わった画像の束を読み直すと、並び順とキーを同時に切り替え、前からあった記録は書き換えない", .timeLimit(.minutes(1)))
    func reloadingChangedBundleSwitchesKeyWithDigests() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let source = SlowImages(["a.png": TestFixtures.png(red: 0.1), "b.png": TestFixtures.png(red: 0.6)])
        let urls = ["a.png", "b.png"].map { URL(fileURLWithPath: "/fixtures/" + $0) }
        func makeModel(_ bundle: ImageBundleModel) -> DocumentViewModel {
            DocumentViewModel(
                data: Data(), fileURL: nil, format: .image, preferences: environment.preferences,
                library: environment.library, imageBundle: bundle, settingsStore: environment.store)
        }
        // The record of an earlier window: this window must neither rewrite it nor take it away.
        let earlierBundle = ImageBundleModel(urls: urls, readImage: { try source.read($0) })
        let earlier = makeModel(earlierBundle)
        try await open(earlier)
        earlierBundle.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        earlier.rememberedSettingsDidChange()
        try await waitUntil { earlier.hasSavedSettings }
        earlier.stop()

        let bundle = ImageBundleModel(urls: urls, readImage: { try source.read($0) })
        let model = makeModel(bundle)
        try await open(model)
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

    @Test("この窓で並べ替えた画像の束は、画像が書き換えられると新しい組の記録だけを残す", .timeLimit(.minutes(1)))
    func editedBundleLeavesOneRecord() async throws {
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

        source.replace("b.png", with: TestFixtures.png(red: 0.9))
        model.reload()
        try await waitUntil { model.contentHash?.hex != oldKey && !model.isRendering }
        model.stop()
        let newKey = try #require(model.contentHash).hex
        #expect(environment.store.keys() == [newKey])
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
        model.sizeWindowToPaper()
        let paper = try #require(model.currentPaperSize)
        model.enterPrintMode()
        #expect(model.currentPaperSize == nil)
        model.printOptions.furniture = .pageNumber
        model.rememberedSettingsDidChange()
        model.stop()
        let saved = try #require(environment.store.record(for: ContentHash.of(data).hex))
        #expect(saved.windowSize == paper)
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

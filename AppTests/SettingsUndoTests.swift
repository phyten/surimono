import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct SettingsUndoTests {
    @MainActor
    private final class Fixture {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences: AppPreferences
        let library: UserLibrary
        let store: DocumentSettingsStore

        init() {
            preferences = AppPreferences(defaults: suite.defaults)
            library = UserLibrary(root: root.appendingPathComponent("Library"))
            store = DocumentSettingsStore(directory: root.appendingPathComponent("Settings"))
        }

        func markdown(_ text: String = "# Undo") -> DocumentViewModel {
            let pages = TestFixtures.pdf("Undo", pages: 4)
            return DocumentViewModel(
                data: Data(text.utf8), fileURL: nil, format: .markdown, preferences: preferences, library: library,
                renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pages)! }), settingsStore: store)
        }

        func html() -> DocumentViewModel {
            let pages = TestFixtures.pdf("html", pages: 2)
            return DocumentViewModel(
                data: Data("<p>本文</p>".utf8), fileURL: nil, format: .html, preferences: preferences,
                library: library, renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pages)! }),
                settingsStore: nil)
        }

        func set(_ name: String, layoutID: String) -> PrintSettingSet {
            PrintSettingSet(name: name, settings: DocumentSettings(layoutID: layoutID, themeID: "mincho"))
        }

        deinit {
            suite.remove()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    private func open(_ model: DocumentViewModel) async throws {
        model.start()
        try await waitUntil { model.contentHash != nil && model.result != nil && !model.isRendering }
    }

    /// Changes something of every kind a text remembers, as the reader would.
    private func changeEverything(_ model: DocumentViewModel) {
        model.setLayout(.single)
        model.zoom = 1.5
        model.layoutID = PrintLayout.b5BookletB6.id
        model.paperSeries = .b
        model.themeID = "mincho"
        model.setTextScale(1.5)
        model.paperOrientation = .landscape
        model.printOptions.furniture = .pageNumber
        model.printOptions.mirrorsMargins = true
        model.printFinish.breaks.keepsTablesWhole = true
        model.codeBlock.lineNumbers = .all
        model.bandVisibility = .always
        model.notes.isEnabled = true
    }

    /// One step of the reader's, which the undo manager otherwise groups by the event they came from.
    private func step(_ undo: UndoManager, _ action: () -> Void) {
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    @Test("文書の設定を戻して取り消すと、戻す前の設定がすべて戻り、保存した記録も元に戻る", .timeLimit(.minutes(1)))
    func undoRestoresEverything() async throws {
        let fixture = Fixture()
        let model = fixture.markdown()
        defer { model.stop() }
        try await open(model)
        changeEverything(model)
        model.rememberedSettingsDidChange()
        try await waitUntil { model.hasSavedSettings }
        let key = try #require(model.contentHash?.hex)
        let before = model.rememberedSettings
        let saved = try #require(fixture.store.record(for: key))

        model.resetDocumentSettings()
        #expect(model.rememberedSettings != before)
        #expect(fixture.store.keys().isEmpty)
        model.undoResetDocumentSettings()

        #expect(model.rememberedSettings == before)
        #expect(model.viewOptions.layout == .single)
        #expect(model.zoom == 1.5)
        #expect(model.layoutID == "b5BookletB6")
        #expect(model.themeID == "mincho")
        #expect(model.textScale == 1.5)
        #expect(model.paperOrientation == .landscape)
        #expect(model.printOptions.mirrorsMargins)
        #expect(model.printFinish.breaks.keepsTablesWhole)
        #expect(model.codeBlock.lineNumbers == .all)
        #expect(model.bandVisibility == .always)
        #expect(model.notes.isEnabled)
        #expect(model.hasSavedSettings)
        #expect(fixture.store.record(for: key) == saved)
        #expect(model.toast == nil)
    }

    @Test("文書の設定を戻すと、取り消すボタンのついた知らせが出る")
    func resetShowsUndoToast() {
        let fixture = Fixture()
        let model = fixture.markdown()
        defer { model.stop() }
        model.themeID = "mincho"
        model.resetDocumentSettings()
        #expect(model.toast?.title == String(localized: "Settings reset"))
        #expect(model.toast?.action == .undoReset)
    }

    @Test("文書の設定を戻して取り消さなければ、既定値のままで記録も消えたままになる", .timeLimit(.minutes(1)))
    func resetWithoutUndoStays() async throws {
        let fixture = Fixture()
        let model = fixture.markdown()
        defer { model.stop() }
        try await open(model)
        changeEverything(model)
        model.rememberedSettingsDidChange()
        try await waitUntil { model.hasSavedSettings }

        model.resetDocumentSettings()
        model.dismissToast()
        model.rememberedSettingsDidChange()
        try await Task.sleep(for: .milliseconds(550))

        #expect(model.layoutID == "a4Single")
        #expect(model.themeID == "standard")
        #expect(model.textScale == 1)
        #expect(!model.notes.isEnabled)
        #expect(!model.hasSavedSettings)
        #expect(fixture.store.keys().isEmpty)
    }

    @Test("保存する前に変えた設定も、戻して取り消すと戻り、そのあとで保存される", .timeLimit(.minutes(1)))
    func undoRestoresUnsavedChanges() async throws {
        let fixture = Fixture()
        let model = fixture.markdown()
        defer { model.stop() }
        try await open(model)
        model.themeID = "mincho"
        model.resetDocumentSettings()
        model.undoResetDocumentSettings()
        #expect(model.themeID == "mincho")
        try await waitUntil { model.hasSavedSettings }
        let key = try #require(model.contentHash?.hex)
        #expect(fixture.store.record(for: key)?.themeID == "mincho")
    }

    @Test("スマート削除のオンと残す一覧も、取り消すと戻る")
    func undoRestoresSmartRemoval() {
        let fixture = Fixture()
        let model = fixture.html()
        defer { model.stop() }
        model.setSmartRemoval(enabled: true)
        model.toggleKeep("#cookie")
        model.resetDocumentSettings()
        #expect(!model.isSmartRemovalEnabled)
        model.undoResetDocumentSettings()
        #expect(model.isSmartRemovalEnabled)
        #expect(model.smartRemovalKeptIDs == ["#cookie"])
    }

    @Test("画像の並び順も、取り消すと戻る", .timeLimit(.minutes(1)))
    func undoRestoresImageOrder() async throws {
        let fixture = Fixture()
        let zip = TestFixtures.storedZip([
            ("1.png", TestFixtures.png(red: 0.1)), ("2.png", TestFixtures.png(red: 0.5)),
            ("3.png", TestFixtures.png(red: 0.9)),
        ])
        let archive = try ZipArchive(data: zip)
        let bundle = ImageBundleModel(
            archive: archive, selection: ZipImageSelection(archive: archive),
            archiveURL: URL(fileURLWithPath: "/fixtures/写真.zip"))
        let model = DocumentViewModel(
            data: zip, fileURL: nil, format: .zipArchive, preferences: fixture.preferences, library: fixture.library,
            imageBundle: bundle, settingsStore: fixture.store)
        defer { model.stop() }
        try await open(model)
        bundle.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(bundle.urls.map(\.lastPathComponent) == ["3.png", "1.png", "2.png"])
        model.resetDocumentSettings()
        #expect(bundle.urls.map(\.lastPathComponent) == ["1.png", "2.png", "3.png"])
        model.undoResetDocumentSettings()
        #expect(bundle.urls.map(\.lastPathComponent) == ["3.png", "1.png", "2.png"])
    }

    /// A PDF in a window whose paper the reader made smaller than it opened, with that saved.
    private func resizedDocument(_ fixture: Fixture) async throws -> (DocumentViewModel, NSWindow, CGSize) {
        let model = DocumentViewModel(
            data: TestFixtures.pdf("Size", pages: 4), fileURL: nil, format: .pdf, preferences: fixture.preferences,
            library: fixture.library, settingsStore: fixture.store)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 848),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        model.window = window
        try await open(model)
        model.sizeWindowToPaper()
        let opened = try #require(model.currentPaperSize)
        var frame = window.frame
        frame.size.width -= (opened.width * 0.25).rounded()
        frame.size.height -= (opened.height * 0.25).rounded()
        window.setFrame(frame, display: false)
        let resized = try #require(model.currentPaperSize)
        #expect(resized.height < opened.height - 50)
        model.printOptions.furniture = .pageNumber
        model.rememberedSettingsDidChange()
        try await waitUntil { model.hasSavedSettings }
        return (model, window, resized)
    }

    private func isClose(_ size: CGSize?, to expected: CGSize) -> Bool {
        guard let size else { return false }
        return abs(size.width - expected.width) <= 3 && abs(size.height - expected.height) <= 3
    }

    @Test("刷り台で設定を戻し、表示に戻ってから取り消すと、窓は変えてあった大きさのままで、記録にもその大きさが残る", .timeLimit(.minutes(1)))
    func undoInViewAfterResetInTray() async throws {
        let fixture = Fixture()
        let (model, window, resized) = try await resizedDocument(fixture)
        defer { model.stop() }
        let key = try #require(model.contentHash?.hex)
        model.enterPrintMode()
        model.resetDocumentSettings()
        model.exitPrintMode()
        try await waitUntil { model.mode == .view }
        model.undoResetDocumentSettings()
        #expect(isClose(model.currentPaperSize, to: resized))
        #expect(model.printOptions.showsPageNumbers)
        #expect(isClose(fixture.store.record(for: key)?.windowSize, to: resized))
        withExtendedLifetime(window) {}
    }

    @Test("表示で設定を戻し、刷り台で取り消すと、記録に元の窓の大きさが戻り、表示に戻ると窓もその大きさになる", .timeLimit(.minutes(1)))
    func undoInTrayAfterResetInView() async throws {
        let fixture = Fixture()
        let (model, window, resized) = try await resizedDocument(fixture)
        defer { model.stop() }
        let key = try #require(model.contentHash?.hex)
        model.resetDocumentSettings()
        #expect(!isClose(model.currentPaperSize, to: resized))
        model.enterPrintMode()
        model.undoResetDocumentSettings()
        #expect(model.printOptions.showsPageNumbers)
        #expect(isClose(fixture.store.record(for: key)?.windowSize, to: resized))
        model.exitPrintMode()
        try await waitUntil { model.mode == .view }
        #expect(isClose(model.currentPaperSize, to: resized))
        withExtendedLifetime(window) {}
    }

    @Test("アプリが開いた窓では、編集メニューの取り消しで設定が戻り、やり直すともう一度既定になる")
    func windowHistory() throws {
        let fixture = Fixture()
        let model = fixture.markdown()
        defer { model.stop() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        model.window = window
        let undo = try #require(window.undoManager)
        model.themeID = "mincho"
        step(undo) { model.resetDocumentSettings() }
        #expect(model.themeID == "standard")
        undo.undo()
        #expect(model.themeID == "mincho")
        #expect(model.toast == nil)
        undo.redo()
        #expect(model.themeID == "standard")
        #expect(model.toast?.action == .undoReset)
    }

    @Test("あとから別の知らせが出ても、窓の取り消しでは設定を戻せる")
    func laterToastKeepsWindowUndo() throws {
        let fixture = Fixture()
        let model = fixture.markdown()
        defer { model.stop() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        model.window = window
        let undo = try #require(window.undoManager)
        model.themeID = "mincho"
        step(undo) { model.resetDocumentSettings() }
        model.showToast(Toast(systemImage: "info.circle", title: "Later"))
        #expect(model.toast?.action == nil)
        undo.undo()
        #expect(model.themeID == "mincho")
    }

    @Test("設定セットを削除して取り消すと、同じ名前と中身で元の位置に戻る")
    func undoRestoresSettingSet() throws {
        let fixture = Fixture()
        let preferences = fixture.preferences
        for (name, layout) in [("One", "a4Single"), ("Two", "a4Duplex"), ("Three", "a4BookletA5")] {
            preferences.savePrintSettingSet(fixture.set(name, layoutID: layout))
        }
        let sets = preferences.printSettingSets
        let removal = try #require(preferences.removePrintSettingSet(sets[1].id))
        #expect(preferences.printSettingSets.map(\.name) == ["One", "Three"])
        #expect(preferences.restorePrintSettingSet(removal))
        #expect(preferences.printSettingSets == sets)
        #expect(preferences.printSettingSets[1].layoutID == "a4Duplex")
        // The list is what the next launch reads.
        #expect(AppPreferences(defaults: fixture.suite.defaults).printSettingSets == sets)
    }

    @Test("設定セットを削除すると、その名前と取り消しを持つ知らせが出て、取り消すと消える")
    func removalNotice() throws {
        let fixture = Fixture()
        let preferences = fixture.preferences
        preferences.savePrintSettingSet(fixture.set("配布用", layoutID: "a4Duplex"))
        let set = try #require(preferences.printSettingSets.first)
        SettingSetRemoval.delete(set.id, from: preferences, history: nil)
        let notice = try #require(preferences.removedPrintSettingSet)
        #expect(notice.set.name == "配布用")
        #expect(notice.index == 0)
        SettingSetRemoval.undo(notice, in: preferences, history: nil)
        #expect(preferences.printSettingSets == [set])
        #expect(preferences.removedPrintSettingSet == nil)
    }

    @Test("同じ名前の設定セットを保存し直したあとは、削除を取り消しても新しい方を残す")
    func restoreKeepsNewerSet() throws {
        let fixture = Fixture()
        let preferences = fixture.preferences
        preferences.savePrintSettingSet(fixture.set("One", layoutID: "a4Single"))
        let removal = try #require(preferences.removePrintSettingSet(preferences.printSettingSets[0].id))
        preferences.savePrintSettingSet(fixture.set("One", layoutID: "a4Duplex"))
        #expect(!preferences.restorePrintSettingSet(removal))
        #expect(preferences.printSettingSets.map(\.layoutID) == ["a4Duplex"])
    }

    @Test("設定の窓の取り消しで設定セットが戻り、やり直すともう一度消える")
    func settingSetHistory() throws {
        let fixture = Fixture()
        let preferences = fixture.preferences
        preferences.savePrintSettingSet(fixture.set("One", layoutID: "a4Single"))
        preferences.savePrintSettingSet(fixture.set("Two", layoutID: "a4Duplex"))
        let sets = preferences.printSettingSets
        let undo = UndoManager()
        step(undo) { SettingSetRemoval.delete(sets[0].id, from: preferences, history: undo) }
        #expect(preferences.printSettingSets == [sets[1]])
        undo.undo()
        #expect(preferences.printSettingSets == sets)
        #expect(preferences.removedPrintSettingSet == nil)
        undo.redo()
        #expect(preferences.printSettingSets == [sets[1]])
    }
}

import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct NotePagesFlowTests {
    @MainActor private struct Environment {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var preferences: AppPreferences { AppPreferences(defaults: suite.defaults) }
        var store: DocumentSettingsStore {
            DocumentSettingsStore(directory: directory.appendingPathComponent("Settings"))
        }

        func model(
            _ label: String = "本文", format: DocumentFormat = .markdown, preferences: AppPreferences? = nil
        ) -> DocumentViewModel {
            DocumentViewModel(
                data: Data(label.utf8), fileURL: nil, format: format, preferences: preferences ?? self.preferences,
                library: UserLibrary(root: directory.appendingPathComponent("Library")),
                renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: TestFixtures.pdf("Notes", pages: 1))! }),
                settingsStore: store)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out")
    }

    @Test("ノートは既定でオフで、何も変えなければ文書の記録に残らない")
    func offByDefault() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        #expect(!model.notes.isEnabled)
        #expect(try #require(model.renderSettings).notes == NotePages())
        #expect(model.rememberedSettings.notes == nil)
    }

    @Test("ノートは刷り台だけに載り、読むときの紙には入らない")
    func printModeOnly() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        model.notes.isEnabled = true
        #expect(try #require(model.renderSettings).notes == NotePages())
        model.mode = .print
        #expect(try #require(model.renderSettings).notes.isEnabled)
        model.mode = .compare
        #expect(try #require(model.renderSettings).notes == NotePages())
    }

    @Test("PDF にも画像にもテキストにもノートを選べる", arguments: [DocumentFormat.pdf, .image, .html, .markdown, .plainText])
    func everyFormat(format: DocumentFormat) {
        let environment = Environment()
        defer { environment.cleanUp() }
        #expect(environment.model(format: format).offersNotes)
    }

    @Test("文書の記録にノートを残し、同じ内容を開くと戻る")
    func documentRecord() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let first = environment.model("ノートの記録")
        first.start()
        try await waitUntil { first.contentHash != nil }
        first.notes.isEnabled = true
        first.notes.placement = .chapterEnd
        first.notes.style.spacingInMillimeters = 9
        first.rememberedSettingsDidChange()
        let key = try #require(first.contentHash).hex
        try await waitUntil { environment.store.record(for: key)?.notes != nil }
        let second = environment.model("ノートの記録")
        second.start()
        try await waitUntil { second.contentHash != nil }
        #expect(second.notes.isEnabled)
        #expect(second.notes.placement == .chapterEnd)
        #expect(second.notes.style.spacingInMillimeters == 9)
    }

    @Test("冊子の 1 ページ目がノートになるとき、そうと分かる")
    func coverNote() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        model.chooseLayout("a4BookletA5")
        model.notes.isEnabled = true
        model.notes.placement = .spreadRight
        model.start()
        try await waitUntil { model.hasCurrentPrintPreview && !model.isRendering }
        #expect(model.coverIsNotePage)
        model.notes.placement = .spreadLeft
        model.render()
        try await waitUntil {
            model.hasCurrentPrintPreview && !model.isRendering && model.renderedSettings?.notes.placement == .spreadLeft
        }
        #expect(!model.coverIsNotePage)
    }

    @Test("既定に戻すとノートも切れる")
    func reset() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        model.notes.isEnabled = true
        model.resetDocumentSettings()
        #expect(model.notes == NotePages())
    }

    @Test("プリセットを選ぶと線がそのプリセットになり、線を変えると変更ありになる")
    func choosingPreset() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        let preset = try #require(NotePaperPreset.preset(id: "hougan"))
        model.chooseNotePreset(id: preset.id, style: preset.style)
        #expect(model.notes.style == preset.style)
        #expect(!model.isNoteStyleChanged)
        model.notes.style.spacingInMillimeters = 7
        #expect(model.isNoteStyleChanged)
    }

    @Test("自分のプリセットは保存して上書きでき、次の起動でも残る")
    func ownPresets() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let model = environment.model(preferences: preferences)
        model.notes.style.spacingInMillimeters = 6
        model.saveNotePreset(named: "  週報  ")
        let saved = try #require(preferences.notePresets.first)
        #expect(saved.name == "週報")
        #expect(model.notes.presetID == saved.id)
        #expect(!model.isNoteStyleChanged)

        model.notes.style.spacingInMillimeters = 8
        #expect(model.isNoteStyleChanged)
        model.overwriteNotePreset()
        #expect(preferences.notePresets.first?.style.spacingInMillimeters == 8)
        #expect(preferences.notePresets.count == 1)
        #expect(!model.isNoteStyleChanged)

        let reopened = environment.preferences
        #expect(reopened.notePresets == preferences.notePresets)
    }

    @Test("組み込みのプリセットは上書きできない")
    func builtInsStay() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let model = environment.model(preferences: preferences)
        model.notes.style.spacingInMillimeters = 3
        model.overwriteNotePreset()
        preferences.overwriteNotePreset("daigaku", style: model.notes.style)
        #expect(preferences.notePresets.isEmpty)
        #expect(try #require(NotePaperPreset.preset(id: "daigaku")).style.spacingInMillimeters == 7)
    }

    @Test("名前が空の保存は次の番号の名前になり、壊れた記録は他を失わない")
    func namesAndBrokenRecords() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        preferences.saveNotePreset(named: "   ", style: NotePaperStyle())
        #expect(preferences.notePresets.first?.name.isEmpty == false)
        let saved = try #require(environment.suite.defaults.data(forKey: "notePresets"))
        var items = try #require(try JSONSerialization.jsonObject(with: saved) as? [Any])
        items.append(["id": 12])
        environment.suite.defaults.set(try JSONSerialization.data(withJSONObject: items), forKey: "notePresets")
        #expect(environment.preferences.notePresets.count == 1)
    }

    @Test("使っていた自分のプリセットを消しても文書の線は残る")
    func removedPreset() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let model = environment.model(preferences: preferences)
        model.notes.style.spacingInMillimeters = 6
        model.saveNotePreset(named: "週報")
        model.removeNotePreset(try #require(model.notes.presetID))
        #expect(model.notes.style.spacingInMillimeters == 6)
        #expect(model.notePresetName == nil)
        #expect(!model.isNoteStyleChanged)
    }

    @Test("設定セットはノートを保存して当てられ、ノートなしのセットを当てると切れる")
    func settingSets() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let model = environment.model(preferences: preferences)
        model.notes.isEnabled = true
        model.notes.placement = .duplexBack
        model.savePrintSettingSet(named: "ノートつき")
        let set = try #require(preferences.printSettingSets.first)
        #expect(model.matchesPrintSettingSet(set))
        model.notes = NotePages()
        #expect(!model.matchesPrintSettingSet(set))
        model.applyPrintSettingSet(set)
        #expect(model.notes.isEnabled)
        #expect(model.notes.placement == .duplexBack)
        let builtIn = try #require(PrintSettingSet.builtIns(language: "ja").last)
        model.applyPrintSettingSet(builtIn)
        #expect(model.notes == NotePages())

        model.savePrintSettingSet(named: "ノートなし")
        let plain = try #require(preferences.printSettingSets.last)
        model.notes.isEnabled = true
        #expect(!model.matchesPrintSettingSet(plain))
        model.applyPrintSettingSet(plain)
        #expect(!model.notes.isEnabled)
    }

    @Test("組み込みのプリセットの名前と色の名前はすべて文字列カタログにある")
    func catalogNames() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Localizable.xcstrings")
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        for name in NotePaperPreset.all.map(\.englishName) + NotePaperStyle.palette.map(\.name) {
            #expect(strings[name] != nil, "\(name)")
        }
    }
}

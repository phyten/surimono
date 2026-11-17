import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct PrintSettingSetFlowTests {
    @MainActor private struct Environment {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var preferences: AppPreferences { AppPreferences(defaults: suite.defaults) }
        var store: DocumentSettingsStore {
            DocumentSettingsStore(directory: directory.appendingPathComponent("Settings"))
        }

        func model(_ label: String, format: DocumentFormat = .markdown, preferences: AppPreferences)
            -> DocumentViewModel
        {
            DocumentViewModel(
                data: Data(label.utf8), fileURL: nil, format: format, preferences: preferences,
                library: UserLibrary(root: directory.appendingPathComponent("Library")),
                renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: TestFixtures.pdf("Set", pages: 1))! }),
                settingsStore: store)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
    }

    @Test("合本の設定セットはテーマと文字サイズとHTMLプリセットを保存し再適用する")
    func binderSettings() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf, preferences: environment.preferences,
            library: UserLibrary(root: environment.directory.appendingPathComponent("Library")),
            settingsStore: environment.store,
            binder: BinderModel(urls: [URL(fileURLWithPath: "/fixture/a.md"), URL(fileURLWithPath: "/fixture/b.html")]))
        defer { model.stop() }
        let preset = try #require(model.library.presets.first { $0.id != "none" })
        model.themeID = "mincho"
        model.setTextScale(1.5)
        model.presetID = preset.id
        model.savePrintSettingSet(named: "Mixed")
        let set = try #require(model.preferences.printSettingSets.first)
        #expect(set.themeID == "mincho" && set.textScale == 1.5 && set.presetID == preset.id)
        #expect(model.matchesPrintSettingSet(set))
        model.themeID = "standard"
        #expect(!model.matchesPrintSettingSet(set))
        model.applyPrintSettingSet(set)
        #expect(model.themeID == "mincho" && model.matchesPrintSettingSet(set))
        model.setTextScale(1)
        #expect(!model.matchesPrintSettingSet(set))
        model.applyPrintSettingSet(set)
        #expect(model.textScale == 1.5 && model.matchesPrintSettingSet(set))
        model.presetID = "none"
        #expect(!model.matchesPrintSettingSet(set))
        model.applyPrintSettingSet(set)
        #expect(model.presetID == preset.id && model.matchesPrintSettingSet(set))
    }

    @Test("テキストを含む合本に仕上げのあるセットを当てても、直後は変更ありにならず改ページも持ち込まない")
    func binderIgnoresFinish() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf, preferences: environment.preferences,
            library: UserLibrary(root: environment.directory.appendingPathComponent("Library")),
            settingsStore: environment.store,
            binder: BinderModel(urls: [URL(fileURLWithPath: "/fixture/a.md"), URL(fileURLWithPath: "/fixture/b.md")]))
        defer { model.stop() }
        for set in PrintSettingSet.builtIns(language: model.language) {
            model.applyPrintSettingSet(set)
            #expect(model.matchesPrintSettingSet(set))
            #expect(!model.isSettingSetChanged)
            #expect(model.printFinish == PrintFinish())
        }
    }

    @Test("別の文書へ設定セットを当てると印刷の設定が変わり内容のハッシュで保存される", .timeLimit(.minutes(1)))
    func applyAndRemember() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let first = environment.model("First", preferences: preferences)
        first.layoutID = "a4BookletA5"
        first.themeID = "mincho"
        first.setTextScale(1.25)
        first.paperOrientation = .landscape
        first.printOptions = PrintOptions(marginsInMillimeters: 10, showsPageNumbers: true)
        first.savePrintSettingSet(named: "Book")
        let saved = try #require(preferences.printSettingSets.first)
        let second = environment.model("Second", preferences: preferences)
        defer { second.stop() }
        second.start()
        for _ in 0..<500 where second.contentHash == nil || second.isRendering {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(second.contentHash != nil)
        #expect(!second.hasSavedSettings)
        second.printerListSource = { PrinterList(names: ["A"], defaultName: "A") }
        second.refreshPrinters()
        preferences.setPrinterRotation(true, for: "A", duplex: .shortEdge)
        let view = second.viewOptions
        second.zoom = 2
        second.applyPrintSettingSet(saved)
        #expect(second.layoutID == "a4BookletA5")
        #expect(second.themeID == "mincho" && second.textScale == 1.25)
        #expect(second.paperOrientation == .landscape)
        #expect(
            second.printOptions
                == PrintOptions(marginsInMillimeters: 10, showsPageNumbers: true)
        )
        #expect(second.rotatesBackSides)
        #expect(second.viewOptions == view && second.zoom == 2)
        #expect(second.matchesPrintSettingSet(saved))
        for _ in 0..<500 where !second.hasSavedSettings { try await Task.sleep(for: .milliseconds(20)) }
        #expect(second.hasSavedSettings)
        let record = try #require(environment.store.record(for: ContentHash.of(Data("Second".utf8)).hex))
        #expect(record.layoutID == "a4BookletA5")
        #expect(record.themeID == "mincho" && record.textScale == 1.25)
        #expect(record.printOptions?.marginsInMillimeters == 10)
        #expect(record.printOptions?.rotatesBackSides == false)
    }

    @Test("テーマを使わない文書にはテーマと文字の大きさを当てない", arguments: [DocumentFormat.pdf, .image, .html, .zipArchive])
    func nonThemedFormats(format: DocumentFormat) {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model("Other", format: format, preferences: environment.preferences)
        let set = PrintSettingSet(
            name: "Theme", settings: DocumentSettings(layoutID: "a4Duplex", themeID: "mincho", textScale: 1.5))
        model.applyPrintSettingSet(set)
        #expect(model.themeID == "standard" && model.textScale == 1)
        #expect(model.layoutID == "a4Duplex")
        #expect(model.matchesPrintSettingSet(set))
        model.savePrintSettingSet(named: "Other")
        #expect(model.preferences.printSettingSets.first?.themeID == nil)
        #expect(model.preferences.printSettingSets.first?.textScale == nil)
    }

    @Test("消えたテーマとレイアウトだけを飛ばし最近使ったスタイルには記録しない")
    func unavailableIDsAndRecentThemes() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model("Missing", preferences: environment.preferences)
        let set = PrintSettingSet(
            name: "Missing", settings: DocumentSettings(layoutID: "missing", themeID: "missing", textScale: 1.5))
        model.applyPrintSettingSet(set)
        #expect(model.themeID == "standard" && model.layoutID == "a4Single")
        #expect(model.textScale == 1.5)
        #expect(model.matchesPrintSettingSet(set))
        model.applyPrintSettingSet(PrintSettingSet(name: "Valid", settings: DocumentSettings(themeID: "mincho")))
        #expect(model.themeID == "mincho")
        #expect(model.preferences.recentThemeIDs.isEmpty)
    }

    @Test("HTML のプリセットだけを保存しスマート削除と表示方法は当てても変わらない")
    func htmlPreset() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model("HTML", format: .html, preferences: environment.preferences)
        let preset = try #require(model.library.presets.first { $0.id != "none" })
        model.presetID = preset.id
        model.savePrintSettingSet(named: "Article")
        let set = try #require(model.preferences.printSettingSets.first)
        #expect(set.presetID == preset.id && set.themeID == nil)
        model.presetID = "none"
        model.isSmartRemovalEnabled = true
        model.smartRemovalKeptIDs = ["keep"]
        model.applyPrintSettingSet(set)
        #expect(model.presetID == preset.id)
        #expect(model.isSmartRemovalEnabled && model.smartRemovalKeptIDs == ["keep"])
        #expect(model.htmlPresentation == .web)
        var missing = set
        missing.presetID = "missing"
        model.applyPrintSettingSet(missing)
        #expect(model.presetID == preset.id)
    }

    @Test("同名の上書きは識別子と作成順を保ち名前変更と削除も永続化する")
    func persistenceAndManagement() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let model = environment.model("Save", preferences: preferences)
        model.savePrintSettingSet(named: "One")
        model.savePrintSettingSet(named: "Two")
        let first = try #require(preferences.printSettingSets.first)
        model.layoutID = "a4Duplex"
        model.savePrintSettingSet(named: " One ")
        let reloaded = environment.preferences
        #expect(reloaded.printSettingSets.map(\.name) == ["One", "Two"])
        #expect(reloaded.printSettingSets[0].id == first.id)
        #expect(reloaded.printSettingSets[0].layoutID == "a4Duplex")
        #expect(!reloaded.renamePrintSettingSet(first.id, to: "Two"))
        #expect(!reloaded.renamePrintSettingSet(first.id, to: "  "))
        #expect(reloaded.renamePrintSettingSet(first.id, to: "Renamed"))
        #expect(environment.preferences.printSettingSets.map(\.name) == ["Renamed", "Two"])
        reloaded.removePrintSettingSet(first.id)
        #expect(environment.preferences.printSettingSets.map(\.name) == ["Two"])
    }

    @Test("保存時の既定名は空でなく既存の名前と重ならない")
    func numberedName() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let first = preferences.nextPrintSettingSetName
        #expect(!first.isEmpty)
        preferences.savePrintSettingSet(PrintSettingSet(name: first, settings: DocumentSettings()))
        #expect(preferences.nextPrintSettingSetName != first)
    }

    @Test("セットにない項目は当てても現在の値を保つ")
    func partialSet() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model("Partial", preferences: environment.preferences)
        model.setTextScale(1.75)
        model.themeID = "mincho"
        model.printerListSource = { PrinterList(names: ["A"], defaultName: "A") }
        model.refreshPrinters()
        model.preferences.setPrinterRotation(true, for: "A", duplex: .longEdge)
        let before = model.rememberedSettings
        model.applyPrintSettingSet(PrintSettingSet(name: "Layout", settings: DocumentSettings(layoutID: "a4Duplex")))
        var expected = before
        expected.layoutID = "a4Duplex"
        #expect(model.rememberedSettings == expected)
    }

    @Test("選ばなかった余白とスタイルは適用も一致判定もせず上書きでも追加しない")
    func selectedParts() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model("Parts", preferences: environment.preferences)
        defer { model.stop() }
        model.savePrintSettingSet(named: "Layout", parts: [.layout])
        let set = try #require(model.preferences.printSettingSets.first)
        model.printOptions.linksMargins = false
        model.themeID = "mincho"
        model.applyPrintSettingSet(set)
        #expect(!model.printOptions.linksMargins)
        #expect(model.themeID == "mincho")
        #expect(model.matchesPrintSettingSet(set))
        model.overwriteActiveSettingSet()
        #expect(model.preferences.printSettingSets.first?.parts == [.layout])
    }

    @Test("並べ替えた設定セットの順は再読み込みしても残る")
    func reorder() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        for name in ["One", "Two", "Three"] {
            preferences.savePrintSettingSet(
                PrintSettingSet(name: name, settings: DocumentSettings(layoutID: "a4Single")))
        }
        preferences.movePrintSettingSets(from: IndexSet(integer: 0), to: 3)
        #expect(environment.preferences.printSettingSets.map(\.name) == ["Two", "Three", "One"])
        preferences.movePrintSettingSets(from: IndexSet([1, 2]), to: 0)
        #expect(environment.preferences.printSettingSets.map(\.name) == ["Three", "One", "Two"])
    }

    @Test("配列の壊れた要素や重複だけを捨て読める設定セットを残す")
    func lossyArray() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let first = PrintSettingSet(name: "One", settings: DocumentSettings(layoutID: "a4Duplex"))
        let second = PrintSettingSet(name: "Two", settings: DocumentSettings(themeID: "mincho"))
        let firstJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))
        let secondJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(second))
        let data = try JSONSerialization.data(withJSONObject: [firstJSON, 3, ["name": "Broken"], firstJSON, secondJSON])
        environment.suite.defaults.set(data, forKey: "printSettingSets")
        #expect(environment.preferences.printSettingSets == [first, second])
    }
}

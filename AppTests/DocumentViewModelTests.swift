import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct DocumentViewModelTests {
    @Test("表示と見比べ台は印刷レイアウトに関係なく A4 片面で組む", arguments: [ViewerMode.view, .compare])
    func readingLayoutIgnoresPrintLayout(mode: ViewerMode) throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.layoutID = PrintLayout.a4BookletA5.id
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown, preferences: preferences,
            library: UserLibrary(root: directory))
        defer { model.stop() }
        model.mode = mode
        model.paperOrientation = .landscape
        model.setMargins(12)
        model.setTextScale(1.25)
        model.selectTheme("mincho")
        for layout in PrintLayout.presets {
            model.layoutID = layout.id
            let settings = try #require(model.renderSettings)
            #expect(settings.layout == .a4Single)
            #expect(settings.paperOrientation == .landscape)
            #expect(settings.options.marginsInMillimeters == 12)
            #expect(settings.textScale == 1.25)
            #expect(settings.theme.id == "mincho")
            #expect(model.layoutID == layout.id)
        }
        #expect(preferences.layoutID == "a4BookletA5")
    }

    @Test("刷り台だけは選んだ印刷レイアウトで組み、表示へ戻ると A4 片面に戻す")
    func printModeUsesRememberedLayout() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory))
        defer { model.stop() }
        for layout in PrintLayout.presets {
            model.layoutID = layout.id
            model.enterPrintMode()
            #expect(model.renderSettings?.layout == layout)
            model.exitPrintMode()
            #expect(model.renderSettings?.layout == .a4Single)
            #expect(model.layoutID == layout.id)
        }
    }

    @Test("表示では冊子やメモ用紙を選んでいても余白と用紙の向きを変えられる")
    func readingControlsUseReadingLayout() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory))
        defer { model.stop() }
        model.paperOrientation = .landscape
        for layout in [PrintLayout.a4BookletA5, .a4Handout3] {
            model.layoutID = layout.id
            #expect(model.marginsApply)
            #expect(!PaperOrientationControl(model: model).isFixed)
            #expect(PaperOrientationControl(model: model).value == "Landscape")
            model.enterPrintMode()
            #expect(PaperOrientationControl(model: model).isFixed)
            #expect(model.marginsApply == (layout == .a4BookletA5))
            model.exitPrintMode()
        }
    }

    @Test(
        "縦23枚と回転した横1枚のPDFは印刷レイアウトによらず縦A4を窓の基準にする", .timeLimit(.minutes(1)),
        arguments: [PrintLayout.a4Single, .a4BookletA5, .a4Handout3])
    func mixedPaperUnitSize(layout: PrintLayout) async throws {
        let document = try #require(PDFDocument(data: TestFixtures.pdf("mixed", pages: 24)))
        document.page(at: 16)?.rotation = 90
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = DocumentViewModel(
            data: try #require(document.dataRepresentation()), fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        defer { model.stop() }
        model.layoutID = layout.id
        model.render()
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        model.viewOptions.layout = .single
        #expect(model.paperUnitSize == CGSize(width: 595, height: 842))
        model.viewOptions.layout = .spread
        #expect(model.paperUnitSize == CGSize(width: 1190, height: 842))
    }

    @Test("文書形式に合うテーマとプリセットだけを描画要求に反映する")
    func renderSettings() throws {
        let library = UserLibrary(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.themeID = "mincho"
        preferences.presetID = "clean"
        preferences.allowsJavaScript = true
        preferences.margin = 12
        for format in DocumentFormat.allCases {
            let model = DocumentViewModel(
                data: Data(), fileURL: nil, format: format, preferences: preferences, library: library)
            let settings = try #require(model.renderSettings)
            #expect(settings.theme.id == (format.usesPrintTheme ? "mincho" : "standard"))
            #expect(settings.preset.id == (format.usesHTMLPreset ? "clean" : "none"))
            #expect(settings.allowsJavaScriptInHTML)
            #expect(settings.options.marginsInMillimeters == 12)
        }
    }

    @Test("ウィンドウで選んだレイアウトは既定値や別の文書を変えない")
    func windowDefaults() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let library = UserLibrary(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let first = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf, preferences: preferences, library: library)
        let second = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf, preferences: preferences, library: library)
        first.layoutID = "a3BookletA4"
        #expect(second.layoutID == "a4Single")
        #expect(preferences.layoutID == "a4Single")
    }

    @Test("冊子の要約は論理ページ数と用紙枚数と短辺綴じを示す")
    func summary() {
        let summary = PrintSummary(plan: Imposition.plan(pageCount: 12, layout: .a3BookletA4))
        #expect(
            DocumentViewModel.summaryText(summary, layout: .a3BookletA4, locale: Locale(identifier: "ja"))
                == "12 ページ → A3 3 枚（両面・短辺綴じ）")
        #expect(
            DocumentViewModel.summaryText(summary, layout: .a3BookletA4, locale: Locale(identifier: "en"))
                == "12 pages → A3 3 sheets (Duplex, short edge)")
    }

    @Test("開いている文書へのPDF書き出しは相対要素を含むパスでも拒否する")
    func protectsSources() {
        let source = URL(fileURLWithPath: "/tmp/original.pdf")
        #expect(!DocumentViewModel.canExport(to: source, sourceURLs: [source]))
        #expect(
            !DocumentViewModel.canExport(
                to: URL(fileURLWithPath: "/tmp/folder/../original.pdf"), sourceURLs: [source]))
        #expect(
            DocumentViewModel.canExport(
                to: URL(fileURLWithPath: "/tmp/export.pdf"), sourceURLs: [source]))
    }

    @Test("開いた文書のハードリンクにも書き出さない")
    func protectsLinkedSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        let linked = directory.appendingPathComponent("linked.pdf")
        try Data("test".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: linked)
        #expect(!DocumentViewModel.canExport(to: linked, sourceURLs: [source]))
    }

    @Test("PDF書き出し名は元の名前と選択したレイアウトを含む")
    func exportName() {
        #expect(
            DocumentViewModel.exportName(
                fileURL: URL(fileURLWithPath: "/tmp/notes.md"), layout: .a4Single, language: "ja")
                == "notes（A4 片面）.pdf")
    }

}

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

        var locations: KeyedRecordStore<ContentHash> {
            KeyedRecordStore(directory: directory.appendingPathComponent("DocumentLocations"))
        }

        func file(_ bytes: Data, named name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            return url
        }

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

    @Test("縦書きの右から左へのページ送りと冊子の右とじは既定で、文書に保存した向きととじ側を優先する")
    func verticalReadingOrder() throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        let model = DocumentViewModel(
            data: Data("本文".utf8), fileURL: nil, format: .org,
            preferences: fixture.preferences, library: fixture.library, settingsStore: fixture.store)
        model.layoutID = PrintLayout.a4BookletA5.id
        model.selectTheme("tategaki")
        #expect(model.viewOptions.direction == .rightToLeft)
        #expect(model.viewOptions.scrollAxis == .horizontal)
        #expect(model.layout.bookletBinding == .right)
        #expect(model.bookletBinding == nil)
        model.selectTheme("standard")
        #expect(model.viewOptions.direction == .leftToRight)
        var saved = model.rememberedSettings
        saved.bookletBinding = .left
        saved.themeID = "tategaki"
        model.restoreClosedDocument(saved)
        #expect(model.viewOptions.direction == .leftToRight)
        #expect(model.layout.bookletBinding == .left)
        model.selectTheme("standard")
        model.selectTheme("tategaki")
        #expect(model.viewOptions.direction == .leftToRight)
    }

    @Test(
        "LaTeXは文書クラスに合う既定スタイルで開き、明示的に選んだスタイルだけを記憶する", .timeLimit(.minutes(1)),
        arguments: [
            ("ctexart", "latex-plain-zh"), ("oblivoir", "latex-plain-ko"), ("article", "latex-article"),
            ("book", "latex-report"), ("report", "latex-report"),
            ("jsarticle", "latex-plain-ja"), ("ltjsreport", "latex-plain-ja"), ("ltjsbook", "latex-plain-ja"),
        ])
    func latexClassStyle(documentClass: String, expected: String) async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        fixture.preferences.themeID = "compact"
        let bytes = Data("\\documentclass{\(documentClass)}\\begin{document}Body\\end{document}".utf8)
        let page = pdf("Body", pages: 1)
        func makeModel(_ format: DocumentFormat) -> DocumentViewModel {
            DocumentViewModel(
                data: bytes, fileURL: nil, format: format, preferences: fixture.preferences,
                library: fixture.library,
                renderer: DocumentRenderer(paginate: { _ in try #require(PDFDocument(data: page)) }),
                settingsStore: fixture.store)
        }
        let original = makeModel(.latex)
        try await open(original)
        #expect(original.themeID == expected)
        original.rememberedSettingsDidChange()
        original.flushPendingSettings()
        #expect(fixture.store.keys().isEmpty)
        #expect(fixture.preferences.recentThemeIDs.isEmpty)
        original.selectTheme("latex-report" == expected ? "latex-article" : "latex-report")
        original.rememberedSettingsDidChange()
        original.flushPendingSettings()
        #expect(original.hasSavedSettings)
        original.stop()
        let restored = makeModel(.latex)
        defer { restored.stop() }
        try await open(restored)
        #expect(restored.themeID == original.themeID)
        // A clipboard document may reinterpret exactly the same bytes, and so encounter the same saved record.
        let markdown = makeModel(.markdown)
        defer { markdown.stop() }
        try await open(markdown)
        #expect(markdown.themeID == "compact")
        #expect(!markdown.availableThemes.contains { $0.id == original.themeID })
    }

    @Test("別ファイルの文書クラスを既定に使い、前置きだけを変えて読み直しても設定を保存しない", .timeLimit(.minutes(1)))
    func includedClassStyle() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        let bytes = Data(#"\input{preamble}\begin{document}Body\end{document}"#.utf8)
        let main = try fixture.file(bytes, named: "main.tex")
        let preamble = try fixture.file(Data(#"\documentclass{ltjsarticle}"#.utf8), named: "preamble.tex")
        let page = pdf("Body", pages: 1)
        let renderer = DocumentRenderer(
            isSandboxed: { false }, paginate: { _ in try #require(PDFDocument(data: page)) })
        let model = DocumentViewModel(
            data: bytes, fileURL: main, format: .latex, preferences: fixture.preferences,
            library: fixture.library, renderer: renderer, settingsStore: fixture.store)
        defer { model.stop() }
        try await open(model)
        #expect(model.themeID == "latex-plain-ja")
        try Data(#"\documentclass{report}"#.utf8).write(to: preamble)
        model.reload()
        try await waitUntil { model.themeID == "latex-report" && !model.isRendering }
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        #expect(fixture.store.keys().isEmpty)
        #expect(fixture.preferences.recentThemeIDs.isEmpty)
    }

    @Test("LaTeX の既定の余白と柱は保存せず、明示した同じ数値と「なし」は開き直しても優先する", .timeLimit(.minutes(1)))
    func latexPageChoices() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        fixture.preferences.margin = 17
        let bytes = Data(
            #"\documentclass[a4paper]{article}\usepackage[margin=24mm]{geometry}\begin{document}Body\end{document}"#
                .utf8)
        let page = pdf("Body", pages: 1)
        func makeModel() -> DocumentViewModel {
            DocumentViewModel(
                data: bytes, fileURL: nil, format: .latex, preferences: fixture.preferences, library: fixture.library,
                renderer: DocumentRenderer(paginate: { _ in try #require(PDFDocument(data: page)) }),
                settingsStore: fixture.store)
        }

        let first = makeModel()
        try await open(first)
        #expect(first.usesDocumentMargins)
        #expect(first.usesDocumentFurniture)
        #expect(abs((first.result?.options.margins.top ?? 0) - 24) < 0.001)
        #expect(first.result?.furniture == .pageNumber)
        first.rememberedSettingsDidChange()
        first.flushPendingSettings()
        #expect(fixture.store.keys().isEmpty)

        first.selectTheme("standard")
        #expect(!first.usesDocumentMargins)
        #expect(!first.usesDocumentFurniture)
        first.selectTheme("latex-article")
        first.setMargins(17)
        first.chooseFurniture(.none)
        first.rememberedSettingsDidChange()
        first.flushPendingSettings()
        first.stop()

        let second = makeModel()
        defer { second.stop() }
        try await open(second)
        #expect(second.hasSavedSettings)
        #expect(!second.usesDocumentMargins)
        #expect(!second.usesDocumentFurniture)
        #expect(second.printOptions.margins == .uniform(17))
        #expect(second.printOptions.furniture.isEmpty)
        second.resetDocumentSettings()
        #expect(second.usesDocumentMargins)
        #expect(second.usesDocumentFurniture)
        #expect(fixture.store.keys().isEmpty)
        #expect(fixture.preferences.margin == 17)
    }

    @Test("前置きのフォルダーを許可すると余白とクラスが更新され、文書の設定は作られない", .timeLimit(.minutes(1)))
    func latexPageAfterFolderGrant() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        let bytes = Data(#"\input{layout}\begin{document}Body\end{document}"#.utf8)
        let main = try fixture.file(bytes, named: "main.tex")
        _ = try fixture.file(
            // Same paper as the app prints on, so the document's margins apply exactly.
            Data(#"\documentclass[a4paper]{report}\usepackage[top=19mm,bottom=25mm]{geometry}"#.utf8),
            named: "layout.tex")
        let page = pdf("Body", pages: 1)
        let model = DocumentViewModel(
            data: bytes, fileURL: main, format: .latex, preferences: fixture.preferences, library: fixture.library,
            renderer: DocumentRenderer(isSandboxed: { true }, paginate: { _ in try #require(PDFDocument(data: page)) }),
            settingsStore: fixture.store)
        defer { model.stop() }
        try await open(model)
        #expect(model.themeID == "latex-article")
        model.useDocumentFolder(FolderAccess.Lease(url: fixture.directory, release: {}))
        model.render()
        try await waitUntil { !model.isRendering && model.themeID == "latex-report" }
        let margins = try #require(model.result?.options.margins)
        #expect(abs(margins.top - 19) < 0.001)
        #expect(abs(margins.bottom - 25) < 0.001)
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        #expect(fixture.store.keys().isEmpty)
    }

    @Test("設定セットは余白と柱を個別に切り替え、混合余白を文書指定と取り違えない")
    func latexPageSettingSet() throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        let model = DocumentViewModel(
            data: Data(#"\documentclass{article}\begin{document}Body\end{document}"#.utf8), fileURL: nil,
            format: .latex, preferences: fixture.preferences, library: fixture.library, settingsStore: fixture.store)
        let documentSet = model.currentPrintSettingSet.keeping([.margins, .furniture])
        let raw = model.printOptions.margins
        model.setMargins(raw.top)
        model.chooseFurniture(.none)
        #expect(!model.matchesPrintSettingSet(documentSet))
        model.applyPrintSettingSet(documentSet.keeping([.furniture]))
        #expect(!model.usesDocumentMargins)
        #expect(model.usesDocumentFurniture)
        model.applyPrintSettingSet(documentSet)
        #expect(model.matchesPrintSettingSet(documentSet))
        #expect(MarginChoices(model: model, unit: .millimeters).selection == .document)

        var numeric = PrintOptions()
        numeric.margins = PageMargins(top: 10, left: 20, bottom: 30, right: 40)
        numeric.furniture = .name
        let set = PrintSettingSet(name: "Letterhead", settings: DocumentSettings(printOptions: numeric))
        model.applyPrintSettingSet(set)
        #expect(!model.usesDocumentMargins)
        #expect(!model.usesDocumentFurniture)
        #expect(model.printOptions.margins == numeric.margins)
        #expect(model.furnitureChoice == .name)
        #expect(MarginChoices(model: model, unit: .millimeters).selection == nil)
    }

    @Test("文書の指示は既定値とセットに重なり保存や最近使った記録を作らない", .timeLimit(.minutes(1)))
    func documentDirectivesDefaults() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        var options = PrintOptions()
        options.margins = .uniform(7)
        fixture.preferences.savePrintSettingSet(
            PrintSettingSet(
                name: "配布用",
                settings: DocumentSettings(
                    layoutID: PrintLayout.a4Single.id, textScale: 1.5, printOptions: options,
                    paperOrientation: .portrait)))
        let source = Data(
            "---\nsurimono:\n  set: 配布用\n  layout: A4BOOKLETA5\n  orientation: landscape\n  margins: 15mm\n  text-size: 115%\n---\n# Test"
                .utf8)
        let pageData = pdf("Test", pages: 1)
        let model = DocumentViewModel(
            data: source, fileURL: nil, format: .markdown, preferences: fixture.preferences,
            library: fixture.library, renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pageData)! }),
            settingsStore: fixture.store)
        defer { model.stop() }
        try await open(model)
        #expect(model.layoutID == "a4BookletA5")
        #expect(model.paperOrientation == .landscape)
        #expect(model.printOptions.margins == .uniform(15))
        #expect(model.textScale == 1.15)
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        #expect(fixture.store.keys().isEmpty)
        #expect(fixture.preferences.recentThemeIDs.isEmpty)
        model.setTextScale(1.75)
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        #expect(model.hasSavedSettings)
        model.resetDocumentSettings()
        #expect(model.textScale == 1.15)
        #expect(fixture.store.keys().isEmpty)
    }

    @Test("以前に 112.6% で保存したセットを前付けで当てた文書は、セットと一致し記録を作らない", .timeLimit(.minutes(1)))
    func oldFractionalSetThroughFrontMatter() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        fixture.preferences.savePrintSettingSet(
            PrintSettingSet(name: "Old", settings: DocumentSettings(textScale: 1.126)))
        let pageData = pdf("Old", pages: 1)
        let model = DocumentViewModel(
            data: Data("---\nsurimono:\n  set: Old\n---\n# Old set".utf8), fileURL: nil, format: .markdown,
            preferences: fixture.preferences, library: fixture.library,
            renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pageData)! }), settingsStore: fixture.store)
        defer { model.stop() }
        try await open(model)
        #expect(model.textScale == 1.13)
        #expect(model.activeSettingSet?.name == "Old")
        #expect(!model.isSettingSetChanged)
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        #expect(fixture.store.keys().isEmpty)
    }

    @Test("既定の 12.5 mm と 113% で開いた文書は、何も変えなければ保存しない", .timeLimit(.minutes(1)))
    func fineDefaultsAreNotAChange() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        fixture.preferences.margin = 12.5
        fixture.preferences.defaultTextScale = 1.13
        let pageData = pdf("Fine", pages: 1)
        let model = DocumentViewModel(
            data: Data("# Fine".utf8), fileURL: nil, format: .markdown, preferences: fixture.preferences,
            library: fixture.library, renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pageData)! }),
            settingsStore: fixture.store)
        defer { model.stop() }
        try await open(model)
        #expect(model.printOptions.margins == .uniform(12.5))
        #expect(model.textScale == 1.13)
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        #expect(fixture.store.keys().isEmpty)
    }

    @Test("文書に覚えた 12.5 mm と 113% は開き直しても同じ値で、戻すと既定に戻る", .timeLimit(.minutes(1)))
    func fineSettingsRoundTrip() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        let source = Data("# Fine record".utf8)
        let pageData = pdf("Fine", pages: 1)
        func open() async throws -> DocumentViewModel {
            let model = DocumentViewModel(
                data: source, fileURL: nil, format: .markdown, preferences: fixture.preferences,
                library: fixture.library,
                renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pageData)! }),
                settingsStore: fixture.store)
            try await self.open(model)
            return model
        }
        let first = try await open()
        first.setMargins(12.5)
        first.setTextScale(1.13)
        first.rememberedSettingsDidChange()
        first.flushPendingSettings()
        first.stop()
        let record = try #require(fixture.store.record(for: ContentHash.of(source).hex))
        #expect(record.textScale == 1.13)
        #expect(record.printOptions?.margins == .uniform(12.5))

        let second = try await open()
        defer { second.stop() }
        #expect(second.printOptions.margins == .uniform(12.5))
        #expect(second.textScale == 1.13)
        #expect(second.hasSavedSettings)
        second.resetDocumentSettings()
        #expect(second.printOptions.margins == .uniform(15))
        #expect(second.textScale == 1)
    }

    @Test("文字の大きさは 1% 刻みのどの値も選べ、大きく・小さくは次の段階へ進む", .timeLimit(.minutes(1)))
    func textScaleBetweenSteps() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        let model = DocumentViewModel(
            data: Data("# Steps".utf8), fileURL: nil, format: .markdown, preferences: fixture.preferences,
            library: fixture.library, settingsStore: fixture.store)
        defer { model.stop() }
        model.setTextScale(1.13)
        #expect(model.textScale == 1.13)
        model.increaseTextSize()
        #expect(model.textScale == 1.25)
        model.setTextScale(1.13)
        model.decreaseTextSize()
        #expect(model.textScale == 1.1)
        model.setTextScale(1.126)
        #expect(model.textScale == 1.13)
        model.setTextScale(2.5)
        #expect(model.textScale == 1.13)
    }

    @Test("保存済み設定は指示に優先し再読み込みでも利用者の変更を守る", .timeLimit(.minutes(1)))
    func documentDirectivesSaved() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        let source = Data("---\nsurimono:\n  text-size: 115%\n---\n# Test".utf8)
        try fixture.store.save(DocumentSettings(textScale: 1.75), for: ContentHash.of(source).hex)
        let pageData = pdf("Test", pages: 1)
        let model = DocumentViewModel(
            data: source, fileURL: nil, format: .markdown, preferences: fixture.preferences,
            library: fixture.library, renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pageData)! }),
            settingsStore: fixture.store)
        defer { model.stop() }
        try await open(model)
        #expect(model.textScale == 1.75)
        model.replaceContent(Data("---\nsurimono:\n  text-size: 90%\n---\n# Changed".utf8), format: .markdown)
        #expect(model.textScale == 1.75)
    }

    @Test("操作していない文書だけ変更された指示を適用する", .timeLimit(.minutes(1)))
    func documentDirectivesReload() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        let pageData = pdf("Test", pages: 1)
        let model = DocumentViewModel(
            data: Data("---\nsurimono:\n  text-size: 115%\n---\n# Test".utf8),
            fileURL: nil, format: .markdown, preferences: fixture.preferences,
            library: fixture.library, renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: pageData)! }),
            settingsStore: fixture.store)
        defer { model.stop() }
        try await open(model)
        model.replaceContent(Data("---\nsurimono:\n  text-size: 90%\n---\n# Changed".utf8), format: .markdown)
        #expect(model.textScale == 0.9)
        try await waitUntil { !model.isRendering }
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        #expect(fixture.store.keys().isEmpty)
        model.setTextScale(1.5)
        model.replaceContent(Data("---\nsurimono:\n  text-size: 80%\n---\n# Changed again".utf8), format: .markdown)
        #expect(model.textScale == 1.5)
    }

    @Test("文書のスタイル指定はIDと英語名と日本語名を受け取り未知の値は飛ばす", arguments: ["ACADEMIC", "Academic", "論文"])
    func documentDirectiveStyle(_ style: String) throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        let model = DocumentViewModel(
            data: Data("---\nsurimono:\n  style: \(style)\n  layout: unknown\n  set: absent\n---\n# Test".utf8),
            fileURL: nil, format: .markdown, preferences: fixture.preferences, library: fixture.library,
            settingsStore: fixture.store)
        defer { model.stop() }
        model.resetDocumentSettings()
        #expect(model.themeID == "academic")
        #expect(model.layoutID == fixture.preferences.layoutID)
        #expect(fixture.preferences.recentThemeIDs.isEmpty)
        #expect(fixture.store.keys().isEmpty)
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
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        try await waitUntil { window.level == .floating }
        let unit = try #require(model.paperUnitSize)
        let paper = ViewerWindow.initialPaperSize(unit: unit, on: window.screen)
        let content = window.contentRect(forFrameRect: window.frame).size
        #expect(abs(content.height - paper.height - BandRoom.full(for: .split).total) <= 1)
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
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        // A PDF of six portrait pages opens as a left-to-right book with its cover alone.
        #expect(model.viewOptions.layout == .spread && model.viewOptions.showsCoverAlone)
        model.sizeWindowToPaper(initialOnly: true)
        #expect(model.showsNarrowCover)
        func paperRatio() -> CGFloat {
            let content = window.contentRect(forFrameRect: window.frame).size
            return content.width / (content.height - BandRoom.full(for: .split).total)
        }
        let page: CGFloat = 595.0 / 842.0
        #expect(abs(paperRatio() - page) < 0.02)
        // Leave room on the left: a window at the edge of the screen is kept on it rather than at its right edge.
        // The window goes to the right edge of the screen, which leaves all the room there is: from the middle, a
        // small screen (some CI runners') had less than a page's width to the left, and the right edge moved.
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameTopLeftPoint(NSPoint(x: visible.maxX - window.frame.width, y: window.frame.maxY))
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

    @Test("冊子を覚えた文書を開き直すと、表示も刷り台も冊子のページで組む", .timeLimit(.minutes(1)))
    func rememberedBookletShowsOnScreenToo() async throws {
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
        #expect(reopened.renderSettings?.layout == .a4BookletA5)
        // The first pages are laid out before the record is read; DocumentContent lays them out again for the
        // restored settings, which this test does in its place.
        reopened.renderForChangedSettings()
        try await waitUntil { !reopened.isRendering }
        #expect(reopened.renderedSettings?.layout == .a4BookletA5)
        // The tray composes the same pages on first entry.
        reopened.enterPrintMode()
        #expect(reopened.renderSettings?.layout == .a4BookletA5)
        try await waitUntil { reopened.canOutput }
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
        first.enterPrintMode()
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

    @Test("書体を替えると組版と保存設定が変わり、最近使ったスタイルには加わらない", .timeLimit(.minutes(1)))
    func typefaceChange() async throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        let data = Data("Typeface 本文".utf8)
        var embedded: [Bool] = []
        let model = DocumentViewModel(
            data: data, fileURL: nil, format: .markdown, preferences: fixture.preferences, library: fixture.library,
            renderer: DocumentRenderer(paginate: { request in
                if case .html(let html, _) = request.source { embedded.append(html.contains("data:font/ttf;base64,")) }
                return PDFDocument(data: self.pdf("Page"))!
            }), settingsStore: fixture.store)
        defer { model.stop() }
        try await open(model)
        #expect(embedded.last == false)
        #expect(model.typeface == .style && !model.hasSavedSettings)
        model.setTypeface(.latex)
        model.renderForChangedSettings()
        model.rememberedSettingsDidChange()
        try await waitUntil { !model.isRendering && model.hasSavedSettings && embedded.last == true }
        try await waitUntil { fixture.store.record(for: ContentHash.of(data).hex)?.typeface == .latex }
        #expect(fixture.preferences.recentThemeIDs.isEmpty)
    }

    @Test("既定の書体は新しい文書に使い、書体を含まない古い記録はスタイルのまま開く")
    func legacyTypeface() throws {
        let fixture = try environment()
        defer { fixture.cleanUp() }
        fixture.preferences.defaultTypeface = .latex
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .org, preferences: fixture.preferences,
            library: fixture.library, settingsStore: fixture.store)
        #expect(model.typeface == .latex)
        model.restoreClosedDocument(DocumentSettings(textScale: 1.25))
        #expect(model.typeface == .style)
        #expect(model.textScale == 1.25)
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

    @Test("閉じている間に編集したファイルは同じ場所から設定としおりを戻し、新しい内容の記録を作る", .timeLimit(.minutes(1)))
    func restoresSettingsByLocation() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let original = pdf("Before", pages: 4)
        let url = try environment.file(original, named: "draft.pdf")
        let first = environment.model(original, url: environment.directory.appendingPathComponent("./draft.pdf"))
        try await open(first)
        first.setLayout(.single)
        first.layoutID = PrintLayout.a4BookletA5.id
        first.toggleBookmark(page: 3, visiblePages: [3])
        first.rememberedSettingsDidChange()
        first.stop()

        let edited = pdf("After", pages: 2)
        try edited.write(to: url)
        let reopened = environment.model(edited, url: url)
        defer { reopened.stop() }
        try await open(reopened)
        #expect(reopened.hasSavedSettings)
        #expect(reopened.toast == nil)
        #expect(reopened.viewOptions.layout == .single)
        #expect(reopened.layoutID == PrintLayout.a4BookletA5.id)
        #expect(reopened.bookmarkPages == [1])
        let key = ContentHash.of(edited)
        let migrated = try #require(environment.store.record(for: key.hex))
        #expect(migrated == environment.store.record(for: ContentHash.of(original).hex))
        #expect(environment.locations.record(for: ContentHash.of(Data(url.standardizedFileURL.path.utf8)).hex) == key)
    }

    @Test("別の場所で内容も異なる同名ファイルには設定を引き継がない", .timeLimit(.minutes(1)))
    func unrelatedLocation() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let shared = try await sharedRecord(environment)
        shared.first.stop()
        let other = pdf("Other")
        let url = try environment.file(other, named: "elsewhere/doc.pdf")
        let model = environment.model(other, url: url)
        defer { model.stop() }
        try await open(model)
        #expect(!model.hasSavedSettings)
        #expect(model.viewOptions.layout == .spread)
        #expect(environment.locations.keys().count == 1)
    }

    @Test("別々の場所で共有した記録は片方を閉じて編集した後ももう片方の場所から戻る", .timeLimit(.minutes(1)))
    func sharedLocationsSurviveEditing() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let shared = try await sharedRecord(environment)
        shared.first.stop()
        let copy = environment.model(shared.data, url: shared.copyURL)
        try await open(copy)
        #expect(copy.hasSavedSettings)
        copy.stop()

        for (index, url) in [shared.firstURL, shared.copyURL].enumerated() {
            let edited = pdf("Edit \(index)")
            try edited.write(to: url)
            let reopened = environment.model(edited, url: url)
            try await open(reopened)
            #expect(reopened.hasSavedSettings)
            #expect(reopened.viewOptions.layout == .single)
            #expect(environment.store.record(for: ContentHash.of(edited).hex)?.view?.layout == .single)
            reopened.stop()
        }
    }

    @Test("内容の記録は場所の記録より先に使い、その場所を新しい内容へ向ける", .timeLimit(.minutes(1)))
    func contentTakesPrecedence() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let shared = try await sharedRecord(environment)
        shared.first.stop()
        let replacement = pdf("Replacement")
        let hash = ContentHash.of(replacement)
        try environment.store.save(DocumentSettings(zoom: 1.75), for: hash.hex)
        try replacement.write(to: shared.firstURL)
        let model = environment.model(replacement, url: shared.firstURL)
        defer { model.stop() }
        try await open(model)
        #expect(model.zoom == 1.75)
        let key = ContentHash.of(Data(shared.firstURL.standardizedFileURL.path.utf8)).hex
        #expect(environment.locations.record(for: key) == hash)
    }

    @Test("場所の索引と設定のファイル名・本文に元のパスを保存しない", .timeLimit(.minutes(1)))
    func storesOnlyHashedLocation() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let bytes = pdf("Document")
        let url = try environment.file(bytes, named: "private-folder/private-filename.pdf")
        let model = environment.model(bytes, url: url)
        try await open(model)
        model.zoom = 2
        model.rememberedSettingsDidChange()
        model.stop()

        let locations = environment.locations.directory
        let key = ContentHash.of(Data(url.standardizedFileURL.path.utf8)).hex
        let names = try FileManager.default.contentsOfDirectory(atPath: locations.path)
        #expect(names == [key + ".json"])
        let entry = try Data(contentsOf: locations.appendingPathComponent(key + ".json"))
        #expect(try JSONDecoder().decode(String.self, from: entry) == ContentHash.of(bytes).hex)
        for file in try FileManager.default.contentsOfDirectory(
            at: environment.store.directory, includingPropertiesForKeys: nil)
        {
            #expect(file.lastPathComponent == ContentHash.of(bytes).hex + ".json")
            let json = try String(contentsOf: file, encoding: .utf8)
            #expect(!json.contains("private-folder") && !json.contains("private-filename"))
        }
    }

    @Test("メモリ文書は場所を記録せず、異なる内容は知らせを出さずに既定値で開く", .timeLimit(.minutes(1)))
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
        #expect(environment.locations.keys().isEmpty)
    }

    @Test("既定に戻すと保存を消し、表示と印刷の設定を既定値にする", .timeLimit(.minutes(1)))
    func resetRemovesSavedSettings() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let data = pdf("a")
        let url = try environment.file(data, named: "reset.pdf")
        let model = environment.model(data, url: url)
        try await open(model)
        model.setLayout(.single)
        model.layoutID = PrintLayout.a4BookletA5.id
        model.printOptions.furniture = .pageNumber
        model.rememberedSettingsDidChange()
        try await waitUntil { model.hasSavedSettings }
        #expect(environment.locations.keys().count == 1)
        model.resetDocumentSettings()
        #expect(environment.locations.keys().isEmpty)
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

    @Test("容量整理の後に作り直した内容の記録も別の場所から参照されていれば残す", .timeLimit(.minutes(1)))
    func recreatedRecordStillHasAnotherLocation() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let shared = try await sharedRecord(environment)
        shared.first.stop()
        let key = ContentHash.of(shared.data).hex
        try environment.store.removeRecord(for: key)
        let copy = environment.model(shared.data, url: shared.copyURL)
        defer { copy.stop() }
        try await open(copy)
        #expect(!copy.hasSavedSettings)
        copy.zoom = 1.75
        copy.rememberedSettingsDidChange()
        copy.flushPendingSettings()
        _ = try await edit(copy, at: shared.copyURL, in: environment)
        #expect(environment.store.record(for: key)?.zoom == 1.75)
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

    @Test("同じ場所の ZIP を作り直したときは画像の内容がそろう場合だけ並び順を引き継ぐ", .timeLimit(.minutes(1)), arguments: [false, true])
    func editedArchiveOrder(replacesImage: Bool) async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let a = TestFixtures.png(red: 0.1)
        let b = TestFixtures.png(red: 0.6)
        let original = TestFixtures.storedZip([("a.png", a), ("b.png", b)])
        let url = try environment.file(original, named: "photos.zip")
        func model(_ bytes: Data) throws -> DocumentViewModel {
            let archive = try ZipArchive(data: bytes)
            let bundle = ImageBundleModel(
                archive: archive, selection: ZipImageSelection(archive: archive), archiveURL: url)
            return DocumentViewModel(
                data: bytes, fileURL: url, format: .zipArchive, preferences: environment.preferences,
                library: environment.library, imageBundle: bundle, settingsStore: environment.store)
        }
        let first = try model(original)
        try await open(first)
        first.imageBundle?.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        first.zoom = 1.75
        first.rememberedSettingsDidChange()
        first.stop()

        let edited = TestFixtures.storedZip([("a.png", a), ("c.png", replacesImage ? TestFixtures.png(red: 0.9) : b)])
        try edited.write(to: url)
        let reopened = try model(edited)
        defer { reopened.stop() }
        try await open(reopened)
        #expect(reopened.zoom == 1.75)
        #expect(reopened.imageBundle?.items.first?.name == (replacesImage ? "a.png" : "c.png"))
        let record = try #require(environment.store.record(for: ContentHash.of(edited).hex))
        #expect(record.imageOrder == (replacesImage ? nil : [ContentHash.of(b).hex, ContentHash.of(a).hex]))
    }

    @Test("場所から復元した HTML は再検出できた部分だけをスマート削除の残す一覧に引き継ぐ", .timeLimit(.minutes(1)))
    func editedHTMLKeepList() async throws {
        let environment = try environment()
        defer { environment.cleanUp() }
        let original = Data("<p>Before</p>".utf8)
        let url = try environment.file(original, named: "article.html")
        let pages = pdf("Article")
        func model(_ bytes: Data) -> DocumentViewModel {
            let renderer = DocumentRenderer(paginateWithResult: { _ in
                WebPaginator.Result(
                    document: PDFDocument(data: pages)!,
                    preparationResult: ##"[{"id":"#nav","category":"relatedLinks","excerpt":"Links","reason":"nav"}]"##)
            })
            return DocumentViewModel(
                data: bytes, fileURL: url, format: .html, preferences: environment.preferences,
                library: environment.library, renderer: renderer, settingsStore: environment.store)
        }
        let first = model(original)
        try await open(first)
        first.setSmartRemoval(enabled: true)
        first.toggleKeep("#nav")
        first.toggleKeep("#old")
        first.rememberedSettingsDidChange()
        first.stop()

        let edited = Data("<p>After</p>".utf8)
        try edited.write(to: url)
        let reopened = model(edited)
        defer { reopened.stop() }
        try await open(reopened)
        reopened.render()
        try await waitUntil { !reopened.isRendering }
        #expect(reopened.isSmartRemovalEnabled)
        #expect(reopened.smartRemovalKeptIDs == ["#nav"])
        #expect(environment.store.record(for: ContentHash.of(edited).hex)?.smartRemoval?.keptIDs == ["#nav"])
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

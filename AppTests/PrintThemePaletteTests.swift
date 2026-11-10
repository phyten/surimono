import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PrintThemePaletteTests {
    @Test("見本の既定はこの文書で、切り替えは次の起動にも残る")
    func samplePreference() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.themeSampleSource == .document)
        preferences.themeSampleSource = .specimen
        #expect(AppPreferences(defaults: suite.defaults).themeSampleSource == .specimen)
        suite.defaults.set("unknown", forKey: "themeSampleSource")
        #expect(AppPreferences(defaults: suite.defaults).themeSampleSource == .document)
    }

    @Test("吹き出しはテーマのない文書では消費せず、最初の対象文書で一度だけ出す")
    func tipOnce() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(!preferences.takePrintStyleTip(usesPrintTheme: false))
        #expect(!preferences.hasSeenPrintStyleTip)
        #expect(preferences.takePrintStyleTip(usesPrintTheme: true))
        #expect(!preferences.takePrintStyleTip(usesPrintTheme: true))
        #expect(!AppPreferences(defaults: suite.defaults).takePrintStyleTip(usesPrintTheme: true))
    }

    @Test("見本の文書は日本語以外では英語を使い、必要な要素をすべて持つ")
    func specimenLanguages() throws {
        #expect(ThemeSpecimen.markdown(language: "ja-JP").contains("小さな図書室"))
        #expect(ThemeSpecimen.markdown(language: "fr") == ThemeSpecimen.markdown(language: "en"))
        for language in ["ja", "en"] {
            let html = MarkdownConverter.convert(ThemeSpecimen.markdown(language: language)).body
            for tag in ["<h1", "<h2", "<p>", "<ul>", "<table>", "<pre>", "<blockquote>"] {
                #expect(html.contains(tag))
            }
        }
    }

    @Test("刷り台の窓でパレットを開き、乗せても組版せず、選ぶと最近使ったものと用紙が更新される")
    func hostedPrintPalette() async throws {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
        let renderer = DocumentRenderer(paginate: { _ in PDFDocument(data: TestFixtures.pdf("Palette"))! })
        let trial = DocumentRenderer(paginate: { _ in PDFDocument(data: TestFixtures.pdf("Trial"))! })
        let model = DocumentViewModel(
            data: Data("# Own document".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer, trialRenderer: trial)
        defer { model.stop() }
        model.enterPrintMode()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1000, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: DocumentContent(model: model))
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { model.hasCurrentPrintPreview && !model.isRendering }
        let count = renderer.logicalRenderCount
        // What the tray's style button does.
        model.openThemePalette()
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.isThemePalettePresented)
        model.hoverPaletteTheme("mincho")
        await model.paletteSamples.load(try #require(model.theme("mincho")))
        #expect(model.palettePreviewThemeID == "mincho")
        #expect(renderer.logicalRenderCount == count)
        #expect(trial.logicalRenderCount == 0)
        #expect(model.themeTrial.themeID == nil)
        #expect(model.themeID == "standard")
        // What a click on a sample does.
        model.selectTheme("mincho")
        try await waitUntil {
            renderer.logicalRenderCount > count && model.hasCurrentPrintPreview && !model.isRendering
        }
        #expect(model.preferences.recentThemeIDs.first == "mincho")
        #expect(model.isThemePalettePresented)
        model.preferences.themeSampleSource = .specimen
        model.followThemeSamples()
        #expect(model.paletteSamples === model.specimenSamples)
        model.preferences.themeSampleSource = .document
        #expect(model.paletteSamples === model.themeSamples)
        model.themePaletteDidClose()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.isThemePalettePresented)
        #expect(model.mode == .print)
    }

    /// Every twelfth theme, the standard one among them: composing all 95 in both languages would take a minute, and
    /// the text PDFKit gives back from a sample is not reliable enough to look for the last words in (some fonts
    /// return no kana, some cut the text short).
    @Test("同梱見本は日本語も英語も、実際の組版で 1 ページに収まる", .timeLimit(.minutes(2)), arguments: ["ja", "en"])
    func specimenPrintsOnePage(language: String) async throws {
        let themes = try PrintThemeLibrary.load()
        let renderer = DocumentRenderer()
        for (index, theme) in themes.enumerated() where index % 12 == 0 || theme.id == "standard" {
            var settings = ThemeSpecimen.settings
            settings.theme = theme
            let rendered = try await renderer.prepare(ThemeSpecimen.source(language: language), settings: settings)
            #expect(rendered.logicalDocument.pageCount == 1, "\(theme.id)")
        }
    }

    @Test("見本の元を切り替えても実文書の見本と組版設定は保つ")
    func separateSampleCaches() async throws {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
        let model = DocumentViewModel(
            data: Data("# Own document".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        defer { model.stop() }
        let theme = try #require(model.theme("standard"))
        await model.paletteSamples.load(theme)
        let own = try #require(model.paletteSamples.page(for: theme))
        #expect(own.string?.contains("Own document") == true)
        let settings = model.renderSettings
        model.preferences.themeSampleSource = .specimen
        model.followThemeSamples()
        await model.paletteSamples.load(theme)
        let specimen = try #require(model.paletteSamples.page(for: theme))
        #expect(specimen !== own)
        #expect(specimen.string?.contains("Own document") == false)
        model.preferences.themeSampleSource = .document
        model.followThemeSamples()
        #expect(model.paletteSamples.page(for: theme) === own)
        #expect(model.renderSettings == settings)
        #expect(model.preferences.recentThemeIDs.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct CodePaletteModelTests {
    private func library() -> UserLibrary {
        UserLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func renderer(pages: Int) -> DocumentRenderer {
        DocumentRenderer(paginate: { _ in
            PDFDocument(data: TestFixtures.pdf("code-palette-\(pages)", pages: pages)) ?? PDFDocument()
        })
    }

    private func model(
        _ suite: TestDefaultsSuite, format: DocumentFormat = .markdown, store: DocumentSettingsStore? = nil
    ) -> DocumentViewModel {
        DocumentViewModel(
            data: Data("```swift\nlet a = 1\n```\n".utf8), fileURL: nil, format: format,
            preferences: AppPreferences(defaults: suite.defaults), library: library(), renderer: renderer(pages: 1),
            settingsStore: store, trialRenderer: renderer(pages: 3))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("既定はスタイルに合わせ、今と同じ組版の設定になる")
    func matchesStyleByDefault() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        #expect(model.codePaletteID == CodePalette.matchesStyleID)
        #expect(try #require(model.renderSettings).code.isDefault)
    }

    @Test("スタイルを変えても、選んだコードの配色は残る")
    func paletteSurvivesTheStyle() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.selectCodePalette("wairo")
        model.selectTheme("mincho")
        #expect(model.codePaletteID == "wairo")
        #expect(try #require(model.renderSettings).code.palette?.id == "wairo")
        #expect(try #require(model.renderSettings).theme.id == "mincho")
    }

    @Test("新しい文書はアプリの既定の配色で始まり、知らない配色ならスタイルに合わせる")
    func appDefault() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.defaultCodePaletteID = "hicon"
        #expect(model(suite).codePaletteID == "hicon")
        preferences.defaultCodePaletteID = "gone"
        #expect(model(suite).codePaletteID == CodePalette.matchesStyleID)
    }

    @Test("文書の設定はコードの配色と枠を覚え、既定の文書には枠を書かない")
    func remembers() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        #expect(model.rememberedSettings.codePaletteID == CodePalette.matchesStyleID)
        #expect(model.rememberedSettings.codeBlock == nil)
        model.selectCodePalette("sumi")
        model.codeBlock.lineNumbers = .all
        #expect(model.rememberedSettings.codePaletteID == "sumi")
        #expect(model.rememberedSettings.codeBlock == CodeBlockOptions(lineNumbers: .all))
    }

    @Test("保存した配色と枠で開き直し、知らない配色の記録は他の設定を残して無視する", .timeLimit(.minutes(1)))
    func restores() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentSettingsStore(directory: directory)
        let hash = ContentHash.of(Data("```swift\nlet a = 1\n```\n".utf8)).hex

        try store.save(
            DocumentSettings(codePaletteID: "sepia", codeBlock: CodeBlockOptions(frame: .rule)), for: hash)
        let restored = model(suite, store: store)
        restored.start()
        try await waitUntil { restored.contentHash != nil }
        #expect(restored.codePaletteID == "sepia")
        #expect(restored.codeBlock == CodeBlockOptions(frame: .rule))

        try store.save(DocumentSettings(themeID: "mincho", codePaletteID: "gone"), for: hash)
        let unknown = model(suite, store: store)
        unknown.start()
        try await waitUntil { unknown.contentHash != nil }
        #expect(unknown.codePaletteID == CodePalette.matchesStyleID)
        #expect(unknown.themeID == "mincho")
    }

    @Test("既定に戻すと、コードの配色と枠も戻る")
    func reset() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.selectCodePalette("sumi")
        model.codeBlock.frame = .left
        model.resetDocumentSettings()
        #expect(model.codePaletteID == CodePalette.matchesStyleID)
        #expect(model.codeBlock == CodeBlockOptions())
    }

    @Test("HTML 文書にはコードの配色を渡さない")
    func htmlIgnoresThePalette() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.defaultCodePaletteID = "sumi"
        let model = model(suite, format: .html)
        #expect(try #require(model.renderSettings).code.isDefault)
        #expect(model.rememberedSettings.codePaletteID == nil)
    }

    @Test("暗い地の配色を選ぶとインクの注意が出て、他の配色では出ない")
    func inkWarning() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.selectCodePalette("sumi")
        #expect(model.toast == nil)
        model.selectCodePalette("dark")
        #expect(model.toast?.title == String(localized: "Dark code blocks use a lot of ink"))
    }

    @Test("乗せた配色を紙で試し、離すと文書のページに戻る", .timeLimit(.minutes(1)))
    func triesAPalette() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.render()
        try await waitUntil { model.result != nil && !model.isRendering }
        let own = try #require(model.result?.logicalDocument)

        model.tryCodePalette("wairo")
        #expect(model.trialThemeName == "和色" || model.trialThemeName == "Japanese Colors")
        try await waitUntil { model.themeTrial.document != nil }
        #expect(model.paperDocument?.pageCount == 3)
        #expect(model.codePaletteID == CodePalette.matchesStyleID)

        model.endThemeTrial()
        #expect(model.paperDocument === own)
    }

    @Test("試している配色を選ぶと、組み上がるまで試しのページを出し続ける", .timeLimit(.minutes(1)))
    func choosingKeepsTheTrial() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.render()
        try await waitUntil { model.result != nil && !model.isRendering }
        model.tryCodePalette("wairo")
        try await waitUntil { model.themeTrial.document != nil }
        let trial = try #require(model.themeTrial.document)

        model.selectCodePalette("wairo")
        #expect(model.themeTrial.themeID == nil)
        #expect(model.paperDocument === trial)
        model.render()
        try await waitUntil { !model.isRendering && model.chosenTrial == nil }
        #expect(model.paperDocument?.pageCount == 1)
    }

    @Test("いまの配色に乗せても試さない")
    func currentPaletteNeedsNoTrial() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.tryCodePalette(CodePalette.matchesStyleID)
        #expect(model.themeTrial.themeID == nil)
    }

    @Test("見本の組み立ては、文書にコードがあるかを知っている")
    func samplesKnowAboutCode() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        model.followThemeSamples()
        #expect(model.themeSamples.containsCode)
    }

    @Test("配色の既定はアプリの設定に残る")
    func preferencePersists() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        AppPreferences(defaults: suite.defaults).defaultCodePaletteID = "ud"
        #expect(AppPreferences(defaults: suite.defaults).defaultCodePaletteID == "ud")
    }
}

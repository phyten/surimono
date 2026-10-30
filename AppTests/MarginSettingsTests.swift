import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct MarginSettingsTests {
    private func makeModel(format: DocumentFormat, suite: TestDefaultsSuite) -> DocumentViewModel {
        let library = UserLibrary(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return DocumentViewModel(
            data: Data(), fileURL: nil, format: format, preferences: AppPreferences(defaults: suite.defaults),
            library: library)
    }

    @Test("表示モードから変えた余白は印刷のオプションと描画要求に入る")
    func setMarginsUpdatesRenderSettings() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.setMargins(5)
        #expect(model.printOptions.marginsInMillimeters == 5)
        #expect(try #require(model.renderSettings).options.marginsInMillimeters == 5)
    }

    @Test("余白は 0〜40 mm に収め、数でない値は無視する")
    func setMarginsClamps() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.setMargins(55)
        #expect(model.printOptions.marginsInMillimeters == 40)
        model.setMargins(-3)
        #expect(model.printOptions.marginsInMillimeters == 0)
        model.setMargins(.nan)
        #expect(model.printOptions.marginsInMillimeters == 0)
        model.setMargins(.infinity)
        #expect(model.printOptions.marginsInMillimeters == 0)
    }

    @Test("余白は 0.1 mm 単位に丸め、既定の値と同じ表示の別の値を作らない")
    func setMarginsRoundsToTenths() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.setMargins(5.01)
        #expect(model.printOptions.marginsInMillimeters == 5)
        #expect(model.marginChoices == DocumentViewModel.marginPresets)
        model.setMargins(12.46)
        #expect(model.printOptions.marginsInMillimeters == 12.5)
    }

    @Test("刷り台の余白は PDF 以外の印刷に効き、3 枚＋メモの用紙にも効く")
    func marginsAffectPrinting() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        #expect(makeModel(format: .markdown, suite: suite).marginsAffectPrinting)
        #expect(!makeModel(format: .pdf, suite: suite).marginsAffectPrinting)
        let handout = makeModel(format: .markdown, suite: suite)
        handout.layoutID = "a4Handout3"
        #expect(handout.marginsAffectPrinting)
        #expect(!handout.marginsApply)
    }

    @Test("余白は Markdown には効き、PDF と 3 枚＋メモには効かない")
    func marginsApply() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        #expect(makeModel(format: .markdown, suite: suite).marginsApply)
        #expect(!makeModel(format: .pdf, suite: suite).marginsApply)
        let handout = makeModel(format: .markdown, suite: suite)
        handout.layoutID = "a4Handout3"
        #expect(!handout.marginsApply)
    }

    @Test("余白のメニューは 0・5・10・15・20・25 mm を並べる")
    func presets() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.setMargins(15)
        #expect(model.marginChoices == [0, 5, 10, 15, 20, 25])
    }

    @Test("余白のメニューは既定の値でない今の余白も並べる")
    func currentValueIsListed() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.setMargins(12.5)
        #expect(model.marginChoices == [0, 5, 10, 12.5, 15, 20, 25])
        #expect(MarginMenu.label(12.5).contains("12.5"))
    }
}

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

    @Test("余白は 1 mm 単位に丸める")
    func setMarginsRoundsToMillimeters() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.setMargins(5.01)
        #expect(model.printOptions.marginsInMillimeters == 5)
        #expect(model.marginChoices == DocumentViewModel.marginPresets)
        model.setMargins(12.46)
        #expect(model.printOptions.marginsInMillimeters == 12)
    }

    @Test("刷り台の余白は PDF 以外の印刷に効き、3 枚＋メモの用紙にも効く")
    func marginsAffectPrinting() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        #expect(makeModel(format: .markdown, suite: suite).marginsAffectPrinting)
        #expect(!makeModel(format: .pdf, suite: suite).marginsAffectPrinting)
        let handout = makeModel(format: .markdown, suite: suite)
        handout.layoutID = "a4Handout3"
        handout.enterPrintMode()
        #expect(handout.marginsAffectPrinting)
        #expect(!handout.marginsApply)
    }

    @Test("表示の余白は印刷に 3 枚＋メモを選んでも Markdown に効き、PDF には効かない")
    func marginsApply() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        #expect(makeModel(format: .markdown, suite: suite).marginsApply)
        #expect(!makeModel(format: .pdf, suite: suite).marginsApply)
        let handout = makeModel(format: .markdown, suite: suite)
        handout.layoutID = "a4Handout3"
        #expect(handout.marginsApply)
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
        model.printOptions.marginsInMillimeters = 12.5
        #expect(model.marginChoices == [0, 5, 10, 12.5, 15, 20, 25])
        #expect(MarginMenu.label(12.5).contains("12.5"))
    }

    @Test("4 辺をそろえている間は 1 辺の変更が全部に効き、外すと 1 辺だけ変わる")
    func linkedMargins() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.setMargin(\.left, to: 20)
        #expect(model.printOptions.margins == .uniform(20))
        model.setMarginsLinked(false)
        model.setMargin(\.left, to: 30.4)
        #expect(model.printOptions.margins == PageMargins(top: 20, left: 30, bottom: 20, right: 20))
        model.setMarginsLinked(true)
        #expect(model.printOptions.margins == .uniform(20))
    }

    @Test("余白がそろっていないとき、表示モードのメニューは今の値を持たず、選ぶと 4 辺をそろえる")
    func unevenMarginsInTheMenu() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.printOptions.linksMargins = false
        model.printOptions.margins = PageMargins(top: 10, left: 20, bottom: 10, right: 20)
        #expect(model.marginChoices == DocumentViewModel.marginPresets)
        model.setMargins(15)
        #expect(model.printOptions.margins == .uniform(15))
        #expect(model.printOptions.linksMargins)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out")
    }

    @Test("そろっていない余白でも、ページをつなぐときに本文を削らないよう一番小さい余白だけ詰める")
    func viewMarginIsTheSmallest() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.printOptions.margins = PageMargins(top: 10, left: 20, bottom: 30, right: 40)
        model.start()
        try await waitUntil { model.isUpToDate }
        #expect(abs((model.viewLogicalMargin ?? 0) - 10 * 72 / 25.4) < 0.01)
    }
}

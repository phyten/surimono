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

    @Test("余白は端数を保ち、12.5 mm を 13 mm に丸めない")
    func setMarginsKeepsFractions() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.setMargins(12.5)
        #expect(model.printOptions.marginsInMillimeters == 12.5)
        #expect(model.marginChoices(in: .millimeters) == [0, 5, 10, 12.5, 15, 20, 25])
        // An inch keeps its exact millimeters.
        model.setMargins(6.35)
        #expect(model.printOptions.marginsInMillimeters == 6.35)
        #expect(model.marginChoices(in: .inches) == [0, 6.35, 12.7, 19.05, 25.4])
    }

    @Test("インチで 0.5 と同じに見える 12.6 mm のときも、0.5 インチを選ぶと 12.7 mm になる")
    func choosingPresetThatShowsLikeCurrent() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.setMargins(12.6)
        let choices = model.marginChoices(in: .inches)
        #expect(choices == [0, 6.35, 12.6, 12.7, 19.05, 25.4])
        // The menu's selection writes the chosen millimeters as they are.
        model.setMargins(choices[3])
        #expect(model.printOptions.marginsInMillimeters == 12.7)
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

    @Test("表示の文字の余白は Markdown の紙に効き、PDF と、余白のないページを刷る 3 枚＋メモには出さない")
    func marginsApply() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        #expect(makeModel(format: .markdown, suite: suite).marginsApply)
        #expect(!makeModel(format: .pdf, suite: suite).marginsApply)
        let booklet = makeModel(format: .markdown, suite: suite)
        booklet.layoutID = "a4BookletA5"
        #expect(booklet.marginsApply)
        let handout = makeModel(format: .markdown, suite: suite)
        handout.layoutID = "a4Handout3"
        #expect(!handout.marginsApply)
        #expect(handout.marginsAffectPrinting)
    }

    @Test("PDF の余白は変わらないという注記は、PDF を含む合本にだけ出す")
    func pdfMarginNoteNeedsAPDF() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let library = UserLibrary(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        func binder(_ names: [String]) -> DocumentViewModel {
            DocumentViewModel(
                data: Data(), fileURL: nil, format: .markdown, preferences: AppPreferences(defaults: suite.defaults),
                library: library,
                binder: BinderModel(orderedURLs: names.map { URL(fileURLWithPath: "/tmp/\($0)") }))
        }
        #expect(!makeModel(format: .markdown, suite: suite).notesPDFMargins)
        #expect(!binder(["a.md", "b.org"]).notesPDFMargins)
        #expect(binder(["a.md", "b.pdf"]).notesPDFMargins)
    }

    @Test("余白のメニューは 0・5・10・15・20・25 mm を並べる")
    func presets() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.setMargins(15)
        #expect(model.marginChoices(in: .millimeters) == [0, 5, 10, 15, 20, 25])
    }

    @Test("余白のメニューは既定の値でない今の余白も並べる")
    func currentValueIsListed() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = makeModel(format: .markdown, suite: suite)
        model.printOptions.marginsInMillimeters = 12.5
        #expect(model.marginChoices(in: .millimeters) == [0, 5, 10, 12.5, 15, 20, 25])
        let locale = Locale(identifier: "en_US")
        #expect(MarginUnit.millimeters.label(12.5, locale: locale).contains("12.5"))
        #expect(MarginUnit.inches.label(6.35, locale: locale).contains("0.25"))
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
        #expect(model.printOptions.margins == PageMargins(top: 20, left: 30.4, bottom: 20, right: 20))
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
        #expect(model.marginChoices(in: .millimeters) == [0, 5, 10, 15, 20, 25])
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

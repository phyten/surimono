import CoreGraphics
import SurimonoCore
import Testing

struct ViewDefaultPreferencesTests {
    private let preferences = ViewDefaultPreferences(layout: .spread, transition: .fade, joinsPages: false)

    @Test("自動は文書の種類・寸法・PDFヒントごとの従来の既定値を変えない")
    func automaticPreservesDocumentDefaults() {
        for kind in [ViewDefaultsContext.Kind.flowingText, .image, .imageBundle, .pdf] {
            for pages in [1, 2, 10] {
                for size in [CGSize(width: 100, height: 200), CGSize(width: 200, height: 100)] {
                    for hint in [
                        nil, "SinglePage", "OneColumn", "TwoColumnLeft", "TwoColumnRight", "TwoPageLeft",
                        "TwoPageRight",
                    ] as [String?] {
                        let context = ViewDefaultsContext(
                            kind: kind, pageCount: pages, firstPageSize: size, pdfPageLayout: hint, pdfDirection: "R2L")
                        #expect(
                            ViewOptions.resolved(for: context, preferences: ViewDefaultPreferences())
                                == ViewOptions.defaults(for: context))
                    }
                }
            }
        }
    }

    @Test("表示型と送り方は明示した方だけを上書きする")
    func independentOverrides() {
        let context = ViewDefaultsContext(kind: .flowingText, pageCount: 10, firstPageSize: .zero)
        let layoutOnly = ViewOptions.resolved(for: context, preferences: ViewDefaultPreferences(layout: .spread))
        #expect(layoutOnly.layout == .spread)
        #expect(layoutOnly.transition == .scroll)
        let transitionOnly = ViewOptions.resolved(for: context, preferences: ViewDefaultPreferences(transition: .fade))
        #expect(transitionOnly.layout == .single)
        #expect(transitionOnly.transition == .fade)
        let joinsOnly = ViewOptions.resolved(for: context, preferences: ViewDefaultPreferences(joinsPages: false))
        #expect(joinsOnly.layout == .single)
        #expect(joinsOnly.transition == .scroll)
        #expect(!joinsOnly.joinsPages)
    }

    @Test("保存済みの表示設定はアプリの既定値より優先する")
    func savedWins() {
        let context = ViewDefaultsContext(kind: .flowingText, pageCount: 10, firstPageSize: .zero)
        let saved = ViewOptions.defaults(for: context)
        #expect(ViewOptions.resolved(for: context, preferences: preferences, saved: saved) == saved)
    }

    @Test("本文と画像の束にはアプリの既定値を重ね、方向と表紙を保つ", arguments: [ViewDefaultsContext.Kind.flowingText, .imageBundle])
    func appDefaults(kind: ViewDefaultsContext.Kind) {
        let context = ViewDefaultsContext(kind: kind, pageCount: 10, firstPageSize: CGSize(width: 100, height: 200))
        let result = ViewOptions.resolved(for: context, preferences: preferences)
        #expect(result.layout == .spread)
        #expect(result.transition == .fade)
        #expect(!result.joinsPages)
        #expect(result.showsCoverAlone == (kind == .imageBundle))
        #expect(result.scrollAxis == (kind == .flowingText ? .vertical : .horizontal))
    }

    @Test("単独画像と短いPDFと横長PDFは単ページを保つ")
    func forcedSingle() {
        for context in [
            ViewDefaultsContext(kind: .image, pageCount: 1, firstPageSize: .zero),
            ViewDefaultsContext(kind: .pdf, pageCount: 2, firstPageSize: CGSize(width: 100, height: 200)),
            ViewDefaultsContext(kind: .pdf, pageCount: 10, firstPageSize: CGSize(width: 200, height: 100)),
        ] {
            #expect(ViewOptions.resolved(for: context, preferences: preferences).layout == .single)
        }
    }

    @Test(
        "PDFの明示した表示型と送り方と綴じ方向を優先する",
        arguments: ["SinglePage", "OneColumn", "TwoColumnLeft", "TwoColumnRight", "TwoPageLeft", "TwoPageRight"])
    func pdfHints(hint: String) {
        let context = ViewDefaultsContext(
            kind: .pdf, pageCount: 10, firstPageSize: .zero, pdfPageLayout: hint, pdfDirection: "R2L")
        var expected = ViewOptions.defaults(for: context)
        expected.joinsPages = false
        #expect(ViewOptions.resolved(for: context, preferences: preferences) == expected)
    }

    @Test("表示型の指定がない縦長PDFにはアプリの既定値を重ねる")
    func unhintedPDF() {
        let context = ViewDefaultsContext(
            kind: .pdf, pageCount: 10, firstPageSize: CGSize(width: 100, height: 200), pdfDirection: "R2L")
        let result = ViewOptions.resolved(
            for: context, preferences: ViewDefaultPreferences(layout: .single, transition: .wipe, joinsPages: false))
        #expect(result.layout == .single)
        #expect(result.transition == .wipe)
        #expect(result.direction == .rightToLeft)
        #expect(result.showsCoverAlone)
    }
}

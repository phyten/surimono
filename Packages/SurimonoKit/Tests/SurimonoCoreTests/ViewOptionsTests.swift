import CoreGraphics
import Foundation
import SurimonoCore
import Testing

struct ViewOptionsTests {
    private let portrait = CGSize(width: 595, height: 842)

    private func pdf(_ pages: Int = 12, size: CGSize? = nil, layout: String? = nil, direction: String? = nil)
        -> ViewOptions
    {
        ViewOptions.defaults(
            for: ViewDefaultsContext(
                kind: .pdf, pageCount: pages, firstPageSize: size ?? portrait, pdfPageLayout: layout,
                pdfDirection: direction))
    }

    @Test("表示の型は見開きと単ページの順に並ぶ")
    func layouts() {
        #expect(ViewOptions.Layout.allCases == [.spread, .single])
    }

    @Test(
        "方向を持つ送り方ではスクロールの方向が効く",
        arguments: [
            (ViewOptions.Transition.scroll, true), (.slide, true), (.instant, false), (.fade, false),
            (.pageCurl, false), (.cover, true), (.reveal, true), (.wipe, true), (.zoom, false),
        ])
    func scrollAxisMatters(transition: ViewOptions.Transition, uses: Bool) {
        let options = ViewOptions(layout: .spread, scrollAxis: .vertical, transition: transition, showsCoverAlone: true)
        #expect(options.usesScrollAxis == uses)
    }

    @Test(
        "どの表示の型でも送り方がスクロールのときだけ連続スクロールになる",
        arguments: ViewOptions.Layout.allCases, ViewOptions.Transition.allCases)
    func continuous(layout: ViewOptions.Layout, transition: ViewOptions.Transition) {
        let options = ViewOptions(
            layout: layout, scrollAxis: .vertical, transition: transition, showsCoverAlone: false)
        #expect(options.isContinuous == (transition == .scroll))
    }

    private func savedView(layout: String, transition: ViewOptions.Transition) -> String {
        """
        {"layout":"\(layout)","direction":"rightToLeft","scrollAxis":"vertical",
         "transition":"\(transition.rawValue)","showsCoverAlone":false}
        """
    }

    @Test("旧表示型は見開きとして読み込み、ほかの表示設定を保つ", arguments: ViewOptions.Transition.allCases)
    func decodeLegacyView(transition: ViewOptions.Transition) throws {
        let data = Data(savedView(layout: "twoPageScroll", transition: transition).utf8)
        let options = try JSONDecoder().decode(ViewOptions.self, from: data)
        #expect(
            options
                == ViewOptions(
                    layout: .spread, direction: .rightToLeft, scrollAxis: .vertical,
                    transition: transition, showsCoverAlone: false))
        let encoded = try JSONEncoder().encode(options)
        let values = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(values["layout"] as? String == "spread")
    }

    @Test("文書設定の旧表示型もほかの設定を保って見開きへ読み替える", arguments: ViewOptions.Transition.allCases)
    func decodeLegacyDocumentSettings(transition: ViewOptions.Transition) throws {
        let json = """
            {"view":\(savedView(layout: "twoPageScroll", transition: transition)),"zoom":2,"themeID":"test-theme"}
            """
        let settings = try JSONDecoder().decode(DocumentSettings.self, from: Data(json.utf8))
        #expect(
            settings.view
                == ViewOptions(
                    layout: .spread, direction: .rightToLeft, scrollAxis: .vertical,
                    transition: transition, showsCoverAlone: false))
        #expect(settings.zoom == 2)
        #expect(settings.themeID == "test-theme")
    }

    @Test("未知の表示型は読み込みに失敗し、文書設定では表示以外の項目を残す")
    func unknownLayout() throws {
        let view = savedView(layout: "unknown-layout", transition: .fade)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ViewOptions.self, from: Data(view.utf8))
        }
        let json = """
            {"view":\(view),"zoom":2,"themeID":"test-theme"}
            """
        let settings = try JSONDecoder().decode(DocumentSettings.self, from: Data(json.utf8))
        #expect(settings.view == nil)
        #expect(settings.zoom == 2)
        #expect(settings.themeID == "test-theme")
    }

    @Test("表示の型は現在の文字列で書き出して読み戻せる", arguments: ViewOptions.Layout.allCases)
    func layoutRoundTrip(layout: ViewOptions.Layout) throws {
        let data = try JSONEncoder().encode(layout)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(layout.rawValue)\"")
        #expect(try JSONDecoder().decode(ViewOptions.Layout.self, from: data) == layout)
    }

    @Test(
        "スライドで入る辺は表示の型によらずスクロール方向と綴じ方向と進退で決まる",
        arguments: ViewOptions.Layout.allCases,
        [
            (ViewOptions.ScrollAxis.vertical, ViewOptions.Direction.leftToRight, true, ViewOptions.SlideEdge.bottom),
            (.vertical, .leftToRight, false, .top),
            (.vertical, .rightToLeft, true, .bottom),
            (.vertical, .rightToLeft, false, .top),
            (.horizontal, .leftToRight, true, .right),
            (.horizontal, .leftToRight, false, .left),
            (.horizontal, .rightToLeft, true, .left),
            (.horizontal, .rightToLeft, false, .right),
        ])
    func slideEdge(
        layout: ViewOptions.Layout,
        scenario: (ViewOptions.ScrollAxis, ViewOptions.Direction, Bool, ViewOptions.SlideEdge)
    ) {
        let (axis, direction, forward, edge) = scenario
        let options = ViewOptions(
            layout: layout, direction: direction, scrollAxis: axis, transition: .slide, showsCoverAlone: true)
        #expect(options.slideEdge(forward: forward) == edge)
    }

    @Test("流し込みの文書は単ページの縦の連続スクロールで開く")
    func flowingTextDefaults() {
        let options = ViewOptions.defaults(
            for: ViewDefaultsContext(kind: .flowingText, pageCount: 30, firstPageSize: portrait))
        #expect(
            options
                == ViewOptions(
                    layout: .single, direction: .leftToRight, scrollAxis: .vertical, transition: .scroll,
                    showsCoverAlone: false))
    }

    @Test("画像の束は見開き・表紙単独・左綴じ・スライドで開く")
    func imageBundleDefaults() {
        let options = ViewOptions.defaults(
            for: ViewDefaultsContext(kind: .imageBundle, pageCount: 1, firstPageSize: portrait))
        #expect(
            options
                == ViewOptions(
                    layout: .spread, direction: .leftToRight, scrollAxis: .horizontal, transition: .slide,
                    showsCoverAlone: true))
    }

    @Test("1枚の画像は単ページで開く")
    func imageDefaults() {
        let options = ViewOptions.defaults(
            for: ViewDefaultsContext(kind: .image, pageCount: 1, firstPageSize: portrait))
        #expect(options.layout == .single)
        #expect(!options.showsCoverAlone)
    }

    @Test("PDF は見開き・表紙単独・左綴じ・横・スライドで開く")
    func pdfDefaults() {
        #expect(
            pdf()
                == ViewOptions(
                    layout: .spread, direction: .leftToRight, scrollAxis: .horizontal, transition: .slide,
                    showsCoverAlone: true))
    }

    @Test("2ページ以下や横長の PDF は単ページで開く")
    func shortOrLandscapePDF() {
        #expect(pdf(2).layout == .single)
        #expect(pdf(12, size: CGSize(width: 842, height: 595)).layout == .single)
        #expect(pdf(3).layout == .spread)
    }

    @Test("右綴じの PDF は右から左へ表紙単独で開く")
    func rightToLeftPDF() {
        let options = pdf(direction: "R2L")
        #expect(options.direction == .rightToLeft)
        #expect(options.layout == .spread)
        #expect(options.showsCoverAlone)
    }

    @Test("PDF の PageLayout があれば表示の型と表紙の扱いに従う")
    func pdfPageLayout() {
        #expect(pdf(layout: "SinglePage").layout == .single)
        let oneColumn = pdf(layout: "OneColumn")
        #expect(oneColumn.layout == .single && oneColumn.transition == .scroll && oneColumn.scrollAxis == .vertical)
        #expect(!pdf(layout: "TwoPageLeft").showsCoverAlone)
        #expect(pdf(layout: "TwoPageRight").showsCoverAlone)
        let columns = pdf(2, layout: "TwoColumnRight")
        #expect(columns.layout == .spread && columns.transition == .scroll && columns.showsCoverAlone)
    }

    @Test("右綴じの PDF では奇数ページが左にある組みを表紙単独と読む")
    func rightToLeftPageLayout() {
        #expect(pdf(layout: "TwoPageLeft", direction: "R2L").showsCoverAlone)
        #expect(!pdf(layout: "TwoPageRight", direction: "R2L").showsCoverAlone)
    }
}

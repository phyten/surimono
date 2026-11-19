import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXPageLayoutTests {
    @Test("用紙が異なるときは本文の寸法と余白比を保ち、読む PDF と用紙の柱はその本文に揃う")
    func readingPages() async throws {
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass[11pt,letterpaper]{article}
                \usepackage[left=1in,right=2in,top=30bp,bottom=60bp,footskip=24bp]{geometry}
                \setmainfont{Times New Roman}\pagenumbering{Roman}\setcounter{page}{4}
                \begin{document}Body\end{document}
                """#.utf8), format: .latex)
        let renderer = DocumentRenderer(paginateWithResult: { request in
            #expect(request.pageSize == PaperSize.a4.size)
            #expect(abs(request.margins.left - 66.425) < 0.01)
            #expect(abs(request.margins.right - 132.850) < 0.01)
            #expect(abs(request.margins.top - 46.630) < 0.01)
            #expect(abs(request.margins.bottom - 93.260) < 0.01)
            return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 2, size: request.pageSize))
        })
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        let prepared = try await renderer.prepare(source, settings: settings)
        let first = try #require(prepared.viewFurniture[0])
        #expect(first.lines.bottom == ["", "IV", ""])
        #expect(first.latexFooter?.fontName == "Times New Roman")
        #expect(abs((first.latexFooter?.pointSize ?? 0) - 10.909) < 0.01)
        #expect(abs((first.latexFooter?.footSkip ?? 0) - 24) < 0.01)
        let reading = try ReadingPDFExporter.document(
            from: prepared.viewDocument, entries: [], title: "Example", furniture: prepared.viewFurniture)
        let page = try #require(reading.page(at: 0))
        let selection = try #require(reading.findString("IV").first)
        let bounds = selection.bounds(for: page)
        #expect(abs(bounds.midX - 264.425) < 2)
        #expect(bounds.minY < 69.26 && bounds.maxY > 69.26)
        #expect(prepared.viewDocument.findString("IV").isEmpty)
        let sheet = try await renderer.composeSheet(for: prepared)
        #expect(sheet.sheetDocument.page(at: 1)?.string?.contains("V") == true)
    }

    @Test("REVTeX と LNCS の固定原点はドライバーが A4 用紙を選んでも保つ")
    func fixedClassOrigins() {
        for (source, left, top) in [
            (#"\documentclass[preprint]{revtex4-2}"#, 72.0, 72.0), (#"\documentclass{llncs}"#, 134.765, 115.836),
        ] {
            let info = LaTeXConverter.documentClassInfo(source)
            let fitted = info.pageBox.margins(fitting: PaperSize.a4.size)
            #expect(abs(fitted.left * 72 / 25.4 - left) < 0.02)
            #expect(abs(fitted.top * 72 / 25.4 - top) < 0.02)
        }
    }

    @Test("用紙に収まらない余白だけを比例して減らし、数値の余白と手書きの柱を優先する")
    func chooseMargins() throws {
        let info = LaTeXConverter.documentClassInfo(
            #"\documentclass{article}\usepackage[left=100mm,right=200mm,top=12mm,bottom=18mm]{geometry}\begin{document}"#
        )
        let fitted = info.pageBox.margins(fitting: CGSize(width: 360, height: 600))
        #expect(abs(fitted.left * 72 / 25.4 - 96) < 0.01)
        #expect(abs(fitted.right * 72 / 25.4 - 192) < 0.01)
        #expect(fitted.top == 0 && fitted.bottom == 0)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var options = PrintOptions(marginsInMillimeters: 6)
        options.furniture = .name
        var settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""), options: options)
        settings.applyLaTeXPage(info)
        #expect(settings.options == options)
        #expect(settings.latexFooter == nil)
    }

    @Test("同じ見出しでもリンクの着いたページを取り、表紙・単独の空の柱・途中の数え直しを区別する")
    func mappedLabels() throws {
        let document = try RenderingFixtures.pdf(count: 4)
        let targets: [LaTeXPageReferences.Target] = [
            .init(action: "title", value: "", referenced: false),
            .init(action: "pagenumbering", value: "roman", referenced: false),
            .init(action: "", value: "", referenced: true),
            .init(action: "thispagestyle", value: "empty", referenced: false),
            .init(action: "page", value: "8", referenced: true),
        ]
        for (id, page) in [0, 1, 1, 2, 3].enumerated() {
            let marker = PDFAnnotation(
                bounds: CGRect(x: 10, y: 10, width: 1, height: 1), forType: .link, withProperties: nil)
            marker.url = URL(string: "surimono-tex-page:abc/\(id)")
            document.page(at: page)?.addAnnotation(marker)
        }
        let locations = LaTeXPageReferences.locations(in: document, token: "abc", count: targets.count)
        let map = LaTeXPageReferences.map(
            .init(), targets: targets, locations: locations, pageCount: 4, restartsAfterTitle: true)
        #expect(map.pages.map(\.label) == ["1", "i", "ii", "viii"])
        #expect(map.pages.map(\.hasFooter) == [false, true, false, true])
        #expect(map.references == ["2": "i", "4": "viii"])
    }
}

import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXFancyFurnitureTests {
    @Test("左右のヘッダーと中央の番号を読む PDF と用紙 PDF の同じ位置に描く")
    func exportedPages() async throws {
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass{article}\usepackage[left=60bp,right=90bp,top=95bp,bottom=75bp,headsep=21bp,footskip=28bp]{geometry}
                \fancypagestyle{workshop}{\fancyhf{}\lhead{Workshop}\rhead{Crew sheet}\cfoot{Page \thepage}}\pagestyle{workshop}
                \begin{document}Body\end{document}
                """#.utf8), format: .latex)
        let renderer = DocumentRenderer(paginateWithResult: { request in
            WebPaginator.Result(document: try RenderingFixtures.pdf(count: 2, size: request.pageSize))
        })
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
        let prepared = try await renderer.prepare(source, settings: settings)
        let reading = try ReadingPDFExporter.document(
            from: prepared.viewDocument, entries: [], title: "Sample", furniture: prepared.viewFurniture)
        let sheets = try await renderer.composeSheet(for: prepared)
        for pdf in [reading, sheets.sheetDocument] {
            let second = try #require(pdf.page(at: 1))
            let left = try #require(pdf.findString("Workshop").first { $0.pages.first === second })
            let right = try #require(pdf.findString("Crew sheet").first { $0.pages.first === second })
            let foot = try #require(pdf.findString("Page 2").first { $0.pages.first === second })
            let bounds = second.bounds(for: .mediaBox)
            #expect(abs(left.bounds(for: second).minX - 60) < 2)
            #expect(abs(right.bounds(for: second).maxX - (bounds.width - 90)) < 2)
            #expect(left.bounds(for: second).contains(CGPoint(x: 62, y: bounds.height - 74)))
            #expect(foot.bounds(for: second).contains(CGPoint(x: (bounds.width - 30) / 2, y: 47)))
        }
    }

    @Test("論文クラスが番号を抑止するページでも利用者が選んだ柱を両方の PDF に出す")
    func customFurniture() async throws {
        let source = DocumentSource(
            data: Data(#"\documentclass[conference]{IEEEtran}\begin{document}Text\end{document}"#.utf8), format: .latex)
        let renderer = DocumentRenderer(paginateWithResult: { request in
            WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1, size: request.pageSize))
        })
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var options = PrintOptions()
        options.furniture.topRight = "Review copy"
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""), options: options)
        let prepared = try await renderer.prepare(source, settings: settings)
        let reading = try ReadingPDFExporter.document(
            from: prepared.viewDocument, entries: [], title: "Sample", furniture: prepared.viewFurniture)
        let sheet = try await renderer.composeSheet(for: prepared)
        #expect(prepared.viewFurniture[0]?.latexFooter == nil)
        #expect(reading.findString("Review copy").count == 1)
        #expect(sheet.sheetDocument.findString("Review copy").count == 1)
    }

    @Test("柱の左はそのページの最後の見出し、右は最初の印を取り次ページへ引き継ぐ")
    func runningMarks() {
        let state = LaTeXConverter.documentClassInfo(
            #"\documentclass{article}\pagestyle{fancy}\fancyhf{}\lhead{\leftmark}\rhead{\rightmark}"#
        ).pageNumbers
        let targets: [LaTeXPageReferences.Target] = [
            .init(action: "majorMark", value: "1 WORKSHOP", referenced: false),
            .init(action: "rightmark", value: "1.1 Crew", referenced: false),
            .init(action: "rightmark", value: "1.2 Stock", referenced: false),
            .init(action: "rightmark", value: "1.3 Spares", referenced: false),
            .init(action: "thispagestyle", value: "empty", referenced: false),
        ]
        let map = LaTeXPageReferences.map(
            state, targets: targets, locations: [0: 0, 1: 0, 2: 1, 3: 1, 4: 3], pageCount: 4, restartsAfterTitle: false)
        #expect(
            map.pages.map(\.lines.top) == [
                ["1 WORKSHOP", "", ""], ["1 WORKSHOP", "", "1.2 Stock"], ["1 WORKSHOP", "", "1.3 Spares"],
                ["", "", ""],
            ])
    }
}

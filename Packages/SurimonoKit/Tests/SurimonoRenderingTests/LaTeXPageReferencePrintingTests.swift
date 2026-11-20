import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXPageReferencePrintingTests {
    @Test("AMS 書籍は表題と裏面を数え、章扉に 3 を刷る", .timeLimit(.minutes(1)))
    func amsBookTitleVerso() async throws {
        let tex = #"""
            \documentclass[oneside,openany]{amsbook}\title{Handbook}\author{Workshop}
            \begin{document}\keywords{Card}\begin{abstract}Verso material.\end{abstract}
            \maketitle\chapter{Fold}\section{Trial}Chapter material.\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-report" })
        let prepared = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex),
            settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        #expect(prepared.logicalDocument.pageCount == 3)
        #expect(prepared.logicalDocument.page(at: 1)?.string?.contains("Verso material") == true)
        #expect(prepared.logicalDocument.page(at: 2)?.string?.contains("Chapter material") == true)
        #expect(prepared.viewFurniture[0] == nil)
        #expect(prepared.viewFurniture[1] == nil)
        #expect(prepared.viewFurniture[2]?.lines.bottom == ["", "3", ""])
    }

    @Test(
        "短い手紙は無ノンブルの一枚で終わり、続きのある手紙だけに二頁目の柱を刷る",
        .timeLimit(.minutes(1)), arguments: [false, true])
    func letterPages(continued: Bool) async throws {
        let tail = continued ? #"\newpage Second sheet."# : ""
        let text = #"""
            \documentclass{letter}\address{Model workshop\\East bench}\signature{Fixture desk}\date{14 May 2026}
            \begin{document}\begin{letter}{Stores desk\\Paper Model Workshop}\opening{Dear team,}
            Please reserve the card stock.\begin{center}\begin{tabular}{lr}Stock&Sheets\\Thin&3\\Heavy&2\end{tabular}\end{center}
            \closing{With thanks,}\encl{Stock list}\#(tail)\end{letter}\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let prepared = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(text.utf8), format: .latex),
            settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        #expect(prepared.logicalDocument.pageCount == (continued ? 2 : 1))
        #expect(prepared.logicalDocument.page(at: 0)?.string?.contains("Stock list") == true)
        #expect(prepared.viewFurniture[0] == nil)
        if continued {
            #expect(prepared.logicalDocument.page(at: 1)?.string?.contains("Second sheet") == true)
            #expect(prepared.viewFurniture[1]?.lines.bottom == ["", "2", ""])
        }
    }

    @Test("本文目次・図表一覧・ページ参照は目標のローマ数字を刷り、測定リンクを PDF に残さない", .timeLimit(.minutes(1)))
    func crossReferences() async throws {
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass{article}\pagenumbering{Roman}
                \begin{document}
                \tableofcontents\listoffigures\listoftables
                See page \pageref{dest}.
                \newpage\thispagestyle{empty}\section{Destination}\label{dest}
                \begin{figure}\caption{Figure specimen}\end{figure}
                \begin{table}\caption{Table specimen}\end{table}
                \end{document}
                """#.utf8), format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let pdf = prepared.logicalDocument
        #expect(pdf.pageCount == 2)
        let first = try #require(pdf.page(at: 0)?.string)
        let compact = first.filter { !$0.isWhitespace }
        #expect(first.components(separatedBy: "II").count == 5)
        #expect(!first.contains("III") && compact.contains("SeepageII."))
        for entry in ["Destination", "Figurespecimen", "Tablespecimen"] {
            #expect(compact.contains(entry))
        }
        let second = try #require(pdf.page(at: 1))
        let figure = try #require(pdf.findString("Figure specimen").first { $0.pages.first === second })
        let table = try #require(pdf.findString("Table specimen").first { $0.pages.first === second })
        let heading = try #require(pdf.findString("Destination").first { $0.pages.first === second })
        #expect(figure.bounds(for: second).minY > table.bounds(for: second).maxY)
        #expect(table.bounds(for: second).minY > heading.bounds(for: second).maxY)
        #expect(prepared.viewFurniture[0]?.lines.bottom == ["", "I", ""])
        #expect(prepared.viewFurniture[1] == nil)
        for index in 0..<pdf.pageCount {
            for link in pdf.page(at: index)?.annotations ?? [] {
                #expect(link.url?.scheme != "surimono-tex-page")
            }
        }
    }
}

extension LaTeXPageReferencePrintingTests {
    @Test("長い和文目次と図表目次は両方の組版で前付のローマ数字と本文の再採番を保つ", .timeLimit(.minutes(1)), arguments: [false, true])
    func japaneseContents(flow: Bool) async throws {
        let sections = (1...64).map { _ in #"\section{同名の節}"# }.joined()
        let fragment = LaTeXConverter.convert(
            #"\documentclass{ltjsreport}\usepackage{hyperref,tcolorbox,listings,fancyhdr}\pagenumbering{roman}\begin{document}\tableofcontents\listoffigures\listoftables\clearpage\chapter*{序文}\phantomsection\addcontentsline{toc}{chapter}{前付}\label{front}FRONTMARK\clearpage\pagenumbering{arabic}\chapter{本編}\label{main}MAINMARK\begin{tcolorbox}一段目\end{tcolorbox}"#
                + "\n\\begin{lstlisting}\nvalue\n\\end{lstlisting}\n"
                + #"\begin{figure}[h]\caption{図の一覧}\end{figure}\begin{table}[h]\caption{表の一覧}\end{table}"#
                + sections + #"\par FRONT[\pageref{front}] MAIN[\pageref{main}]\end{document}"#)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 595, height: 842), margins: .uniform(millimeters: 18),
            allowsJavaScript: false, latexPageNumbers: fragment.latexClass?.pageNumbers, latexFlow: flow)
        let text = try #require(result.document.string)
        #expect(!text.contains("?"))
        #expect(!text.contains("SRM"))
        #expect(!result.issues.contains { $0.id == "latex-page-references" || $0.id == "latex-flow-fallback" })
        let index = try #require(
            (0..<result.document.pageCount).first {
                result.document.page(at: $0)?.string?.contains("FRONTMARK") == true
            })
        let roman = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii"]
        #expect(roman.indices.contains(index))
        if roman.indices.contains(index) { #expect(text.contains("FRONT[\(roman[index])]")) }
        #expect(text.contains("MAIN[1]"))
    }

    @Test("存在しない目次の行き先は確認に知らせる", .timeLimit(.minutes(1)), arguments: [false, true])
    func missingDestination(flow: Bool) async throws {
        let result = try await WebPaginator().paginateWithResult(
            .html(
                ##"<body class="format-latex"><nav class="toc"><ul><li><a href="#lost">Lost</a></li></ul></nav></body>"##,
                baseURL: nil),
            pageSize: CGSize(width: 595, height: 842), margins: .uniform(millimeters: 12),
            allowsJavaScript: false, latexPageNumbers: .init(), latexFlow: flow)
        #expect(result.issues.contains { $0.id == "latex-page-references" })
    }

    @Test("連続した改ページと文献の開始は両方の組版で一枚だけ送る", .timeLimit(.minutes(1)), arguments: [false, true])
    func bibliographyBreak(flow: Bool) async throws {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{ltjsreport}\begin{document}\chapter{本文}BODYMARK\clearpage\clearpage\begin{thebibliography}{1}\bibitem{x}BIBMARK\end{thebibliography}\end{document}"#
        )
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 595, height: 842), margins: .uniform(millimeters: 12),
            allowsJavaScript: false, latexFlow: flow)
        #expect(result.document.pageCount == 2)
        #expect(result.document.page(at: 0)?.string?.contains("BODYMARK") == true)
        #expect(result.document.page(at: 1)?.string?.contains("BIBMARK") == true)
    }
    @Test("計測だけが失敗したら新しい文書に疑問符を置き本文と確認を返す", .timeLimit(.minutes(1)), arguments: [false, true])
    func measurementFailure(flow: Bool) async throws {
        let html =
            ##"<body class="format-latex"><nav class="toc"><ul><li><a href="#test-destination">Index</a></li></ul></nav><h2 id="test-destination">BODYMARK</h2></body>"##
        let failLookup = """
            const get = document.getElementById.bind(document);
            document.getElementById = id => {
              if (id === 'test-destination') throw Error('measurement unavailable');
              return get(id);
            };
            return 'prepared';
            """
        let paginator = WebPaginator()
        let result = try await paginator.paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 595, height: 842), margins: .uniform(millimeters: 12),
            allowsJavaScript: false, preparationScript: failLookup, latexPageNumbers: .init(), latexFlow: flow)
        let text = try #require(result.document.string)
        #expect(text.contains("BODYMARK"))
        #expect(text.contains("?"))
        #expect(!text.contains("SRM"))
        #expect(result.preparationResult == "prepared")
        #expect(result.issues.filter { $0.id == "latex-page-references" }.count == 1)
        #expect(paginator.printStartCount == 1)
    }

}

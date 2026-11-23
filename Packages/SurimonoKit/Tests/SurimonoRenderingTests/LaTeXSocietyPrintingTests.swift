import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXSocietyPrintingTests {
    @Test("和文学会誌の柱は実際に刷る本文のページ範囲と短い題を使い、英文要旨へ持ち越さない")
    func issueRange() throws {
        let source = #"""
            \documentclass[paper]{ieicej}
            \field{D}\vol{103}\no{4}\jtitle[短題]{長い題名}
            \begin{document}\maketitle 本文。\end{document}
            """#
        let info = try #require(LaTeXConverter.convert(source).latexClass)
        let targets = [
            LaTeXPageReferences.Target(action: "page", value: "11", referenced: false),
            LaTeXPageReferences.Target(action: "journalSupplement", value: "empty", referenced: false),
        ]
        let map = LaTeXPageReferences.map(
            info.pageNumbers, targets: targets, locations: [0: 0, 1: 3], pageCount: 4, restartsAfterTitle: false)
        #expect(map.pages[0].lines.bottom[1].contains("pp. 11–13"))
        #expect(map.pages[0].lines.bottom[1].contains("J103–D"))
        #expect(map.pages[1].lines.top[2].contains("2020/4"))
        #expect(map.pages[2].lines.top[0] == "論文／短題")
        #expect(map.pages[3].lines.isEmpty)
    }

    @Test("英文学会誌の短報の柱は紙種を示し、情報処理学会英文誌の DOI は初頁だけに置く")
    func issueOptions() throws {
        func pages(_ tex: String) throws -> [LaTeXPageReferences.Page] {
            let info = try #require(LaTeXConverter.convert(tex).latexClass)
            return LaTeXPageReferences.map(
                info.pageNumbers, targets: [], locations: [:], pageCount: 3, restartsAfterTitle: false
            ).pages
        }
        let letters = try pages(
            #"\documentclass[brief]{ieice}\title{Study}\begin{document}\maketitle Text.\end{document}"#)
        #expect(letters[2].lines.top == ["BRIEF PAPER", "", "3"])
        let journal = try pages(
            #"\documentclass[JIP]{ipsj}\setcounter{volume}{34}\setcounter{page}{21}\begin{document}\title{Study}\maketitle Text.\end{document}"#
        )
        #expect(journal[0].lines.journalPage?.secondary?.text == "[DOI: 10.2197/ipsjjip.34.21]")
        #expect(journal[1].lines.journalPage?.secondary == nil)
        let sig = try pages(#"\documentclass[techrep]{ipsj}\begin{document}\title{研究}\maketitle 本文。\end{document}"#)
        #expect(sig[1].lines.top == ["情報処理学会研究報告", "", ""])
        #expect(sig[1].lines.journalPage?.secondary?.text == "IPSJ SIG Technical Report")
        let english = try pages(
            #"\documentclass[techrep,english]{ipsj}\begin{document}\title{Study}\maketitle Text.\end{document}"#)
        #expect(english[0].lines.top == ["IPSJ SIG Technical Report", "", ""])
        #expect(english[0].lines.journalPage?.secondary == nil)
    }

    @Test("信学技報は初頁に査読に関する注記と著作権、次頁にダッシュ付きのノンブルを出す")
    func technicalReport() throws {
        let tex =
            #"\documentclass[technicalreport]{ieicej}\tecrepyear{2031}\jtitle{測定}\begin{document}\maketitle 本文。\end{document}"#
        let info = try #require(LaTeXConverter.convert(tex).latexClass)
        let pages = LaTeXPageReferences.map(
            info.pageNumbers, targets: [], locations: [:], pageCount: 2, restartsAfterTitle: false
        ).pages
        #expect(pages[0].lines.headRule == 0)
        #expect(pages[0].lines.bottom[0].contains("technical report without peer review"))
        #expect(pages[0].lines.journalPage?.secondary?.text == "Copyright ©2031 by IEICE")
        #expect(pages[1].lines.bottom == ["", "", "— 2 —"])
    }

    @Test("学会誌の柱と著作権を PDF の実寸で配置する", .timeLimit(.minutes(1)))
    func nativeFurniture() async throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        for (preamble, layout, head, headTop, foot, footTop) in [
            (
                #"\documentclass[submit]{ipsj}"#, PrintLayout.a4Single, "情報処理学会論文誌", 35.0, "Information Processing",
                803.0
            ),
            (#"\documentclass[paper]{ieicej}"#, .b5Single, "論", 54.0, "電子情報通信学会論文誌", 675.0),
            (#"\documentclass[paper]{ieice}\field{A}"#, .journalSingle, "FUNDAMENTALS", 50.0, "Copyright", 761.0),
        ] {
            let info = try #require(
                LaTeXConverter.convert(preamble + #"\begin{document}\maketitle Text.\end{document}"#).latexClass)
            var settings = RenderSettings(layout: layout, theme: theme, preset: .init(id: "none", name: ""))
            settings.options.latexFurniture = .style
            settings.applyLaTeXPage(info)
            let box = info.pageBox
            let size = CGSize(width: box.paperWidth, height: box.paperHeight)
            let pdf = try await PDFDrawing.document(pageSize: size) { context in
                context.beginPDFPage(nil)
                PageFurnitureDrawing.draw(
                    LaTeXPageReferences.Page(info.pageNumbers).lines, in: CGRect(origin: .zero, size: size),
                    margins: .init(top: box.top, left: box.left, bottom: box.bottom, right: box.right),
                    scale: 1, latexFooter: settings.latexFooter, context: context)
                context.endPDFPage()
            }
            let page = try #require(pdf.page(at: 0))
            #expect(pdf.findString(head).contains { abs(size.height - $0.bounds(for: page).midY - headTop) < 5 })
            #expect(pdf.findString(foot).contains { abs(size.height - $0.bounds(for: page).midY - footTop) < 5 })
            if layout == .b5Single {
                let title = try #require(pdf.findString(head).first { $0.bounds(for: page).midY > size.height / 2 })
                #expect(abs(title.bounds(for: page).minX - 82.92) < 2)
            }
        }
    }

    @Test("和文誌の短い節見出しを五字幅で描き、PDF 内で一語として検索できる")
    func justifiedHeading() async throws {
        let heading = LaTeXFlowPaginator.DistributedHeading(text: "はじめに", x: 12, y: 18, width: 49.6063)
        let pdf = try await PDFDrawing.document(pageSize: CGSize(width: 160, height: 90)) { context in
            context.beginPDFPage(nil)
            heading.draw(in: context, from: CGPoint(x: 20, y: 75), scale: 1)
            context.endPDFPage()
        }
        let page = try #require(pdf.page(at: 0))
        let matches = pdf.findString("はじめに")
        #expect(matches.count == 1)
        let match = try #require(matches.first)
        let bounds = match.bounds(for: page)
        #expect(abs(bounds.minX - 32) < 1)
        #expect(abs(bounds.width - heading.width) < 1)
    }

    @Test(
        "学会の原稿を指定判型で刷り、初頁の表題・本文・所属注と柱を検索する", .timeLimit(.minutes(1)),
        arguments: ["125-class-ipsj", "126-class-ieicej", "127-class-ieice"])
    func corpus(_ name: String) async throws {
        let corpus = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            .appendingPathComponent("Snapshots/corpus/latex")
        let data = try Data(contentsOf: corpus.appendingPathComponent(name + "/main.tex"))
        let english = name == "127-class-ieice"
        let supplement = name == "126-class-ieicej"
        let theme = try #require(
            PrintThemeLibrary.load().first { $0.id == (english ? "latex-article" : "latex-plain-ja") })
        let layout: PrintLayout = english ? .journalSingle : supplement ? .b5Single : .a4Single
        var settings = RenderSettings(layout: layout, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        settings.options.latexFurniture = .style
        let result = try await DocumentRenderer().prepare(.init(data: data, format: .latex), settings: settings)
        let pdf = try ReadingPDFExporter.document(
            from: result.viewDocument, entries: [], title: "Specimen", furniture: result.viewFurniture)
        #expect(pdf.pageCount == (supplement ? 3 : 2))
        let first = try #require(pdf.page(at: 0))
        let size = first.bounds(for: .mediaBox).size
        let referenceURL = corpus.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("reference/latex/\(name.prefix(3)).pdf")
        func reference() throws -> PDFDocument { try #require(PDFDocument(url: referenceURL)) }
        func locations(_ word: String, in doc: PDFDocument, at index: Int) -> String {
            guard let sheet = doc.page(at: index) else { return "page missing" }
            return doc.findString(word).filter { $0.pages.contains(sheet) }.prefix(8).map { hit in
                let box = hit.bounds(for: sheet)
                let text = hit.attributedString
                let font = text.flatMap {
                    $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
                }
                return String(
                    format: "%.1f/%.1f/w%.1f", box.minX, sheet.bounds(for: .mediaBox).maxY - box.midY, box.width)
                    + "@\(font?.fontName ?? "?")"
            }.joined(separator: ",")
        }
        #expect(abs(size.width - (supplement ? 515.91 : 595.28)) < 0.5)
        #expect(abs(size.height - (english ? 793.70 : supplement ? 728.50 : 841.89)) < 0.5)
        func bounds(_ word: String, on page: PDFPage) throws -> CGRect {
            try #require(pdf.findString(word).first { $0.pages.contains(page) }).bounds(for: page)
        }
        #expect(try bounds("Measuring", on: first).width > 10)
        #expect(try bounds(english ? "Introduction" : "はじめに", on: first).width > 5)
        #expect(try bounds(english ? "baseboard" : "線路", on: first).width > 5)
        let email = try bounds("desk@paper-model.example", on: first)
        #expect(email.maxX < size.width / 2 && email.midY < 190)
        if !english && !supplement {
            let abstract = try #require(first.string?.components(separatedBy: "キーワード").first)
            for boundary in ["3 種類", "2 層", "mm 以内"] { #expect(abstract.contains(boundary)) }
            #expect(try bounds("Model Rail Desk", on: first).width > 20)
            #expect(pdf.findString("0.01 mm").count == 2)
            #expect(pdf.findString("•").count == 3)
            // The hanging bullet can deepen PDFKit's line selection. Its top still
            // gives the relative height of the same body type in the two columns.
            let leftStart = try bounds("鉄道の紙模型には", on: first)
            let rightStart = try bounds("測定値を", on: first)
            #expect(abs(rightStart.maxY - leftStart.maxY - 29.72) < 1.5)
            let second = try #require(pdf.page(at: 1))
            let continuation = try bounds("では薄紙と中厚紙", on: second)
            let tex = try reference()
            let texSecond = try #require(tex.page(at: 1))
            let word = "では薄紙と中厚紙"
            let texLine = try #require(tex.findString(word).first { $0.pages.contains(texSecond) }).bounds(
                for: texSecond)
            let top = size.height - continuation.midY
            let texTop = texSecond.bounds(for: .mediaBox).height - texLine.midY
            func columnStarts(_ sheet: PDFPage) -> String {
                // Separate an extra line carried across the column break from a shifted top margin.
                let box = sheet.bounds(for: .mediaBox)
                return [box.minX, box.midX].map { x in
                    let area = CGRect(x: x, y: box.maxY - 140, width: box.width / 2, height: 90)
                    let lines = sheet.selection(for: area)?.selectionsByLine() ?? []
                    let starts = lines.map { ($0, $0.bounds(for: sheet)) }.sorted { $0.1.midY > $1.1.midY }
                    return starts.prefix(3).map { line, rect in
                        String(format: "%.1f", box.maxY - rect.midY) + "@"
                            + String((line.string ?? "").prefix(14)).debugDescription
                    }.joined(separator: ",")
                }.joined(separator: " / ")
            }
            func inkTop(_ deck: PDFDocument, on sheet: PDFPage) -> String {
                guard let ink = try? printedInk(of: word, in: deck, on: sheet) else { return "?" }
                return String(format: "%.2f", sheet.bounds(for: .mediaBox).maxY - ink.maxY)
            }
            #expect(
                continuation.minX > size.width / 2 && abs(top - texTop) < 4,
                "p2 続き view=\(locations(word, in: result.viewDocument, at: 1)) saved=\(locations(word, in: pdf, at: 1)) TeX=\(locations(word, in: tex, at: 1)) 段頭=\(columnStarts(second)) TeX段頭=\(columnStarts(texSecond)) 墨上端=\(inkTop(pdf, on: second))/\(inkTop(tex, on: texSecond))"
            )
            let entry = try bounds("模型線路係", on: second)
            // An inline citation must not satisfy the check for the printed bibliography label.
            #expect(
                pdf.findString("[1]").contains { match in
                    guard match.pages.contains(second) else { return false }
                    let label = match.bounds(for: second)
                    return label.maxX <= entry.minX + 1 && abs(label.midY - entry.midY) < 3
                })
        }
        if english {
            #expect(pdf.findString("•").count == 3)
            #expect(try bounds("Method", on: first).midX < size.width / 2)
            #expect(try bounds("a thicker core", on: first).minX > size.width / 2)
            let second = try #require(pdf.page(at: 1))
            #expect(try bounds("the crease opens slightly", on: second).maxX < size.width / 2)
        }
        if supplement {
            // The translation and the notes repeat the daggers farther down the page.
            let tex = try reference()
            let texPage = try #require(tex.page(at: 0))
            let marks = tex.findString("††").filter { $0.pages.contains(texPage) }.map { $0.bounds(for: texPage) }
            let texMark = try #require(
                marks.max { $0.midY < $1.midY }, "実 TeX の1ページ目の †=\(locations("†", in: tex, at: 0))")
            let texTop = texPage.bounds(for: .mediaBox).height - texMark.midY
            #expect(
                pdf.findString("††").contains { match in
                    guard match.pages.contains(first) else { return false }
                    let mark = match.bounds(for: first)
                    return abs(mark.minX - texMark.minX) < 2 && abs(size.height - mark.midY - texTop) < 4
                        && mark.width > 6
                },
                "p1 †† view=\(locations("††", in: result.viewDocument, at: 0)) saved=\(locations("††", in: pdf, at: 0)) singles=\(locations("†", in: pdf, at: 0)) TeX=\(locations("††", in: tex, at: 0))"
            )
            #expect(try bounds("部品はすべて", on: first).minX > size.width / 2)
            let last = try #require(pdf.page(at: pdf.pageCount - 1))
            #expect(try bounds("A folded card", on: last).midY > size.height - 95)
            #expect(pdf.findString("A folded card").allSatisfy { $0.pages.contains(last) })
            let footer = try bounds("電子情報通信学会論文誌", on: first)
            #expect(abs(size.height - footer.midY - 675) < 6)
            #expect((last.string ?? "").contains("電子情報通信学会論文誌") == false)
            let second = try #require(pdf.page(at: 1))
            #expect(try bounds("電子情報通信学会論文誌", on: second).midX > size.width / 2)
        } else {
            let header = try bounds(english ? "FUNDAMENTALS" : "情報処理学会論文誌", on: first)
            #expect(abs(size.height - header.midY - (english ? 50 : 35)) < 6)
            let footer = try bounds(english ? "Copyright" : "Information Processing Society", on: first)
            #expect(abs(size.height - footer.midY - (english ? 761 : 803)) < 6)
        }
    }
}

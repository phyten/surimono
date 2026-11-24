import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXConferencePrintingTests {
    @Test("二段組の組版済み段落を保存し直しても左段の全文が右段より先に読める", .timeLimit(.minutes(1)))
    func composedColumnOrder() async throws {
        let left = "The narrow rail holds the first sheet in place. We mark its edge and repeat the trial."
        let right = "A brass stop holds the second sheet in place. We trace its edge and check the result."
        let source = #"""
            \documentclass[twocolumn]{article}\sloppy\begin{document}
            \noindent \#(left)\par\columnbreak\noindent \#(right)\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let fragment = LaTeXConverter.convert(source)
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        let paginator = WebPaginator()
        paginator.collectsLatinLineDiagnostics = true
        let result = try await paginator.paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 23),
            allowsJavaScript: false, composesLaTeXParagraphs: true, latexFlow: true, timeout: .seconds(15))
        let json = try #require(paginator.latinLineDiagnostics)
        let diagnostic = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        try #require(diagnostic["composed"] as? Int == 2)

        let data = try #require(result.document.dataRepresentation())
        let pdf = try #require(PDFDocument(data: data))
        try #require(pdf.pageCount == 1)
        let page = try #require(pdf.page(at: 0))
        let leftStart = try #require(pdf.findString("The narrow rail").first).bounds(for: page)
        let rightStart = try #require(pdf.findString("A brass stop").first).bounds(for: page)
        #expect(leftStart.maxX < rightStart.minX)
        #expect(abs(leftStart.minY - rightStart.minY) < 1)
        let text = try #require(page.string)
        #expect(text.filter(\.isLetter) == (left + right).filter(\.isLetter))
    }

    @Test(
        "学会原稿の査読番号は余白に独立して刷り、完成版でも本文を単語で検索できる", .timeLimit(.minutes(1)),
        arguments: [
            #"\usepackage{neurips_2026}"#, #"\usepackage[main,final]{neurips_2026}"#,
            #"\usepackage{iclr2027_conference,times}"#, #"\usepackage{iclr2027_conference,times}\iclrfinalcopy"#,
        ])
    func reviewFurniture(_ preamble: String) async throws {
        let tex =
            #"\documentclass{article}"# + preamble + #"""
                \title{Spacing study}\author{Rail desk}
                \begin{document}\maketitle
                \begin{abstract}Calibrated spacers.\end{abstract}
                \section*{Results}Repeatable measurement.
                \newpage Second sheet.\end{document}
                """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        settings.options.latexFurniture = .style
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings)
        let pdf = result.logicalDocument
        #expect(pdf.pageCount == 2)
        let page = try #require(pdf.page(at: 0))
        let second = try #require(pdf.page(at: 1))
        func bounds(_ word: String, on page: PDFPage) throws -> CGRect {
            try #require(pdf.findString(word, withOptions: .caseInsensitive).first { $0.pages.contains(page) }).bounds(
                for: page)
        }
        let abstract = try bounds("Calibrated", on: page)
        let body = try bounds("Repeatable", on: page)
        #expect(body.minX >= 107 && body.minX < 110)
        #expect(abstract.minX > body.minX)
        let iclr = preamble.contains("iclr")
        let final = preamble.contains("final")
        let margin = CGRect(x: 65, y: 55, width: 37, height: 700)
        let numbers = page.selection(for: margin)?.string ?? ""
        if final {
            #expect(numbers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else if iclr {
            let zero = try bounds("000", on: page)
            let one = try bounds("001", on: page)
            #expect(abs(zero.minX - 73.13) < 1)
            #expect(abs(zero.midY - one.midY - 11.955) < 0.5)
            #expect(abs(try bounds("054", on: second).midY - zero.midY) < 0.5)
        } else {
            let first = try bounds("1", on: page)
            #expect(abs(first.maxX - 98.04) < 1)
            #expect(abs(first.minY - abstract.minY) < 3)
            let title = try bounds("Spacing", on: page)
            #expect(
                page.selection(for: CGRect(x: 65, y: title.minY, width: 37, height: title.height))?.string?.isEmpty
                    != false)
            #expect((second.selection(for: margin)?.string ?? "").contains("4"))
        }
        if iclr {
            let header =
                final
                ? "Published as a conference paper at ICLR 2027" : "Under review as a conference paper at ICLR 2027"
            let reading = try await ReadingPDFExporter.document(
                from: result.viewDocument, entries: [], title: "Spacing study", furniture: result.viewFurniture)
            for index in 0..<2 {
                let printed = try #require(reading.page(at: index))
                #expect(printed.string?.contains(header) == true)
                // This end of the rule has no header glyphs. Its 0.4pt stroke covers part of a pixel.
                let ink = try (752...753).map { try RenderingFixtures.pixel(printed, x: 490, y: $0)[0] }
                #expect(ink.min() ?? 255 < 230)
                #expect(try RenderingFixtures.pixel(printed, x: 505, y: 752)[0] > 245)
                let lines = try #require(result.viewFurniture[index]?.lines)
                #expect(lines.top == [header, "", ""])
                #expect(abs(lines.headRule - 0.3985) < 0.001)
                #expect(lines.bottom == ["", String(index + 1), ""])
            }
        } else {
            #expect(result.viewFurniture[0]?.lines.isEmpty ?? true)
            #expect(result.viewFurniture[1]?.lines.bottom == ["", "2", ""])
            #expect((page.string ?? "").contains("NeurIPS 2026"))
        }
    }

    @Test(
        "二段組の投稿原稿と最終稿で検索、査読用の余白、柱、脚注を確認する", .timeLimit(.minutes(1)),
        arguments: [
            "115-style-icml", "116-style-icml-accepted", "119-style-cvpr", "120-style-cvpr-final",
            "121-style-acl", "122-style-acl-final", "123-style-aaai", "124-style-aaai-final",
        ])
    func columnFurniture(_ name: String) async throws {
        let corpus = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { file, _ in file.deletingLastPathComponent() }
            .appendingPathComponent("Snapshots/corpus/latex")
        let input = corpus.appendingPathComponent(name + "/main.tex")
        var source = try String(contentsOf: input, encoding: .utf8)
        if name == "119-style-cvpr" {
            source = source.replacingOccurrences(of: #"\def\confName"#, with: #"\def\paperID{732}\def\confName"#)
        }
        let acl = name.contains("-acl")
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(
            layout: acl ? .a4Single : .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        settings.options.latexFurniture = .style
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(source.utf8), format: .latex), settings: settings)
        let pdf = result.logicalDocument
        let first = try #require(pdf.page(at: 0))
        let second = try #require(pdf.page(at: 1))
        func bounds(_ word: String, on page: PDFPage) throws -> CGRect {
            try #require(pdf.findString(word).first { $0.pages.contains(page) }).bounds(for: page)
        }
        #expect(try bounds("Measuring", on: first).width > 10)
        #expect(try bounds("baseboard", on: first).width > 10)
        if name.contains("-cvpr") {
            // A clipped glyph can be invisible on the page and still duplicate a searchable list marker.
            #expect(pdf.findString("•").count == 3)
        }
        if name.contains("-aaai") {
            let number = try bounds("(1)", on: first)
            let equation =
                first.selection(for: CGRect(x: number.minX - 155, y: number.minY, width: 150, height: number.height))?
                .string ?? ""
            for glyph in ["=", "+", "(", "−", "1", ")", ","] { #expect(equation.contains(glyph)) }
            let abstractEnd = try bounds("given rail height.", on: first)
            let introduction = try bounds("Introduction", on: first)
            // PDFKit reports glyph selection centres. The two reference gaps
            // differ because the submission notice reserves two more lines.
            let referenceGap: CGFloat = name.hasSuffix("-final") ? 31.97 : 27.97
            #expect(abs(abstractEnd.midY - introduction.midY - referenceGap) < 1.2)
        }
        if name == "121-style-acl" {
            let reading = try await ReadingPDFExporter.document(
                from: result.viewDocument, entries: [], title: "", furniture: result.viewFurniture)
            let page = try #require(reading.page(at: 0))
            let text = try #require(page.string)
            let anchors = [
                "Paper models of railways", "This note reports", "Section 2 describes the slot",
                "motivated the layer model", "The slot was cut into", "Each spacer was inserted",
            ]
            let offsets = try anchors.map { phrase in
                try #require(text.range(of: phrase)).lowerBound.utf16Offset(in: text)
            }
            #expect(offsets.prefix(3).elementsEqual(offsets.prefix(3).sorted()))
            #expect(offsets.suffix(3).elementsEqual(offsets.suffix(3).sorted()))
            // PDFKit can group the two columns into horizontal bands across a spanning title
            // or folio, even when the PDF paints each entire column in source order.
            withKnownIssue("中央の題名とノンブルを含むACLのページでPDFKitが左右の段を混在させる", isIntermittent: true) {
                #expect(offsets == offsets.sorted())
            }
        }
        if name == "120-style-cvpr-final" || name == "122-style-acl-final" {
            let expected: [CGFloat] = acl ? [198.05, 397.23] : [182.18, 387.03]
            for (author, x) in zip(["Model Rail Desk", "Card Stock Bench"], expected) {
                let matches = pdf.findString(author).filter { $0.pages.contains(first) }
                #expect(matches.contains { abs($0.bounds(for: first).midX - x) < 1.5 })
            }
            let email = try bounds("desk@paper-model.example", on: first)
            #expect(abs(email.width - (acl ? 172.15 : 129.12)) < 1.5)
        }
        let leftMargin = CGRect(x: 6, y: 70, width: 39, height: 650)
        let leftInk = first.selection(for: leftMargin)?.string ?? ""
        let icml = name.contains("-icml")
        let review = name == "119-style-cvpr" || name == "121-style-acl"
        if icml {
            let blind = name == "115-style-icml"
            let author = try bounds(blind ? "Anonymous Authors" : "Model Rail Desk", on: first)
            #expect(abs(author.minX - (blind ? 249.48 : 214.98)) < 1)
            #expect(try bounds("Pressing twice", on: first).midX > 306)
            #expect(try bounds("made the crease", on: second).midX < 306)
            if !blind {
                #expect(abs(try bounds("Card Stock Bench", on: first).minX - 297.60) < 1)
            }
        }
        if icml || acl || name == "120-style-cvpr-final" {
            let figure = try bounds("Side view", on: second)
            let table = try bounds("Measured and predicted", on: second)
            let separation: CGFloat = icml ? 44.83 : (acl ? 48.30 : 45.64)
            #expect(abs(figure.midY - table.midY - separation) < 1.5)
        }
        if review {
            let expectedLeft: CGFloat = acl ? 25.51 : 37.24
            let expectedRight: CGFloat = acl ? 579.72 : 584.72
            let number = try bounds("001", on: first)
            #expect(abs(number.maxX - expectedLeft) < 1)
            let rightMargin = CGRect(x: expectedRight - 16, y: 110, width: 19, height: 490)
            let rightLines = first.selection(for: rightMargin)?.selectionsByLine() ?? []
            #expect(
                rightLines.contains { line in
                    line.string?.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /[0-9]{3}/) != nil
                        && abs(line.bounds(for: first).maxX - expectedRight) < 1
                })
            if acl {
                let heading = try bounds("Abstract", on: first)
                #expect(abs(number.midY - heading.midY) < 3)
            } else {
                let banner = try bounds("CVPR 2027 Submission #732", on: second)
                #expect(abs(banner.midY - (792 - 44)) < 4)
                let corners = pdf.findString("CVPR").filter { $0.pages.contains(second) }.map { $0.bounds(for: second) }
                for x: CGFloat in [29.75, 577.55] {
                    #expect(corners.contains { abs($0.midX - x) < 1 && abs($0.midY - (792 - 28)) < 4 })
                }
            }
        } else if name == "115-style-icml" {
            let zero = try bounds("000", on: first)
            #expect(abs(zero.minX - 25.55) < 1)
            #expect(abs(zero.midY - (try bounds("001", on: first)).midY - 11.955) < 0.5)
            #expect(abs(zero.midY - (try bounds("055", on: second)).midY) < 0.5)
        } else {
            #expect(leftInk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(pdf.findString("CONFIDENTIAL REVIEW COPY").isEmpty)
        }
        if review || icml {
            #expect(result.viewFurniture[0]?.lines.bottom == ["", "1", ""])
            #expect(result.viewFurniture[1]?.lines.bottom == ["", "2", ""])
        } else {
            #expect(result.viewFurniture[0]?.lines.isEmpty ?? true)
            #expect(result.viewFurniture[1]?.lines.isEmpty ?? true)
        }
        if icml {
            #expect(result.viewFurniture[0]?.lines.headRule == 0)
            let header = try #require(result.viewFurniture[1]?.lines)
            #expect(header.top == ["", "Measuring Folded Card Spacers", ""])
            #expect(abs(header.headRule - 0.99626) < 0.01)
        }
        let notices = [
            "115-style-icml": "Preliminary", "116-style-icml-accepted": "Proceedings",
            "123-style-aaai": "prohibited", "124-style-aaai-final": "Copyright",
        ]
        if let notice = notices[name] {
            let box = try bounds(notice, on: first)
            #expect(box.minY < 160 && box.maxX < 295)
        }
    }
}

@MainActor
struct ConferenceReviewDrawingTests {
    @Test("連続した 1 の組み合わせでも査読用の三桁を同じ字幅で右端に揃える")
    func digitAdvances() async throws {
        let single = LaTeXFlowLayout.Piece(
            slice: .init(strip: 0, start: 0, end: 30, width: 295.3125), x: 0, y: 0, scale: 1)
        let marks = ConferenceReviewDrawing(style: .blueColumnLines, lines: [[12]], banner: nil, corner: nil)
        let pdf = try await PDFDrawing.document(pageSize: CGSize(width: 612, height: 792)) { context in
            context.beginPDFPage(nil)
            for (row, number) in [1, 11, 111].enumerated() {
                var next = number
                marks.draw(
                    [single], pageIndex: 0, textOrigin: CGPoint(x: 58.5, y: CGFloat(720 - 20 * row)), width: 495,
                    next: &next, in: context)
            }
            context.endPDFPage()
        }
        let page = try #require(pdf.page(at: 0))
        for number in ["001", "011", "111"] {
            let mark = try #require(pdf.findString(number).first).bounds(for: page)
            #expect(abs(mark.minX - 23.95) < 0.15)
            #expect(abs(mark.maxX - 37.24) < 0.15)
        }
    }

    @Test("同じ段の順序を保った断片だけをまとめ、段・縮尺・元の領域の重なりを境界にする")
    func groupedCaptureOffsets() {
        func band(_ strip: Int, _ start: CGFloat, _ y: CGFloat, x: CGFloat = 0, scale: CGFloat = 1)
            -> LaTeXFlowLayout.Piece
        {
            .init(slice: .init(strip: strip, start: start, end: start + 9, width: 60), x: x, y: y, scale: scale)
        }
        let first = band(0, 10, 30)
        let candidate = [first, band(0, 21, 42), band(0, 33, 57)]
        #expect(LaTeXFlowPaginator.captureOffsets(in: candidate, from: 0) == [0, 1, 4])
        for boundary in [
            band(1, 45, 70), band(0, 45, 70, x: 90), band(0, 45, 70, scale: 0.8),
            band(0, 39, 70), band(0, 45, 60),
        ] {
            #expect(LaTeXFlowPaginator.captureOffsets(in: candidate + [boundary], from: 0) == [0, 1, 4])
        }
    }

    @Test("短い柱は保ち、規定の幅または高さを超えた学会の柱だけを代替文で刷る")
    func runningTitleLimit() async throws {
        let paper = CGSize(width: 612, height: 792)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        for (title, expected) in [
            ("Measuring Folded Card Spacers", "Measuring Folded Card Spacers"),
            (String(repeating: "Folded card ", count: 20), "Title Suppressed Due to Excessive Size"),
            ("Été", "Title Suppressed Due to Excessive Size"),
        ] {
            let source =
                #"\documentclass{article}\usepackage{icml2026}\icmltitlerunning{"# + title
                + #"}\begin{document}Paper.\end{document}"#
            let info = try #require(LaTeXConverter.convert(source).latexClass)
            var settings = RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
            settings.options.latexFurniture = .style
            settings.applyLaTeXPage(info)
            let active = LaTeXPageReferences.Page(info.pageNumbers)
            let pdf = try await PDFDrawing.document(pageSize: paper) { context in
                context.beginPDFPage(nil)
                PageFurnitureDrawing.draw(
                    active.lines, in: CGRect(origin: .zero, size: paper),
                    margins: .init(top: 67.07, left: 55.44, bottom: 76.93, right: 70.56), scale: 1,
                    latexFooter: settings.latexFooter, context: context)
                context.endPDFPage()
            }
            #expect(pdf.page(at: 0)?.string?.contains(expected) == true)
        }
    }

    @Test("段の内側が入れ替わっても奇偶ページ共に段の外の同じ距離に査読番号を描く", arguments: [false, true])
    func outerCoordinates(blue: Bool) async throws {
        let originX: CGFloat = blue ? 58.5 : 70.866
        let width: CGFloat = blue ? 495 : 453.544
        let column: CGFloat = blue ? 236.25 : 218.27
        let ratio = WebPaginator.printPixelsPerPoint
        let slice = LaTeXFlowLayout.Slice(strip: 0, start: 0, end: 30, width: column * ratio)
        let pieces = [
            LaTeXFlowLayout.Piece(slice: slice, x: 0, y: 0, scale: 1),
            LaTeXFlowLayout.Piece(slice: slice, x: (width - column) * ratio, y: 0, scale: 1),
        ]
        let marks = ConferenceReviewDrawing(
            style: blue ? .blueColumnLines : .grayColumnLines, lines: [[12]], banner: nil, corner: nil)
        var next = 1
        let pdf = try await PDFDrawing.document(pageSize: CGSize(width: 612, height: 792)) { context in
            for page in 0..<2 {
                context.beginPDFPage(nil)
                marks.draw(
                    pieces, pageIndex: page, textOrigin: CGPoint(x: originX, y: 720), width: width, next: &next,
                    in: context)
                context.endPDFPage()
            }
        }
        for (i, text) in ["001", "002", "003", "004"].enumerated() {
            let selection = try #require(pdf.findString(text).first)
            let page = try #require(pdf.page(at: i / 2))
            #expect(selection.pages == [page])
            let x: CGFloat
            if blue { x = i.isMultiple(of: 2) ? 37.24 : 584.72 } else { x = i.isMultiple(of: 2) ? 25.51 : 579.72 }
            #expect(abs(selection.bounds(for: page).maxX - x) < 0.5)
        }
    }
}

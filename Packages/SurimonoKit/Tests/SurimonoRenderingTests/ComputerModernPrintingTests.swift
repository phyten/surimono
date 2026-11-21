import PDFKit
import SurimonoCore
import SurimonoFormats
import SurimonoRendering
import Testing

@MainActor
struct ComputerModernPrintingTests {
    private func printed(_ body: String, documentClass: String = "article") async throws -> PDFDocument {
        // Without a page number, only the sample itself can introduce a font into the PDF.
        let source =
            #"\documentclass{\#(documentClass)}\pagestyle{empty}\begin{document}\noindent "#
            + body + #"\end{document}"#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(source.utf8), format: .latex),
            settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let bytes = try #require(result.logicalDocument.dataRepresentation())
        return try #require(PDFDocument(data: bytes))
    }

    @Test("本文の fi と ffi は印刷した PDF から元の文字列として検索・コピーできる", .timeLimit(.minutes(1)))
    func ligatureSearch() async throws {
        let pdf = try await printed(#"A first office proof. \textsc{Gauge board}."#)
        let text = try #require(pdf.page(at: 0)?.string)
        #expect(text.contains("first office"))
        #expect(pdf.findString("first").count == 1)
        #expect(pdf.findString("office").count == 1)
        #expect(pdf.findString("Gauge board").count == 1)
    }

    @Test(
        "指定のないキリル文字とギリシャ文字を同梱書体で刷る", .timeLimit(.minutes(1)),
        arguments: ["Мерная доска", "Η σανίδα μέτρησης"])
    func languages(_ text: String) async throws {
        let pdf = try await printed(text)
        #expect(pdf.findString(text).count == 1)
        let data = try #require(pdf.dataRepresentation())
        let fonts = String(decoding: data, as: UTF8.self)
        let faces = fonts.matches(of: #/\/BaseFont\s*\/(?:[A-Z]{6}\+)?([^/\s<>]+)/#).map { String($0.output.1) }
        #expect(Set(faces) == ["CMUSerif-Roman"])
    }

    @Test("箇条書きの黒丸は最初の行の左に一度だけ現れ、本文の前にコピーされる", .timeLimit(.minutes(1)))
    func bulletOrder() async throws {
        let pdf = try await printed(
            #"\begin{itemize}\item Cut across the grain.\item Keep the straight edge.\end{itemize}"#,
            documentClass: "scrbook")
        let page = try #require(pdf.page(at: 0))
        let text = try #require(page.string)
        #expect(text.contains("• Cut across the grain."))
        #expect(text.contains("• Keep the straight edge."))
        let bullets = pdf.findString("•")
        try #require(bullets.count == 2)
        let label = bullets[0].bounds(for: page)
        let body = try #require(pdf.findString("Cut").first).bounds(for: page)
        #expect(label.maxX < body.minX && abs(label.midY - body.midY) < 1)
    }

    @Test("和文クラスの黒丸は本文に先行し、Latin Modern の原寸で刷られる", .timeLimit(.minutes(1)), arguments: ["ltjsarticle", "ltjarticle"])
    func japaneseBullet(_ documentClass: String) async throws {
        let pdf = try await printed(#"\begin{itemize}\item 紙を折る。\end{itemize}"#, documentClass: documentClass)
        let page = try #require(pdf.page(at: 0))
        let text = try #require(page.string)
        let bullet = try #require(text.range(of: "•"))
        let body = try #require(text.range(of: "紙"))
        #expect(bullet.upperBound <= body.lowerBound)
        let ink = try printedInk(of: "•", in: pdf, on: page)
        #expect(abs(ink.width - 2.88) <= 0.3)
        #expect(abs(ink.height - 2.88) <= 0.3)
    }

    @Test("小型大文字でも数字・句読点を本文のライニング数字と同じ書体で刷る", .timeLimit(.minutes(1)))
    func liningFigures() async throws {
        let pdf = try await printed(#"\textsc{19.,} 19.,"#)
        let page = try #require(pdf.page(at: 0))
        let matches = pdf.findString("19.,")
        try #require(matches.count == 2)
        #expect(abs(matches[0].bounds(for: page).width - matches[1].bounds(for: page).width) < 0.05)
        let data = try #require(pdf.dataRepresentation())
        let faces = String(decoding: data, as: UTF8.self).matches(of: #/\/BaseFont\s*\/(?:[A-Z]{6}\+)?([^/\s<>]+)/#)
        #expect(Set(faces.map { String($0.output.1) }) == ["CMUSerif-Roman"])
    }

    @Test("画面の実測で AV のカーニングと本文の小型大文字が効く", .timeLimit(.minutes(1)))
    func shapedAdvances() async throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(
            fragment: HTMLFragment(body: "<span id='sample'>AV</span>"), format: .latex, theme: theme)
        let probe = """
            const el = document.querySelector('#sample');
            el.style.cssText = 'display:inline-block;white-space:pre;font-size:100px;word-spacing:0';
            await document.fonts.load('100px "Surimono Computer Modern"', 'AVabc');
            function width(text) {
                el.textContent = text;
                return el.getBoundingClientRect().width;
            }
            const kern = width('AV'), separate = width('A') + width('V'), plain = width('abc');
            el.style.fontVariantCaps = 'small-caps';
            return JSON.stringify([kern, separate, plain, width('abc')]);
            """
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: probe, timeout: .seconds(15))
        let json = try #require(result.preparationResult)
        let values = try JSONDecoder().decode([Double].self, from: Data(json.utf8))
        try #require(values.count == 4)
        // CMU Roman has 1000 units/em. These are its shaped advances including the AV kern and smcp glyphs.
        for (width, expected) in zip(values, [138.9, 150.0, 152.7, 178.4]) {
            #expect(abs(width - expected) < 0.1)
        }
    }

    @Test("本文・等幅・サンセリフの形と太さの指定を実際の書体に切り替える", .timeLimit(.minutes(1)))
    func faces() async throws {
        let pdf = try await printed(
            #"""
            Roman \textbf{Bold} \textit{Italic} \textbf{\textit{Both}} \textsl{Slanted} \textbf{\textsl{Boldslant}}.
            \texttt{Mono \textbf{Bold} \textit{Italic} \textsl{Oblique} \textbf{\textit{Both}}}.
            \textsf{Sans \textbf{Bold} \textit{Oblique} \textbf{\textsl{Both}}}.
            """#)
        let fonts = String(decoding: try #require(pdf.dataRepresentation()), as: UTF8.self)
        for face in [
            "CMUSerif-Roman", "CMUSerif-Bold", "CMUSerif-Italic", "CMUSerif-BoldItalic",
            "CMUSerif-RomanSlanted", "CMUSerif-BoldSlanted", "CMUTypewriter-Regular", "CMUTypewriter-Bold",
            "CMUTypewriter-Italic", "CMUTypewriter-Oblique", "CMUTypewriter-BoldItalic",
            "CMUSansSerif", "CMUSansSerif-Bold", "CMUSansSerif-Oblique", "CMUSansSerif-BoldOblique",
        ] {
            #expect(fonts.contains("+\(face)/") || fonts.contains("+\(face) "), "\(face)")
        }
    }
}

import PDFKit
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXMarginInkPrintingTests {
    @Test("ページの途中でも独立した箱の下にはみ出す文字を一度だけ刷る", .timeLimit(.minutes(1)))
    func interiorOverhang() async throws {
        let html = """
            <style>* { margin:0; padding:0 } body { font:8px/10px monospace }
            section { height:30px; position:relative }
            span { position:absolute; top:40px; left:75px }</style>
            <p>FIRST</p><section>MIDDLE<span>EXTENSION</span></section><p>LAST</p>
            """
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 250, height: 180),
            margins: .init(top: 30, left: 30, bottom: 30, right: 30), allowsJavaScript: false,
            checksVerticalLaTeXInk: true)
        #expect(result.document.pageCount == 1)
        let page = try #require(result.document.page(at: 0))
        for word in ["FIRST", "MIDDLE", "EXTENSION", "LAST"] {
            #expect(result.document.findString(word).count == 1)
        }
        let middle = try #require(result.document.findString("MIDDLE").first)
        let lower = try #require(result.document.findString("EXTENSION").first)
        #expect(middle.bounds(for: page).midY - lower.bounds(for: page).midY > 25)
    }

    @Test("通常の一段文書ではみ出す箱を見つけ、上下の余白にも文字を一度だけ刷る", .timeLimit(.minutes(1)))
    func realVerticalOverhang() async throws {
        let html = """
            <style>html,body,p{margin:0;padding:0}body{font:8px/10px monospace}
            .box{height:100px;position:relative}.box span{position:absolute;left:0}
            section{break-before:page}</style>
            <div class="box">BODY<span class="high">ABOVE</span><span class="low">BELOW</span></div>
            <section>SECOND</section>
            """
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 200, height: 120),
            margins: .init(top: 20, left: 20, bottom: 20, right: 20), allowsJavaScript: false,
            preparationScript:
                "document.querySelector('.high').style.top='-17px'; document.querySelector('.low').style.bottom='-17px';",
            checksVerticalLaTeXInk: true)
        #expect(result.issues.isEmpty)
        try #require(result.document.pageCount == 2)
        let first = try #require(result.document.page(at: 0))
        for (word, above) in [("ABOVE", true), ("BELOW", false)] {
            let matches = result.document.findString(word)
            try #require(matches.count == 1)
            let match = try #require(matches.first)
            #expect(match.pages.first == first)
            let bounds = match.bounds(for: first)
            #expect(above ? bounds.minY > 100 : bounds.maxY < 20)
        }
        #expect(result.document.page(at: 1)?.string?.contains("SECOND") == true)
    }

    @Test("通常印刷の余白に置いた番号は印刷され、二枚目の行位置とリンク先は本文幅のまま保たれる", .timeLimit(.minutes(1)))
    func nativeMarginInk() async throws {
        let html = """
            <style>html,body{margin:0;padding:0}body{font:12px/16px monospace}
            p{margin:0}pre{position:relative;margin:0;border:1px solid}
            pre::before{content:'781';position:absolute;right:calc(100% + 3px)}
            section{break-before:page}</style>
            <p>Firstline</p><pre>numbered</pre>
            <section><p>Secondpage</p><p>This repeated line verifies that the surrounding physical
            margins do not alter our line breaks. <a href="https://example.org/measure">Lastword</a></p></section>
            """
        let size = CGSize(width: 330, height: 260)
        let margins = WebPaginator.Margins(top: 41, left: 64, bottom: 39, right: 55)
        func printed(ink: Bool) async throws -> PDFDocument {
            let paginator = WebPaginator()
            let result = try await paginator.paginateWithResult(
                .html(html, baseURL: nil), pageSize: size, margins: margins, allowsJavaScript: false,
                latexMarginInk: ink, checksVerticalLaTeXInk: ink)
            #expect(paginator.printStartCount == 1)
            return result.document
        }
        let baseline = try await printed(ink: false)
        let withInk = try await printed(ink: true)
        try #require(baseline.pageCount == 2 && withInk.pageCount == 2)
        let first = try #require(withInk.page(at: 0))
        let number = try #require(withInk.findString("781").first)
        #expect(number.bounds(for: first).maxX < 64)
        for (index, needle) in [(0, "Firstline"), (1, "Secondpage"), (1, "Lastword")] {
            func bounds(in pdf: PDFDocument) throws -> CGRect {
                let page = try #require(pdf.page(at: index))
                let match = try #require(pdf.findString(needle).first)
                #expect(match.pages.first == page)
                return match.bounds(for: page)
            }
            let old = try bounds(in: baseline)
            let new = try bounds(in: withInk)
            #expect(abs(old.minX - new.minX) < 1.5 && abs(old.minY - new.minY) < 1.5)
        }
        func link(in pdf: PDFDocument) throws -> PDFAnnotation {
            let page = try #require(pdf.page(at: 1))
            return try #require(page.annotations.first { $0.url?.lastPathComponent == "measure" })
        }
        let previous = try link(in: baseline)
        let preserved = try link(in: withInk)
        #expect(abs(previous.bounds.midX - preserved.bounds.midX) < 1.5)
        #expect(abs(previous.bounds.midY - preserved.bounds.midY) < 1.5)
    }
}

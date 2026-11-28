import AppKit
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct VerticalLaTeXPagesTests {
    private func prepare(_ source: String, css: String = "") async throws -> PreparedRender {
        _ = NSApplication.shared
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let theme = PrintTheme(
            id: style.id, name: style.name, css: style.css + "\n" + css, formats: style.formats, flow: style.flow)
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""),
            options: PrintOptions().defaults(for: .latex))
        return try await DocumentRenderer().prepare(
            DocumentSource(data: Data(source.utf8), format: .latex), settings: settings)
    }

    @Test("縦組みの tbook は章の頁の左上と偶数頁の右上にノンブル、偶数頁の左に章の柱、奇数頁の右に節の柱を刷る", .timeLimit(.minutes(1)))
    func bookHeads() async throws {
        let prepared = try await prepare(
            #"""
            \documentclass{tbook}
            \begin{document}
            \chapter{春}\section{庭}本文。
            \newpage
            \section{池}本文。
            \newpage
            \section{森}本文。
            \end{document}
            """#)
        try #require(prepared.logicalDocument.pageCount == 3)
        let first = try #require(prepared.viewFurniture[0]?.lines)
        let second = try #require(prepared.viewFurniture[1]?.lines)
        let third = try #require(prepared.viewFurniture[2]?.lines)
        #expect(first.top == ["1", "", ""] && first.bottom.allSatisfy(\.isEmpty))
        #expect(second.top[0].contains("春") && second.top[2] == "2")
        #expect(third.top[0] == "3" && third.top[2].contains("森"))
        // On the exported page the number stands above the grid, at its outer edge, inside the paper.
        let reading = try await ReadingPDFExporter.document(
            from: prepared.viewDocument, entries: [], title: "Sample", furniture: prepared.viewFurniture)
        for (index, label, outerLeft) in [(1, "2", false), (2, "3", true)] {
            let page = try #require(reading.page(at: index))
            let media = page.bounds(for: .mediaBox)
            let margins = try #require(prepared.viewFurniture[index]?.margins)
            let number = try #require(
                reading.findString(label).filter { $0.pages.first === page }.map { $0.bounds(for: page) }
                    .first { $0.minY >= media.height - margins.top })
            #expect(number.maxY <= media.height && number.minY - (media.height - margins.top) < 40)
            if outerLeft {
                #expect(abs(number.minX - margins.left) < 2)
            } else {
                #expect(abs(number.maxX - (media.width - margins.right)) < 2)
            }
        }
    }

    @Test("縦組みの tarticle は下の中央に、jlreq の縦組みは上の中央にノンブルを刷る", .timeLimit(.minutes(1)))
    func articleNumbers() async throws {
        let plain = try await prepare(#"\documentclass{tarticle}\begin{document}本文。\end{document}"#)
        #expect(plain.viewFurniture[0]?.lines.bottom == ["", "1", ""])
        let reading = try await ReadingPDFExporter.document(
            from: plain.viewDocument, entries: [], title: "Sample", furniture: plain.viewFurniture)
        let page = try #require(reading.page(at: 0))
        let margins = try #require(plain.viewFurniture[0]?.margins)
        let media = page.bounds(for: .mediaBox)
        let foot = try #require(reading.findString("1").first?.bounds(for: page))
        // Below the grid and centred under it.
        #expect(foot.maxY <= margins.bottom && foot.minY >= 0)
        #expect(abs(foot.midX - (margins.left + (media.width - margins.left - margins.right) / 2)) < 2)
        let jlreq = try await prepare(#"\documentclass[tate]{jlreq}\begin{document}本文。\end{document}"#)
        #expect(jlreq.viewFurniture[0]?.lines.top == ["", "1", ""])
    }

    @Test("縦組みの本は表題と目次を別のページに置き、目次にページ番号を入れ、見出しのページを組版から知る", .timeLimit(.minutes(1)))
    func titleAndContents() async throws {
        let prepared = try await prepare(
            #"""
            \documentclass{tbook}
            \title{題}\author{著}
            \begin{document}
            \maketitle
            \tableofcontents
            \chapter{春}本文。
            \chapter{夏}本文。
            \end{document}
            """#)
        let pdf = prepared.logicalDocument
        try #require(pdf.pageCount == 4)
        #expect(pdf.page(at: 0)?.string?.contains("題") == true)
        let contents = try #require(pdf.page(at: 1)?.string)
        #expect(!contents.contains("題") && contents.contains("春"))
        #expect(!contents.contains("?"))
        let facts = try #require(prepared.facts)
        let pages = facts.headings.compactMap { $0.id.flatMap { facts.headingPages[$0] } }
        #expect(pages == [2, 3])
    }

    @Test("縦組みの別行数式は行の方向に回して置き、幅の広い式が一つずつページを取らない", .timeLimit(.minutes(1)))
    func turnedFormulas() async throws {
        let long = (1...16).map { "a_{\($0)}" }.joined(separator: " + ")
        let prepared = try await prepare(
            #"""
            \documentclass{tarticle}
            \begin{document}
            前の文。
            \begin{equation} s = \#(long) \end{equation}
            \begin{equation} t = \#(long) \end{equation}
            \[ u = \#(long) \]
            後の文。
            \end{document}
            """#, css: ".surimono-vertical .math-display svg { color: #db009f; }")
        let pdf = prepared.logicalDocument
        #expect(pdf.pageCount == 1)
        let page = try #require(pdf.page(at: 0))
        let text = try #require(page.string).filter { !$0.isWhitespace }
        #expect(text.contains("前") && text.contains("後"))
        // Each number is printed once, and none for the unnumbered display.
        #expect(text.components(separatedBy: "(1)").count == 2 && text.components(separatedBy: "(2)").count == 2)
        #expect(!text.contains("(3)"))
        // The formulas' ink runs along the line and stays inside the grid.
        let ink = try #require(try PagePixels(page).bounds { r, g, b in r > g + 100 && b > g + 75 })
        let margins = try #require(prepared.viewFurniture[0]?.margins)
        let media = page.bounds(for: .mediaBox)
        #expect(ink.height > ink.width)
        #expect(ink.minX >= margins.left - 1 && ink.maxX <= media.width - margins.right + 1)
        #expect(ink.minY >= margins.top - 1 && ink.maxY <= media.height - margins.bottom + 1)
    }

    @Test("縦組みの tbook は \\frontmatter と \\mainmatter の直後が段落でもページを分け、前付と本文の番号を分ける", .timeLimit(.minutes(1)))
    func bookMatter() async throws {
        let prepared = try await prepare(
            #"""
            \documentclass{tbook}
            \begin{document}
            \frontmatter
            前付の本文。
            \mainmatter
            本文の冒頭。
            \backmatter
            後付の本文。
            \end{document}
            """#)
        let pdf = prepared.logicalDocument
        try #require(pdf.pageCount == 3)
        // Vertical pages read back one glyph at a time, so distinct characters identify the passages.
        let first = pdf.page(at: 0)?.string ?? ""
        let second = pdf.page(at: 1)?.string ?? ""
        #expect(first.contains("前") && !first.contains("冒"))
        #expect(second.contains("冒") && !second.contains("後") && pdf.page(at: 2)?.string?.contains("後") == true)
        #expect(prepared.viewFurniture[0]?.lines.top.first == "i")
        #expect(prepared.viewFurniture[1]?.lines.top.first == "1")
    }

    @Test("上下二段の縦組みで \\newpage は下段へ、\\clearpage と下段からの \\newpage は次のページへ送る", .timeLimit(.minutes(1)))
    func columnAndPageBreaks() async throws {
        func pages(_ body: String) async throws -> PDFDocument {
            try await prepare("\\documentclass[twocolumn]{tarticle}\\begin{document}\(body)\\end{document}")
                .logicalDocument
        }
        let column = try await pages("上段の本文。\\newpage 下段の本文。")
        #expect(column.pageCount == 1)
        #expect(column.page(at: 0)?.string?.contains("下") == true)
        #expect(try await pages("上段の本文。\\clearpage 次の本文。").pageCount == 2)
        let lower = try await pages("一の本文。\\newpage 二の本文。\\newpage 三の本文。")
        try #require(lower.pageCount == 2)
        #expect(lower.page(at: 1)?.string?.contains("三") == true && lower.page(at: 1)?.string?.contains("二") == false)
    }

    @Test("縦組みでページ参照を書き込んで行が送られたら組み直し、番号を書いた原稿と同じページに段落を置く", .timeLimit(.minutes(1)))
    func referencesReflow() async throws {
        // Each reference grows from "?" to "1000" when filled, pushing the following lines across page cuts.
        func source(_ reference: String) -> String {
            let body = String(repeating: "本文", count: 20)
            let paragraphs = (1...60).map { "\(body)\(String(repeating: reference, count: 10))。M\($0)X" }
            return #"""
                \documentclass{tarticle}
                \begin{document}
                \setcounter{page}{1000}
                \section{始}\label{top}冒頭。

                \#(paragraphs.joined(separator: "\n\n"))
                \end{document}
                """#
        }
        func markers(_ pdf: PDFDocument) -> [[Int]] {
            (0..<pdf.pageCount).map { page in
                let text = (pdf.page(at: page)?.string ?? "").filter { !$0.isWhitespace }
                return (1...60).filter { text.contains("M\($0)X") }
            }
        }
        let referenced = try await prepare(source(#"\pageref{top}"#)).logicalDocument
        let written = try await prepare(source("1000")).logicalDocument
        try #require(written.pageCount > 1)
        #expect(referenced.pageCount == written.pageCount)
        #expect(markers(referenced) == markers(written))
        let text = (0..<referenced.pageCount).map { referenced.page(at: $0)?.string ?? "" }.joined()
        #expect(!text.contains("?"))
    }
}

import AppKit
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct VerticalLaTeXPagesTests {
    private func prepare(_ source: String) async throws -> PreparedRender {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
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
    }

    @Test("縦組みの tarticle は下の中央に、jlreq の縦組みは上の中央にノンブルを刷る", .timeLimit(.minutes(1)))
    func articleNumbers() async throws {
        let plain = try await prepare(#"\documentclass{tarticle}\begin{document}本文。\end{document}"#)
        #expect(plain.viewFurniture[0]?.lines.bottom == ["", "1", ""])
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
            \[ s = \#(long) \]
            \[ t = \#(long) \]
            \[ u = \#(long) \]
            後の文。
            \end{document}
            """#)
        #expect(prepared.logicalDocument.pageCount == 1)
        let text = try #require(prepared.logicalDocument.page(at: 0)?.string)
        #expect(text.contains("前") && text.contains("後"))
    }
}

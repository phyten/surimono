import CoreText
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXJapaneseGridPrintingTests {
    // PDFKit includes the Japanese label's ascent in a selection on the first
    // caption line. The two occurrences of the same initial glyph share an outline.
    private func initialGlyph(in box: CGRect, on page: PDFPage) throws -> CGRect {
        let index = page.characterIndex(at: CGPoint(x: box.minX + 1, y: box.midY))
        try #require((0..<page.numberOfCharacters).contains(index))
        let glyph = page.characterBounds(at: index)
        try #require(!glyph.isEmpty && glyph.intersects(box))
        return glyph
    }

    @Test("和文ラベルを含む行でも欧文の同じ字形から既知のベースライン間隔を読み取れる")
    func mixedCaptionGlyphs() async throws {
        let roman = try #require(NSFont(name: "Times-Roman", size: 9))
        let mincho = try #require(NSFont(name: "HiraMinProN-W3", size: 11))
        let pdf = try await PDFDrawing.document(pageSize: CGSize(width: 180, height: 100)) { context in
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            for (row, text) in ["図 1: Fiberone", "Fibertwo"].enumerated() {
                let line = NSMutableAttributedString(string: text, attributes: [.font: roman])
                if row == 0 { line.addAttribute(.font, value: mincho, range: NSRange(location: 0, length: 1)) }
                context.textPosition = CGPoint(x: 20, y: 75 - CGFloat(row) * 12.951)
                CTLineDraw(CTLineCreateWithAttributedString(line), context)
            }
        }
        let page = try #require(pdf.page(at: 0))
        let first = try #require(pdf.findString("Fiberone").first).bounds(for: page)
        let second = try #require(pdf.findString("Fibertwo").first).bounds(for: page)
        let measured = try initialGlyph(in: first, on: page).maxY - initialGlyph(in: second, on: page).maxY
        #expect(abs(measured - 12.951) < 0.01)
    }

    @Test("和文の級数と行間倍率を変えても実際の PDF の行送りは〇・一ポイント以内に収まる", .timeLimit(.minutes(1)), arguments: ["10pt", "11pt", "spread"])
    func baselineDistances(_ option: String) async throws {
        let size = option == "11pt" ? "11pt" : "10pt"
        let spread = option == "spread" ? 1.15 : 1.0
        let factor = (option == "11pt" ? 1.095 : 1.0) * spread * 72 / 72.27
        let normal = 16 * factor
        let small = 13 * factor
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass[a4paper,\#(size)]{ltjsarticle}
                \usepackage[margin=25mm]{geometry}
                \usepackage{listings,tabularx,caption}
                \linespread{\#(spread)}
                \captionsetup{font=small}
                \begin{document}
                \begin{abstract}Asterone\\Astertwo\end{abstract}
                \section{紙帯}Paperone\\Papertwo
                \begin{lstlisting}[basicstyle=\small\ttfamily]
                ridgeone
                ridgetwo
                \end{lstlisting}
                \noindent\begin{tabularx}{\linewidth}{p{32mm}p{57mm}X}
                Cellone&細い帯&Spare\\Celltwo&厚い帯&Edge
                \end{tabularx}
                \begin{itemize}\item Listone\\Listtwo\end{itemize}
                \begin{figure}[h]\centering\rule{12mm}{2mm}
                \caption{Fiberone\\Fibertwo}\end{figure}
                \end{document}
                """#.utf8), format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let result = try await DocumentRenderer().prepare(source, settings: settings)
        let pdf = result.logicalDocument
        // The fixed-width JFM glue must still paint the source space in the exported label.
        let bytes = try #require(pdf.dataRepresentation())
        let saved = try #require(PDFDocument(data: bytes))
        #expect(saved.findString("図 1").count == 1)
        #expect(pdf.pageCount == 1)
        let page = try #require(pdf.page(at: 0))
        func bounds(_ text: String) throws -> CGRect {
            let selection = try #require(pdf.findString(text).first)
            try #require(selection.pages.first == page)
            return selection.bounds(for: page)
        }
        for (first, second, pitch): (String, String, CGFloat) in [
            ("Paperone", "Papertwo", normal), ("ridgeone", "ridgetwo", small), ("Cellone", "Celltwo", normal),
            ("Asterone", "Astertwo", small), ("Listone", "Listtwo", normal), ("Fiberone", "Fibertwo", small),
        ] {
            let distance =
                try initialGlyph(in: bounds(first), on: page).maxY - initialGlyph(in: bounds(second), on: page).maxY
            #expect(abs(distance - pitch) < 0.1, "\(first): \(distance) for \(pitch)")
        }
        let flexibleColumn = try bounds("Spare").minX
        #expect(
            abs(flexibleColumn - (70.866 + 89 * 72 / 25.4 + 5 * 6 * (size == "11pt" ? 1.095 : 1) * 72 / 72.27)) < 1.5)
    }

    @Test("和文の文献番号と最初の項目が同じ基線に乗り、箇条書きの丸を文字として検索できる", .timeLimit(.minutes(1)))
    func bibliographyLabelAndBullet() async throws {
        let tex = #"""
            \documentclass{ltjsarticle}\begin{document}
            \begin{itemize}\item 台帳\end{itemize}
            \begin{thebibliography}{9}\bibitem{a}1Fold 台帳。\end{thebibliography}\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        let page = try #require(pdf.page(at: 0))
        let text = try #require(pdf.findString("1Fold").first).bounds(for: page)
        let first = try initialGlyph(in: text, on: page)
        let label = try #require(pdf.findString("[1]").first).bounds(for: page)
        let index = page.characterIndex(at: CGPoint(x: label.midX, y: label.midY))
        try #require((0..<page.numberOfCharacters).contains(index))
        #expect(abs(page.characterBounds(at: index).maxY - first.maxY) < 0.25)
        #expect(pdf.findString("•", withOptions: []).count == 1)
    }

    @Test("宋体の標準論文で空の著者表をはさむ題名と日付の基線間隔が保たれる", .timeLimit(.minutes(1)))
    func emptyArticleAuthor() async throws {
        let tex = #"""
            \documentclass[a4paper]{article}
            \usepackage[margin=23mm]{geometry}
            \usepackage{fontspec}\setmainfont{Songti SC}
            \begin{document}
            \title{Fold 纸板}\author{}\date{Field 五月}\maketitle
            \begin{figure}[ht]\centering\rule{10mm}{1mm}\caption{纸板}\end{figure}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-zh" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        let page = try #require(pdf.page(at: 0))
        let title = try #require(pdf.findString("Fold").first).bounds(for: page)
        let date = try #require(pdf.findString("Field").first).bounds(for: page)
        // F sits on the baseline at both title and date sizes. The article title pass
        // uses ordinary WebKit layout pixels, which round at each of the two skips.
        let gap = try initialGlyph(in: title, on: page).minY - initialGlyph(in: date, on: page).minY
        #expect(abs(gap - 51 * 72 / 72.27) < 1.6)
    }

    @Test("別行数式の前の行末と上揃えの小組に応じて本文の基線間隔を保つ", .timeLimit(.minutes(1)))
    func environmentHeights() async throws {
        let tex = #"""
            \documentclass[a4paper,11pt]{ltjsarticle}
            \usepackage[margin=25mm]{geometry}
            \usepackage{amsmath}
            \begin{document}
            \noindent MarkA 窓札。
            \[a=27\]
            \noindent MarkB\hspace{90mm}端。
            \begin{equation}a=27\end{equation}
            \noindent MarkC 左右の台。
            \par\noindent\begin{minipage}[t]{.46\linewidth}
            \subsubsection*{左の台}紙札。\\折り目。
            \end{minipage}\hfill
            \begin{minipage}[t]{.46\linewidth}
            \subsubsection*{右の台}窓札。\\刻み。
            \end{minipage}\par
            \noindent MarkD 幅。
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        #expect(pdf.pageCount == 1)
        let page = try #require(pdf.page(at: 0))
        for (first, second, expected) in [
            ("MarkA", "MarkB", 40.364), ("MarkB", "MarkC", 52.364), ("MarkC", "MarkD", 80.997),
        ] {
            let a = try #require(pdf.findString(first).first).bounds(for: page)
            let b = try #require(pdf.findString(second).first).bounds(for: page)
            let distance = try initialGlyph(in: a, on: page).maxY - initialGlyph(in: b, on: page).maxY
            #expect(abs(distance - expected) < 0.2, "\(first)–\(second): \(distance)")
        }
    }

    @Test("和文のコードは最初の番号からコードと同じ基線に置く", .timeLimit(.minutes(1)))
    func listingNumberBaselines() async throws {
        let tex = #"""
            \documentclass[a4paper,11pt]{ltjsarticle}
            \usepackage[margin=25mm]{geometry}\usepackage{listings}
            \begin{document}
            \begin{lstlisting}[basicstyle=\small\ttfamily,numbers=left,caption={Fold},frame=single]
            1first
            2second
            \end{lstlisting}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        let page = try #require(pdf.page(at: 0))
        for word in ["1first", "2second"] {
            let code = try #require(pdf.findString(word).first)
            let digit = page.characterBounds(at: code.range(at: 0, on: page).location)
            let gutter = try #require(
                pdf.findString(String(word.prefix(1))).first { selection in
                    let box = selection.bounds(for: page)
                    return box.maxX < digit.minX && abs(box.midY - digit.midY) < 8
                })
            // A subset's selection bounds can include whitespace outside the character hit-testing area.
            let label = page.characterBounds(at: gutter.range(at: 0, on: page).location)
            #expect(!label.isEmpty && !digit.isEmpty)
            #expect(abs(label.minY - digit.minY) < 0.1)
        }
    }

    @Test("表紙の下端に深さのある文字を置いても次ページが増えず、注や図のない本文も行送りを保つ", .timeLimit(.minutes(1)))
    func flexibleTitlePage() async throws {
        let tex = #"""
            \documentclass[a4paper,11pt]{ltjsarticle}
            \usepackage[margin=25mm]{geometry}
            \begin{document}
            \begin{titlepage}\noindent Upper\vfill
            \begin{minipage}{.6\linewidth}\small Middleone\\Middletwo\end{minipage}
            \vfill\noindent Lower edge\end{titlepage}
            \noindent Finalone\\Finaltwo
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        #expect(pdf.pageCount == 2)
        let cover = try #require(pdf.page(at: 0))
        let lower = try #require(pdf.findString("Lower edge").first)
        #expect(lower.pages.first == cover)
        #expect(abs(lower.bounds(for: cover).minY - 70.87) < 5)
        for (first, second, index, pitch) in [
            ("Middleone", "Middletwo", 0, 14.182), ("Finalone", "Finaltwo", 1, 17.455),
        ] {
            let page = try #require(pdf.page(at: index))
            let a = try #require(pdf.findString(first).first)
            let b = try #require(pdf.findString(second).first)
            #expect(a.pages.first == page && b.pages.first == page)
            #expect(abs(a.bounds(for: page).maxY - b.bounds(for: page).maxY - pitch) < 0.1)
        }
    }
}

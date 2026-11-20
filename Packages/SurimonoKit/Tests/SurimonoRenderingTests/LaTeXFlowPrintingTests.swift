import AppKit
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXFlowPrintingTests {
    @Test("単段記事のコード枠は右余白に出た縦罫まで印刷する", .timeLimit(.minutes(1)))
    func listingRightRule() async throws {
        let tex = #"""
            \documentclass{article}\usepackage{listings}
            \begin{document}\section*{Counting folds}
            \begin{lstlisting}[basicstyle=\small\ttfamily,numbers=left,frame=single,caption={A rack}]
            first
            middle
            last
            \end{lstlisting}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        let page = try #require(pdf.page(at: 0))
        let middle = try #require(pdf.findString("middle").first).bounds(for: page)
        // The 10pt article measure is 345 TeX points. Only the frame can paint past it mid-line.
        let edge = Int(middle.minX + 345 * 72 / 72.27)
        let samples = try (edge + 1...edge + 6).map { try RenderingFixtures.pixel(page, x: $0, y: Int(middle.midY))[0] }
        #expect(samples.contains { $0 < 230 })
    }

    @Test(
        "本文書体の x 高で節から引用と通常段落への基準線間隔が変わる", .timeLimit(.minutes(1)),
        arguments: [("Times New Roman", 22.20, 33.53), ("Hiragino Mincho ProN", 24.28, 36.69)])
    func sectionBaselines(_ fixture: (String, Double, Double)) async throws {
        let (font, after, before) = fixture
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{article}\setmainfont{\#(font)}\begin{document}
            \begin{abstract}ABSTRACTEND\end{abstract}\tableofcontents
            \section{FIRSTMARK}\begin{quote}QUOTEBASE\end{quote}
            \section{NEXTMARK}TEXTBASE
            \end{document}
            """#)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        // PDFKit selections can share the entire line's bounds across runs of different sizes.
        // An empty inline block exposes the actual baseline without changing the text metrics.
        let measure = """
            function baseline(selector) {
              const marker = document.createElement('i');
              marker.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline';
              document.querySelector(selector).prepend(marker);
              const y = marker.getBoundingClientRect().top;
              marker.remove();
              return y / \(WebPaginator.printPixelsPerPoint);
            }
            return JSON.stringify([
              baseline('blockquote p') - baseline('#sec-1'),
              baseline('#sec-2 + p') - baseline('#sec-2'),
              baseline('.latex-contents-title') - baseline('.abstract p:last-child')
            ]);
            """
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: measure, latexPageNumbers: fragment.latexClass?.pageNumbers,
            latexFlow: true)
        #expect(result.issues.isEmpty)
        let json = try #require(result.preparationResult)
        let gaps = try JSONDecoder().decode([Double].self, from: Data(json.utf8))
        try #require(gaps.count == 3)
        for (gap, expected) in zip(gaps, [after, after, before]) { #expect(abs(gap - expected) < 1.2) }
    }

    @Test("二段の幅・段頭の図・段下の注と選択できる本文の順序を実際の PDF で確かめる", .timeLimit(.minutes(1)))
    func columns() async throws {
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass[a4paper,twocolumn]{article}
                \usepackage[margin=20mm]{geometry}\setlength{\columnsep}{10pt}
                \begin{document}
                \noindent LEFTSTART\footnote{NOTEBOTTOM}\par
                \begin{figure}[t]\centering FLOATTOP\end{figure}
                \columnbreak\noindent RIGHTSTART\par
                \clearpage\noindent LASTPAGE\end{document}
                """#.utf8), format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        let rendered = try await DocumentRenderer().prepare(source, settings: settings)
        let pdf = rendered.logicalDocument
        #expect(pdf.pageCount == 2)
        let page = try #require(pdf.page(at: 0))
        func rect(_ word: String) throws -> CGRect {
            let matches = pdf.findString(word, withOptions: [])
            try #require(matches.count == 1)
            let selection = try #require(matches.first)
            #expect(selection.pages.first == page)
            return selection.bounds(for: page)
        }
        let left = try rect("LEFTSTART")
        let right = try rect("RIGHTSTART")
        let note = try rect("NOTEBOTTOM")
        let figure = try rect("FLOATTOP")
        let textWidth = page.bounds(for: .mediaBox).width - 2 * 20 * 72 / 25.4
        #expect(abs(right.minX - left.minX - (textWidth + 10 * 72 / 72.27) / 2) < 3)
        #expect(abs(right.midY - figure.midY) < 5)
        #expect(figure.midY > left.midY && figure.minX < right.minX)
        #expect(note.minX < right.minX && abs(note.minY - 20 * 72 / 25.4) < 8)
        let text = try #require(page.string)
        let words = text.components(separatedBy: .whitespacesAndNewlines).joined()
        // PDFKit reads a line that spans both column tops (the float, then the right column's first line) before
        // the left column, and does the same with the PDF real LaTeX makes of this page. Within a column the order
        // is ours: the top float, the text, then the note.
        let ordered = try #require(words.range(of: "FLOATTOP.*LEFTSTART.*NOTEBOTTOM", options: .regularExpression))
        #expect(!words[ordered].isEmpty)
        #expect(words.contains("RIGHTSTART"))
        #expect(pdf.page(at: 1)?.string?.contains("LASTPAGE") == true)
    }

    @Test(
        "表題が表の前でも後でも学会誌の本文との間隔を印刷 PDF に残す", .timeLimit(.minutes(1)),
        arguments: ["[conference]{IEEEtran}", "{llncs}", "[sigconf]{acmart}"])
    func tableCaptionSpacing(declaration: String) async throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass\#(declaration)
            \begin{document}
            \begin{table}[H]\centering\caption{UPPER}\label{t:u}\begin{tabular}{l}ALPHA\end{tabular}\end{table}
            \begin{table}[H]\centering\begin{tabular}{l}ROWONE\\BETA\end{tabular}\caption{LOWER}\end{table}
            \end{document}
            """#)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, latexFlow: true)
        #expect(result.issues.isEmpty)
        let pdf = result.document
        let page = try #require(pdf.page(at: 0))
        func bounds(_ token: String) throws -> CGRect {
            let match = try #require(pdf.findString(token).first)
            try #require(match.pages.first == page)
            return match.bounds(for: page)
        }
        let upperGap = try bounds("UPPER").minY - bounds("ALPHA").maxY
        let ieee = declaration.contains("IEEEtran")
        // The IEEE caption number is its own line, immediately below the table.
        let lowerCaption = try bounds(ieee ? "TABLE II" : "LOWER")
        let lastRow = try bounds("BETA")
        if ieee || declaration == "{llncs}" {
            // Both classes put the skip below the caption even when the source places it below the table.
            let rowPitch = try bounds("ROWONE").midY - lastRow.midY
            #expect(abs(rowPitch - (ieee ? 8.97 : 10.96)) < 1)
            #expect(abs(lastRow.midY - lowerCaption.midY - (ieee ? 8.01 : 10.51)) < 2)
            #expect(upperGap > (ieee ? 3 : 7))
            if ieee {
                let labelPitch = try lowerCaption.midY - bounds("LOWER").midY
                #expect((7.5...11.5).contains(labelPitch))
            }
        } else {
            let lowerGap = lastRow.minY - lowerCaption.maxY
            for gap in [upperGap, lowerGap] {
                #expect((9...20).contains(gap))
            }
        }
    }

    @Test("段組みの両側で先頭見出しの十五ポイントの外余白を落とし、内側の空きは残す", .timeLimit(.minutes(1)))
    func headingAtColumnTop() async throws {
        let html = """
            <style>h2 {font:16px/20px monospace;margin:18.75px 0 0;padding-top:5px}p{margin:0}</style>
            <p>Intro</p><div data-latex-columns="2" data-latex-balance="true">
            <h2>Left</h2><p>Body</p><template data-latex-break="column"></template><h2>Right</h2><p>Body</p></div>
            """
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 320, height: 210),
            margins: .uniform(millimeters: 10), allowsJavaScript: false, latexFlow: true)
        let pdf = result.document
        let first = try #require(pdf.page(at: 0))
        let left = try #require(pdf.findString("Left").first).bounds(for: first)
        let right = try #require(pdf.findString("Right").first).bounds(for: first)
        let intro = try #require(pdf.findString("Intro").first).bounds(for: first)
        #expect(result.issues.isEmpty && pdf.pageCount == 1)
        #expect(right.minX - left.minX > 100 && abs(left.maxY - right.maxY) < 1)
        #expect(intro.minY - left.maxY < 10)
    }

    @Test("三ポイントの行送りと九ミリの段落間の空きを実寸で刷る", .timeLimit(.minutes(1)))
    func verticalSpace() async throws {
        let source = DocumentSource(
            data: Data(
                #"\documentclass{article}\begin{document}LineA\\[3pt]LineB\\LineC\par\vspace{9mm}LineD\clearpage End\end{document}"#
                    .utf8), format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        let result = try await DocumentRenderer().prepare(source, settings: settings)
        let pdf = result.logicalDocument
        let page = try #require(pdf.page(at: 0))
        let y = try ["LineA", "LineB", "LineC", "LineD"].map {
            try #require(pdf.findString($0).first).bounds(for: page).maxY
        }
        #expect(abs((y[0] - y[1]) - (y[1] - y[2]) - 3 * 72 / 72.27) < 0.25)
        #expect(abs(y[1] - y[2] - 11.955) < 0.6)
        #expect(abs(y[2] - y[3] - 37.467) < 0.6)
    }

    @Test("段とページをまたぐ一段落の単語を、一語ずつ元の順に選択できる", .timeLimit(.minutes(1)))
    func readingOrder() async throws {
        let tokens = (0..<320).map { String(format: "word%03d", $0) }
        let html =
            "<style>body{font:12px/18px monospace}p{margin:0}</style>"
            + "<template data-latex-columns=\"2\" data-latex-rule=\"0\"></template><p>" + tokens.joined(separator: " ")
            + "</p>"
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 310, height: 200),
            margins: .uniform(millimeters: 5), allowsJavaScript: false, latexFlow: true)
        #expect(result.issues.isEmpty)
        #expect(result.document.pageCount > 1)
        let text = try #require(result.document.string)
        #expect(text.matches(of: /word[0-9]{3}/).map { String($0.output) } == tokens)
    }

    @Test("脚注が用紙より長い場合は元の本文と注を一段で刷り、確認に理由を出す", .timeLimit(.minutes(1)))
    func fallback() async throws {
        let html =
            "<p>BODY<sup class=\"footnote-ref\"><a href=\"#fn-1\">1</a></sup></p>"
            + "<section class=\"footnotes\"><ol><li id=\"fn-1\"><div style=\"height:400px\">LONGNOTE</div></li></ol></section>"
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 310, height: 200),
            margins: .uniform(millimeters: 5), allowsJavaScript: false, latexFlow: true)
        #expect(result.issues.contains { $0.id == "latex-flow-fallback" })
        #expect(result.document.string?.contains("LONGNOTE") == true)
        #expect(result.document.string?.contains("BODY") == true)
    }

    @Test("応答が途絶えた段の測定から時間内に戻り、新しい一段の文書を刷る", .timeLimit(.minutes(1)))
    func droppedMeasurementReply() async throws {
        let paginator = WebPaginator()
        var started: ContinuousClock.Instant?
        var attempts = 0
        paginator.flowEvaluator = { _, _, _, _ in
            attempts += 1
            started = .now
            // Simulate a recycled content process dropping the measurement reply.
        }
        let html =
            ##"<body class="format-latex"><nav class="toc"><ul><li><a href="#dest">Index</a></li></ul></nav><h2 id="dest">CONTROL</h2></body>"##
        let result = try await paginator.paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 310, height: 200),
            margins: .uniform(millimeters: 5), allowsJavaScript: false, latexPageNumbers: .init(), latexFlow: true,
            timeout: .seconds(2))
        let elapsed = try #require(started).duration(to: .now)
        #expect(attempts == 1)
        #expect(elapsed < .seconds(8))
        #expect(result.issues.filter { $0.id == "latex-flow-fallback" }.count == 1)
        #expect(!result.issues.contains { $0.id == "latex-page-references" })
        #expect(result.document.pageCount == 1)
        let text = try #require(result.document.string)
        #expect(text.contains("CONTROL") && text.contains("1") && !text.contains("?"))
        #expect(paginator.openSessionCount == 0)
    }

    @Test("十二ページの二段論文と百ページの脚注付き本文を計時する", .timeLimit(.minutes(1)), arguments: [12, 100])
    func timing(count: Int) async throws {
        let columns = count == 12 ? "[twocolumn]" : ""
        let line = String(repeating: "A paragraph for measuring the column width and the selectable text. ", count: 8)
        let pages = (1...count).map { i in
            "Section \(i). \(line)\\footnote{Note \(i).}\\par " + (count == 12 ? "\\columnbreak " : "") + line
        }
        let source =
            "\\documentclass\(columns){article}\\begin{document}" + pages.joined(separator: "\\clearpage ")
            + "\\end{document}"
        let fragment = LaTeXConverter.convert(source)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        let start = ContinuousClock.now
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size,
            margins: .uniform(millimeters: 20), allowsJavaScript: false, latexFlow: true)
        let elapsed = start.duration(to: .now)
        #expect(result.issues.isEmpty)
        #expect(result.document.pageCount == count)
        // Wall-clock budgets with room for a shared CI runner, which took 4.8 s where a desk Mac takes 1.5 s.
        // They catch a layout that stopped being linear, not a slow machine.
        #expect(elapsed < .seconds(count == 12 ? 12 : 60), "組版時間 \(elapsed)")
    }
}

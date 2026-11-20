import AppKit
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXFlowPrintingTests {
    @Test("議事録の小型大文字を刷った PDF から原稿の綴りで検索できる", .timeLimit(.minutes(1)))
    func proceedingsSmallCapSearch() async throws {
        let tex = #"""
            \documentclass{amsproc}\title{Fold stops}\author{Fold Desk}
            \address{Paper Workshop}\thanks{The fold bench supplied the trial strips.}
            \begin{document}\begin{abstract}Gauge spacing.\end{abstract}\maketitle
            \begin{figure}[h]\rule{12mm}{2mm}\caption{Edge}\end{figure}
            \begin{table}[h]\caption{Gap}\begin{tabular}{c}3\end{tabular}\end{table}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        for word in ["Abstract", "Figure", "Table", "Paper Workshop"] {
            #expect(pdf.findString(word, withOptions: []).count == 1)
        }

        let page = try #require(pdf.page(at: 0))
        let thanks = try #require(pdf.findString("The fold bench supplied the trial strips.", withOptions: []).first)
        // CMR8 gives this note a 147.65 PDF-point advance in the proceedings reference.
        #expect(abs(thanks.bounds(for: page).width - 147.65) < 2)
    }

    @Test("前付の次の左ページを白紙にして本文章の右下を一に戻す", .timeLimit(.minutes(1)))
    func matterOpeningAndFolio() async throws {
        let tex = #"""
            \documentclass{scrbook}\begin{document}
            \frontmatter\chapter{Preface}Fold the gauge.
            \mainmatter\chapter{Bench}Set the stop.\newpage Check again.
            \backmatter\addchap{Register}Store the card.\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-report" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexFurniture = .style
        let output = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings)
        #expect(output.logicalDocument.pageCount == 5)
        #expect(output.viewFurniture[0]?.lines.bottom == ["", "", "i"])
        let blank = try #require(output.logicalDocument.page(at: 1))
        #expect((blank.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(output.viewFurniture[1]?.lines.isEmpty ?? true)
        #expect(output.viewFurniture[2]?.lines.bottom == ["", "", "1"])
        #expect(output.viewFurniture[3]?.lines.top == ["1\u{2002}Bench", "", ""])
        #expect(output.viewFurniture[4]?.lines.bottom == ["", "", "3"])
    }

    @Test("標準書籍の部扉と章扉は組版領域を基準にして番号と題を置く", .timeLimit(.minutes(1)))
    func bookOpeningPositions() async throws {
        let tex =
            #"\documentclass[openany]{book}\begin{document}\part{Upper valley}\chapter{Spillway}Water.\end{document}"#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-report" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        #expect(pdf.pageCount == 2)
        func top(_ text: String, page: Int) throws -> CGFloat {
            let p = try #require(pdf.page(at: page))
            return try #require(pdf.findString(text).first).bounds(for: p).maxY
        }
        // Corpus 003 uses the same text block on both sheets, so the stock offset cancels.
        let part = try top("Part I", page: 0)
        let chapter = try top("Chapter 1", page: 1)
        #expect(abs(chapter - part - 103) < 6)
        #expect(abs(try chapter - top("Spillway", page: 1) - 47) < 3)
    }

    @Test("欧文文献の斜体は項目の送りを広げず、ページ下の二つの脚注は小さな送りで並ぶ", .timeLimit(.minutes(1)))
    func bibliographyAndFootnotePitch() async throws {
        let tex = #"""
            \documentclass{article}\begin{document}Notes\footnote[7]{ALPHANOTE} and more\footnote[8]{BETANOTE}.
            \begin{thebibliography}{9}\bibitem{a}ALPHABOOK, \emph{Italic}.
            \bibitem{b}BETABOOK, \emph{Second}.\end{thebibliography}\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        let page = try #require(pdf.page(at: 0))
        func top(_ text: String) throws -> CGFloat {
            let hit = pdf.findString(text).first { $0.pages.first == page }
            return try #require(hit, "1ページ目に「\(text)」が見つかりません").bounds(for: page).maxY
        }
        let bookPitch = try top("ALPHABOOK") - top("BETABOOK")
        let first = try top("ALPHANOTE")
        let second = try top("BETANOTE")
        #expect(abs(bookPitch - 19.92) < 0.7)
        #expect(abs(first - second - 9.46) < 0.6)
        func rise(_ number: String, at note: CGFloat) throws -> CGFloat {
            let marks = pdf.findString(number).map { $0.bounds(for: page) }.filter { abs($0.maxY - note) < 8 }
            #expect(marks.count == 1, "脚注本文に対応する番号「\(number)」を1つ印刷する")
            return try #require(marks.first, "脚注番号「\(number)」が見つかりません").maxY - note
        }
        let firstRise = try rise("7", at: first)
        let secondRise = try rise("8", at: second)
        #expect(firstRise > 0 && secondRise > 0)
        #expect(abs(firstRise - secondRise) < 0.5)
    }

    @Test("和文記事の目次と次頁の無番号節で見出しの高さがそろう", .timeLimit(.minutes(1)))
    func japaneseContentsOpening() async throws {
        let tex = #"""
            \documentclass[a4paper,11pt]{ltjsarticle}\usepackage[margin=25mm]{geometry}
            \begin{document}\tableofcontents\clearpage\section*{目次}\section{観察}本文。\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        let titles = pdf.findString("目次")
        #expect(titles.count == 2)
        let tops = titles.compactMap { title in title.pages.first.map { title.bounds(for: $0).maxY } }
        #expect(tops.count == 2)
        if let first = tops.first, let last = tops.last { #expect(abs(first - last) < 2) }
    }

    @Test("和文目次の黒い点は最終行の番号と同じ基準線に並び番号箱の手前で一周期ずつ終わる", .timeLimit(.minutes(1)), arguments: [false, true])
    func printedJapaneseLeader(report: Bool) async throws {
        let heading = report ? "朝の採光" : "折り目の位置"
        let tex =
            report
            ? #"""
            \documentclass[10pt,oneside,a4paper]{ltjsreport}\linespread{1.15}
            \begin{document}\tableofcontents\chapter{実験}\section{朝の採光}本文。\end{document}
            """#
            : #"""
            \documentclass[11pt,a4paper]{ltjsarticle}\usepackage[margin=25mm]{geometry}
            \begin{document}\tableofcontents\clearpage\appendix\section{実験}\subsection{折り目の位置}本文。\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        let page = try #require(pdf.page(at: 0))
        let title = try #require(pdf.findString(heading).first { $0.pages.first == page }).bounds(for: page)
        try checkLeader(
            page, title: title, startX: title.maxX + 1, count: report ? 45 : 39,
            diameter: report ? 7...10 : 8...11, pitch: report ? 7.75 : 8.49, lastDistance: report ? 18.78 : 22.14)
    }

    @Test("伝統的和文書籍と KOMA の目次は本文幅を基準に黒い丸を並べ番号箱の手前で止める", .timeLimit(.minutes(1)), arguments: [false, true])
    func bookContentsLeader(koma: Bool) async throws {
        let corpus = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            .appendingPathComponent("Snapshots/corpus/latex")
        let file = corpus.appendingPathComponent(koma ? "109-scrbook-parts/main.tex" : "112-ltjbook-chapters/main.tex")
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == (koma ? "latex-report" : "latex-plain-ja") })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: try Data(contentsOf: file), format: .latex), settings: settings
        ).logicalDocument
        let page = try #require(pdf.page(at: 2))
        if !koma {
            // Reference 112 repeats the searchable label on the contents page and chapter opener.
            let pages = pdf.findString("第 1 章", withOptions: []).compactMap { $0.pages.first }.map {
                pdf.index(for: $0)
            }
            #expect(pages.contains(2) && pages.contains(4))
        }
        let chapter = try #require(pdf.findString(koma ? "The sliding strip" : "基壇").first { $0.pages.first == page })
        let bounds = chapter.bounds(for: page)
        let crop = try grayCrop(
            page, origin: CGPoint(x: 250, y: bounds.minY), width: 600, height: Int(bounds.height * 6), scale: 6)
        let pixels = try #require(crop.data).assumingMemoryBound(to: UInt8.self)
        #expect((0..<(crop.bytesPerRow * crop.height)).allSatisfy { pixels[$0] > 200 })
        // The KOMA dot centred at x = 250.42 pt crosses x = 250. Start in the gap to measure its full diameter.
        let titles = koma ? ["Cutting the slot", "Checking the edge"] : ["台の角", "台紙の裏"]
        let rises = try titles.map { text in
            let title = try #require(pdf.findString(text).first { $0.pages.first == page })
            return try checkLeader(
                page, title: title.bounds(for: page), startX: koma ? 247 : 223, count: 25,
                diameter: koma ? 8...11 : 7...10, pitch: koma ? 8.49 : 7.75, lastDistance: koma ? 19.44 : 17.22)
        }
        // Both rows have the same rise in the references. Allow one 600-dpi pixel for each sampled edge.
        #expect(abs(rises[0] - rises[1]) <= 0.24)
    }

    @discardableResult
    private func checkLeader(
        _ page: PDFPage, title: CGRect, startX: CGFloat, count: Int, diameter: ClosedRange<Int>,
        pitch: Double, lastDistance: Double
    ) throws -> Double {
        // Sample one complete row at 600 dpi, including the ink of its final digit.
        let scale = 600.0 / 72
        let width = Int(ceil((page.bounds(for: .mediaBox).maxX - startX) * scale))
        let height = Int(ceil((title.height + 4) * scale))
        let ctx = try grayCrop(
            page, origin: CGPoint(x: startX, y: title.minY - 2),
            width: width, height: height, scale: scale)
        let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        let columns = (0..<width).filter { x in (0..<height).contains { y in pixels[y * width + x] < 32 } }
        var runs: [Range<Int>] = []
        for x in columns {
            if runs.last?.upperBound == x {
                let start = runs.removeLast().lowerBound
                runs.append(start..<(x + 1))
            } else {
                runs.append(x..<(x + 1))
            }
        }
        let numberInk = runs.popLast()
        let digit = try #require(numberInk)
        let dot = try #require(runs.last)
        #expect(runs.count == count)
        #expect(runs.allSatisfy { diameter.contains($0.count) })
        for (a, b) in zip(runs, runs.dropFirst()) {
            #expect(abs(Double(b.lowerBound - a.lowerBound) / scale - pitch) < 0.3)
        }
        let distance = Double(digit.lowerBound + digit.upperBound - dot.lowerBound - dot.upperBound) / (2 * scale)
        #expect(abs(distance - lastDistance) < 0.6)
        func inkRows(_ span: Range<Int>) -> [Int] {
            (0..<height).filter { y in span.contains { x in pixels[y * width + x] < 64 } }
        }
        let ink = inkRows(dot)
        let top = try #require(ink.first)
        let bottom = try #require(ink.last)
        let baseline = try #require(inkRows(digit).last)
        let rise = Double(2 * baseline - top - bottom) / (2 * scale)
        // The references put the dot centre 0.54 pt (LuaTeX-ja classes) to 0.84 pt (KOMA) above the baseline. The
        // background that draws the dots lands on the device grid, which moves it by up to a third of a point.
        #expect((0.1...1.2).contains(rise))
        return rise
    }

    @Test("標準記事の引用段落と脚注の二行には別々の基準線間隔を使う", .timeLimit(.minutes(1)))
    func quoteAndFootnotePitch() async throws {
        let tex = #"""
            \documentclass{article}\begin{document}
            \begin{quote}Quartz\par Slate\end{quote}
            Card\footnote{Footfirst\\Footlast}.\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex),
            settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        ).logicalDocument
        let page = try #require(pdf.page(at: 0))
        func top(_ text: String) throws -> CGFloat {
            try #require(pdf.findString(text).first).bounds(for: page).maxY
        }
        // Reference 035 uses twelve points of baseline plus four of parsep; 001 uses the footnotesize strut.
        #expect(abs(try top("Quartz") - top("Slate") - 15.94) < 1.2)
        #expect(abs(try top("Footfirst") - top("Footlast") - 9.50) < 1.2)
    }

    @Test("AMS の小型大文字の見出しとタイプライターのコードを PDF から単語で検索できる", .timeLimit(.minutes(1)))
    func searchableListingAndSmallCaps() async throws {
        let tex = #"""
            \documentclass{amsart}\usepackage{listings}\begin{document}
            \section{Bench trial}
            \begin{lstlisting}[basicstyle=\small\ttfamily]
            first
            middle
            last
            \end{lstlisting}\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        for word in ["Bench", "middle"] {
            #expect(pdf.findString(word, withOptions: .caseInsensitive).count == 1, "「\(word)」を一語として検索できる")
        }
    }

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
        let caption = try #require(pdf.findString("A rack").first).bounds(for: page)
        let first = try #require(pdf.findString("first").first).bounds(for: page)
        // Corpus 034 has 16.5 PDF points between the caption and the first source line.
        #expect(abs(caption.maxY - first.maxY - 16.5) < 3)
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

extension LaTeXFlowPrintingTests {
    private func grayCrop(_ page: PDFPage, origin: CGPoint, width: Int, height: Int, scale: CGFloat) throws -> CGContext
    {
        let ctx = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -origin.x, y: -origin.y)
        ctx.drawPDFPage(try #require(page.pageRef))
        return ctx
    }

    @Test("長表の最終横罫は継続見出しの罫と同じ太さで刷る", .timeLimit(.minutes(1)))
    func closingTableRule() async throws {
        let rows = (1...40).map { "Record\($0) \\\\" }.joined(separator: "\n")
        let tex = #"""
            \documentclass{article}\usepackage{longtable}\setlength{\textheight}{120mm}\begin{document}
            \begin{longtable}{l}FIRSTHEAD\\\hline\endfirsthead
            NEXTHEAD\\\hline\endhead NEXTFOOT\\\endfoot\hline\endlastfoot
            \#(rows)
            \end{longtable}\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        let page = try #require(pdf.page(at: pdf.pageCount - 1))
        let firstPage = try #require(pdf.page(at: 0))
        func rulePixels(below text: String, on page: PDFPage) throws -> Int {
            let selection = try #require(pdf.findString(text).first { $0.pages.first == page }, "対象ページに「\(text)」が必要")
            let box = selection.bounds(for: page)
            // Sample inside tabcolsep, where the rule crosses the gutter and the glyphs do not.
            let ctx = try grayCrop(
                page, origin: CGPoint(x: box.minX - 3, y: box.midY - 12), width: 1,
                height: 200, scale: 1200.0 / 72)
            let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            return (0..<ctx.height).filter { pixels[$0 * ctx.bytesPerRow] < 150 }.count
        }
        let first = try rulePixels(below: "FIRSTHEAD", on: firstPage)
        let head = try rulePixels(below: "NEXTHEAD", on: page)
        let last = try rulePixels(below: "Record40", on: page)
        // The default .4 TeX point occupies 6.64 pixels at 1200 dpi.
        #expect([first, head, last].allSatisfy { (6...7).contains($0) })
        #expect(abs(head - last) <= 1)
    }

    @Test("長表は継続見出しと送りの脚を改ページ時だけ刷る", .timeLimit(.minutes(1)), arguments: [true, false])
    func continuedTable(distinctEnds: Bool) async throws {
        let rows = (1...65).map { "Entry\($0) \\\\" }.joined(separator: "\n")
        let first = distinctEnds ? #"FIRSTHEAD\\\endfirsthead "# : ""
        let last = distinctEnds ? #" LASTFOOT\\\endlastfoot"# : ""
        let tex = #"""
            \documentclass{article}\setlength{\textheight}{120mm}\begin{document}
            \begin{longtable}{l}\#(first)NEXTHEAD\\\endhead
            NEXTFOOT\\\endfoot\#(last)
            \#(rows)
            \end{longtable}\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let pdf = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        #expect(pdf.pageCount == 3)
        var entries: [Int] = []
        for i in 0..<pdf.pageCount {
            let text = try #require(pdf.page(at: i)?.string)
            entries += text.matches(of: /Entry([0-9]+)/).compactMap { Int($0.1) }
            #expect(text.contains("FIRSTHEAD") == (distinctEnds && i == 0))
            #expect(text.contains("NEXTHEAD") == (!distinctEnds || i > 0))
            #expect(text.contains("NEXTFOOT") == (!distinctEnds || i < pdf.pageCount - 1))
            #expect(text.contains("LASTFOOT") == (distinctEnds && i == pdf.pageCount - 1))
        }
        #expect(entries == Array(1...65))
    }
}

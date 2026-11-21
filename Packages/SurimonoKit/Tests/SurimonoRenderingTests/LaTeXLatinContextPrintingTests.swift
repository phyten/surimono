import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXLatinContextPrintingTests {
    private struct Measurement: Decodable {
        struct Paragraph: Decodable {
            struct Line: Decodable {
                let measure, width, pitch, height: Double
                let minSpaceSlack: Double?
            }
            let category, text: String
            let lines: [Line]
            let fallback: String?
        }
        let paragraphs: [Paragraph]
    }

    private let prose =
        "We fold the paper at the mark and rest it on the edge of the table. "
        + "The two ends meet at the rail and the last fold leaves a clear line on the sheet."

    @Test("2段組でリスト・注・文献・図注・要旨・引用を各々の幅と行送りで組み、検索と読む順を保つ", .timeLimit(.minutes(1)))
    func contexts() async throws {
        let cases = [
            ("abstract", "Abstract sample"), ("list", "Outer sample"), ("list", "Inner sample"),
            ("list", "Second sample"), ("description", "Description sample"), ("footnote", "Footnote sample"),
            ("caption", "Caption sample"), ("quote", "Quote sample"), ("quotation", "Quotation sample"),
            ("bibliography", "Reference sample"),
        ]
        let source = #"""
            \documentclass{article}\sloppy
            \begin{document}
            \begin{abstract}Abstract sample. \#(prose)\end{abstract}
            \begin{itemize}
            \item Outer sample. \#(prose)
            \begin{enumerate}\item Inner sample. \#(prose)\end{enumerate}

            Second sample. \#(prose)
            \end{itemize}
            \begin{description}\item[Paper rail] Description sample. \#(prose)\end{description}
            A call to the note\footnote{Footnote sample. \#(prose)}.
            \begin{figure}[H]\rule{2cm}{1pt}\caption{Caption sample. \#(prose)}\end{figure}
            \begin{quote}Quote sample. \#(prose)\end{quote}
            \begin{quotation}Quotation sample. \#(prose)\end{quotation}
            \begin{thebibliography}{9}
            \bibitem{paper}Reference sample. \#(prose)
            \end{thebibliography}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let fragment = LaTeXConverter.convert(source, composition: .twoColumn)
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        let paginator = WebPaginator()
        paginator.collectsLatinLineDiagnostics = true
        let result = try await paginator.paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false,
            composesLaTeXParagraphs: true, latexFlow: true, timeout: .seconds(20))
        #expect(result.issues.isEmpty)
        let json = try #require(paginator.latinLineDiagnostics)
        let rows = try JSONDecoder().decode(Measurement.self, from: Data(json.utf8)).paragraphs
        let pdf = result.document
        let text = try #require(pdf.string).filter { !$0.isWhitespace && $0 != "-" }
        for (category, prefix) in cases {
            let row = try #require(rows.first { $0.category == category && $0.text.contains(prefix) }, "\(prefix)")
            try #require(row.fallback == nil, "\(prefix) — \(row.fallback ?? "")")
            #expect(row.lines.count >= 2, "\(prefix)")
            for line in row.lines {
                #expect(abs(line.height - line.pitch) <= 0.1)
                if let slack = line.minSpaceSlack { #expect(slack >= -0.001) }
            }
            for line in row.lines.dropLast() {
                #expect(abs(line.measure - line.width) <= 0.3 * WebPaginator.printPixelsPerPoint)
            }
            #expect(pdf.findString(prefix, withOptions: []).count == 1, "\(prefix)")
            #expect(text.contains((prefix + "." + prose).filter { !$0.isWhitespace }), "\(prefix)")
        }
    }

    @Test("番号・脚注印と本文の位置関係を印刷した紙面で保つ", .timeLimit(.minutes(1)))
    func hangingLabels() async throws {
        let note =
            "Calm winds pass over quiet fields while branches lean eastward towards distant hills beyond our wooden fence."
        let source = #"""
            \documentclass{article}\sloppy
            \begin{document}
            \begin{enumerate}\item Ladder marks. \#(prose)\end{enumerate}
            The note\footnote{Pencil guide. \#(note)\par Ruler guide. \#(prose)} belongs to this page.
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let fragment = LaTeXConverter.convert(source, composition: .twoColumn)
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        var positions: [[CGPoint]] = []
        for composes in [false, true] {
            let sourceHTML =
                composes ? html : html.replacingOccurrences(of: " data-latex-line-breaking=", with: " data-disabled=")
            let result = try await WebPaginator().paginateWithResult(
                .html(sourceHTML, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
                allowsJavaScript: false, latexFlow: true, timeout: .seconds(15))
            let pdf = result.document
            let page = try #require(pdf.page(at: 0))
            var samples: [CGPoint] = []
            for word in ["Ladder", "Pencil"] {
                let text = try #require(pdf.findString(word, withOptions: []).first).bounds(for: page)
                // The same digit can be an item number, a reference or a folio.
                // Select the hanging mark beside this paragraph's first word.
                let marks = pdf.findString("1", withOptions: []).map { $0.bounds(for: page) }.filter {
                    !$0.isEmpty && $0.midX < text.minX && abs($0.midY - text.midY) < 10
                }
                let mark = try #require(marks.max { $0.midX < $1.midX }, "\(word)")
                if word == "Pencil" { #expect(abs(text.minX - mark.maxX) <= 0.5) }
                samples.append(CGPoint(x: text.minX, y: text.midY - mark.midY))
                samples.append(CGPoint(x: mark.minX, y: mark.height))
            }
            let ruler = try #require(pdf.findString("Ruler", withOptions: []).first).bounds(for: page)
            let pencil = try #require(pdf.findString("Pencil", withOptions: []).first).bounds(for: page)
            let glyphs = note.split { !$0.isLetter }.flatMap { word in
                pdf.findString(String(word), withOptions: []).map { $0.bounds(for: page) }
            }.filter { !$0.isEmpty && $0.midY < pencil.midY - 3 && $0.midY > ruler.midY + 3 }
            let nextY = try #require(glyphs.map(\.midY).max())
            let continuationX = try #require(glyphs.filter { abs($0.midY - nextY) <= 1 }.map(\.minX).min())
            if composes {
                // At 10pt article's footnotesize is 8 TeX points. The kernel's mark
                // box takes 1.8em on the first line, with 1em on a later paragraph.
                let em = 8.0 * 72 / 72.27
                #expect(abs(pencil.minX - continuationX - 1.8 * em) <= 0.5)
                #expect(abs(ruler.minX - continuationX - em) <= 0.5)
            }
            positions.append(samples)
        }
        for (i, (native, composed)) in zip(positions[0], positions[1]).enumerated() {
            #expect(abs(composed.x - native.x) <= 0.5, "位置 \(i) \(native) → \(composed)")
            #expect(abs(native.y - composed.y) <= 0.5)
        }
    }

    @Test("著者年文献のぶら下げを保ち、短い図注・片寄せの図注・表セルは原形を保つ", .timeLimit(.minutes(1)))
    func hangingReferencesAndExclusions() async throws {
        let source = #"""
            \documentclass{article}\usepackage[authoryear]{natbib}
            \begin{document}
            \begin{figure}[H]\caption{Short caption.}\end{figure}
            \begin{figure}[H]\caption{\#(prose)}\end{figure}
            \begin{tabular}{l}Table material\end{tabular}
            \begin{thebibliography}{9}
            \bibitem[Desk(2021)]{desk}Paper rail. \#(prose)
            \end{thebibliography}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
        let probe =
            try LaTeXFlowPaginator.latinLineScript() + #"""
                document.body.style.width = '215px';
                const bib = document.querySelector('.latex-author-year > li');
                const captions = document.querySelectorAll('figcaption');
                captions[1].style.textAlign = 'right';
                const excluded = [...captions, document.querySelector('td')];
                const saved = excluded.map(el => [el.outerHTML, el.firstChild]);
                document.body.getBoundingClientRect(); await document.fonts.ready;
                const range = document.createRange();
                const lines = () => {
                    const result = [];
                    const walk = document.createTreeWalker(bib, NodeFilter.SHOW_TEXT);
                    for (let n = walk.nextNode(); n; n = walk.nextNode()) {
                        for (const match of n.data.matchAll(/\S+/g)) {
                            range.setStart(n, match.index); range.setEnd(n, match.index + match[0].length);
                            for (const r of range.getClientRects()) {
                                if (r.width && (!result.length || r.top > result.at(-1).top + 1)) result.push(r);
                            }
                        }
                    }
                    return result.map(r => r.left);
                };
                const before = lines();
                latinCompose(document.body);
                const after = lines();
                return JSON.stringify([bib.hasAttribute('data-flow-latin'), before.length > 2 && after.length > 2,
                    before[1] - before[0] > 4, Math.abs(after[0] - before[0]) < .625,
                    after.slice(1).every(x => Math.abs(x - before[1]) < .625),
                    excluded.every((el,i) => el.outerHTML === saved[i][0] && el.firstChild === saved[i][1])]);
                """#
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: probe, timeout: .seconds(15))
        #expect(result.preparationResult == "[true,true,true,true,true,true]")
    }

    @Test("文献タイトルの後ろの立体コンマを保ち、斜体の大文字語を途中で分ける", .timeLimit(.minutes(1)))
    func italicTitleHyphen() async throws {
        let source = #"""
            \documentclass{article}\begin{document}\begin{thebibliography}{1}
            \bibitem{x}Broad \emph{Waterways}, end.
            \end{thebibliography}\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
        let probe =
            try LaTeXFlowPaginator.latinLineScript() + #"""
                const p = document.querySelector('.latex-bibliography li'), title = p.querySelector('em');
                const original = p.textContent;
                const sample = document.createElement('span');
                sample.style.cssText = 'position:absolute;visibility:hidden;width:max-content';
                function width(parent,text) {
                    parent.append(sample); sample.textContent = text;
                    return sample.getBoundingClientRect().width;
                }
                await document.fonts.ready;
                const measure = width(p,'Broad') + width(title,'Water-') + parseFloat(getComputedStyle(p).fontSize)/3;
                sample.remove();
                p.style.width = measure + 'px';
                latinCompose(document.body);
                const lines = p.querySelectorAll('.latex-line');
                return JSON.stringify([lines.length, lines[0]?.hasAttribute('data-flow-hyphen'),
                    lines[0]?.querySelector('em')?.textContent, lines[1]?.querySelector('em')?.textContent,
                    p.textContent === original]);
                """#
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: probe, timeout: .seconds(15))
        #expect(result.preparationResult == #"[2,true,"Water","ways",true]"#)
    }

    @Test("文献のURLは許可された位置でリンクを分け、行末に文字を足さない", .timeLimit(.minutes(1)))
    func markedURL() async throws {
        let source = #"""
            \documentclass{article}\usepackage[hyphens]{url}
            \begin{document}\begin{thebibliography}{9}
            \bibitem{rails}Find the list of marks in the notes at \url{https://rail-box.test}.
            \end{thebibliography}\end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
        let probe =
            try LaTeXFlowPaginator.latinLineScript() + #"""
                const p = document.querySelector('li'), a = p.querySelector('.latex-url');
                const text = p.textContent, href = a.getAttribute('href');
                p.style.width = '135px';
                document.body.getBoundingClientRect(); await document.fonts.ready;
                const undo = [];
                latinCompose(document.body,1,undo);
                const parts = [...p.querySelectorAll('.latex-line a')];
                const marked = parts.length === 2 && parts[0].textContent === 'https://rail-' &&
                    parts[1].textContent === 'box.test' && parts.every(a => a.getAttribute('href') === href) &&
                    !parts[0].closest('.latex-line').hasAttribute('data-flow-hyphen') && p.textContent === text;
                for (const restore of undo.reverse()) restore();
                const restored = p.querySelector('a') === a;
                // The reader marks the same separators for native printing; url.sty's
                // hyphens option decides whether the hyphen is legal to the TeX planner.
                a.removeAttribute('data-latex-url-hyphens');
                latinCompose(document.body);
                const ordinary = [...p.querySelectorAll('a')];
                return JSON.stringify([marked, restored, ordinary.map(a=>a.textContent).join('') === href &&
                    !ordinary.slice(0,-1).some(a=>a.textContent.endsWith('-'))]);
                """#
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: probe, timeout: .seconds(15))
        #expect(result.preparationResult == "[true,true,true]")
    }

    @Test("校正の行番号は組んだ項目の各行に一つずつ付く", .timeLimit(.minutes(1)))
    func proofLineNumbers() async throws {
        let source = #"""
            \documentclass{article}\sloppy
            \begin{document}
            \begin{itemize}
            \item \#(prose) \#(prose) \#(prose)
            \end{itemize}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.latexComposition = .proof
        let html = try await HTMLExporter.html(
            source: DocumentSource(data: Data(source.utf8), format: .latex), settings: settings, title: "Proof")
        let lines = html.components(separatedBy: #"class="latex-line""#).count - 1
        let numbers = html.components(separatedBy: #"class="latex-export-line""#).count - 1
        #expect(lines > 1)
        #expect(numbers == lines)
    }
}

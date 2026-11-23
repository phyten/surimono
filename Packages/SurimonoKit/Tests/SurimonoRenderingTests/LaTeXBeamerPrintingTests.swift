import AppKit
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing
import WebKit

@testable import SurimonoRendering

@MainActor
struct LaTeXBeamerPrintingTests {
    @Test("改ページを挟む普通の縦空きは捨て、星付きの空きは続きの紙にも残す", .timeLimit(.minutes(1)))
    func continuationGlue() async throws {
        let tex = #"""
            \documentclass{beamer}
            \begin{document}
            \begin{frame}[allowframebreaks]{Record}
            North peg.\par\framebreak South peg.
            \end{frame}
            \begin{frame}[allowframebreaks]{Record}
            North peg.\par\vspace{9mm}\framebreak\vspace{10mm}South peg.
            \end{frame}
            \begin{frame}[allowframebreaks]{Record}
            North peg.\par\framebreak\vspace*{10mm}South peg.
            \end{frame}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let printed = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex),
            settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let pdf = printed.logicalDocument
        try #require(pdf.pageCount == 6)
        func top(_ word: String, _ page: Int) throws -> CGFloat {
            try printedInk(of: word, in: pdf, on: #require(pdf.page(at: page))).minY
        }
        #expect(try abs(top("North peg", 0) - top("North peg", 2)) < 1)
        #expect(try abs(top("South peg", 1) - top("South peg", 3)) < 1)
        #expect(try abs(top("South peg", 1) - top("South peg", 5)) > 10)
    }

    @Test("一枚より長い脚注も末尾まで一度ずつ印刷する", .timeLimit(.minutes(1)))
    func oversizedFootnote() async throws {
        let marks = (1...220).map { String(format: "sounding%03d", $0) }
        let tex = """
            \\documentclass{beamer}
            \\begin{document}\\begin{frame}{Water levels}
            Recorded values.\\footnote{\(marks.joined(separator: " "))}
            \\end{frame}\\end{document}
            """
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let printed = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex),
            settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        #expect(printed.facts?.continuedBeamerFrames == 1)
        let pdf = printed.logicalDocument
        // The superscript may be attached to the first word in a PDF text selection.
        let extracted = (0..<pdf.pageCount).flatMap {
            (pdf.page(at: $0)?.string ?? "").matches(of: /sounding[0-9]{3}/).map { String($0.output) }
        }
        #expect(extracted == marks)
    }

    @Test("小さなスライドと大きなスライドの見出しはクラスの段階別の字級を使う", .timeLimit(.minutes(1)), arguments: [8, 20])
    func titleSizes(_ pointSize: Int) async throws {
        let tex = """
            \\documentclass[\(pointSize)pt]{beamer}
            \\begin{document}\\begin{frame}{Scale mark}Scale note.\\end{frame}\\end{document}
            """
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let printed = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex),
            settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let reference = pointSize == 8 ? [10.95, 8] : [29.86, 20.74]
        for (word, texSize) in zip(["Scale mark", "Scale note"], reference) {
            let hit = try #require(printed.logicalDocument.findString(word, withOptions: []).first?.attributedString)
            let font = try #require(hit.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(abs(font.pointSize - texSize * 72 / 72.27) < 0.05)
        }
    }

    // Measure the actual text baseline. A definition label and three sizes of list
    // text have different ink depths and PDFKit selection bounds.
    private func baselines(in view: WKWebView, frame: Int, words: [String]) async throws -> [Double] {
        let value = try await view.evaluateForPrinting(
            """
            const body = document.querySelector('[data-frame="' + frame + '"] > .beamer-frame-body');
            const text = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
            return words.map(word => {
                let node;
                while ((node = text.nextNode()) && node.data.trim() !== word) {}
                if (!node) throw Error('Missing baseline: ' + word);
                const mark = document.createElement('span');
                mark.style.cssText = 'display:inline-block;height:0;width:0;vertical-align:baseline';
                node.before(mark);
                const y = mark.getBoundingClientRect().bottom;
                mark.remove();
                return y / pixelsPerPoint;
            });
            """,
            arguments: ["frame": frame, "words": words, "pixelsPerPoint": WebPaginator.printPixelsPerPoint],
            until: .now + .seconds(3))
        return try #require(value as? [Double])
    }

    @Test("子リストから親項目の本文と次の項目へ戻るときは、閉じたリストの空きを一度だけ取る", .timeLimit(.minutes(1)))
    func returningFromSublist() async throws {
        let tex = #"""
            \documentclass{beamer}\begin{document}\begin{frame}[t]
            \begin{itemize}\item Entry
            \begin{itemize}\item Leaf\end{itemize}
            Resume
            \begin{itemize}\item Child\end{itemize}
            \item Sibling\end{itemize}
            \end{frame}\end{document}
            """#
        let words = ["Entry", "Leaf", "Resume", "Child", "Sibling"]
        let paginator = WebPaginator()
        var rows: [Double] = []
        paginator.inspectPrintLayout = { view in
            do { rows = try await self.baselines(in: view, frame: 1, words: words) } catch { Issue.record(error) }
        }
        let renderer = DocumentRenderer(paginateWithResult: { request in try await paginator.paginate(request) })
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == PrintThemeLibrary.slideStyleID })
        _ = try await renderer.prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex),
            settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        try #require(rows.count == words.count)
        // Resume ends at the next sublist (small pitch); Sibling ends at the outer size.
        for (i, expected) in [13.948, 13.947, 13.948, 16.538].enumerated() {
            let gap = rows[i + 1] - rows[i]
            #expect(abs(gap - expected) <= 0.1, "\(words[i]) → \(words[i + 1]) 基線 \(gap) pt、実 TeX \(expected) pt")
        }
    }

    @Test(
        "スライドの用紙と読む順序を実 TeX の原稿と照合する", .timeLimit(.minutes(1)),
        arguments: ["specimen", "additive", "swap", "handout", "overflow", "083"])
    func slidePaper(_ name: String) async throws {
        let folder = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/Beamer")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let corpus = root.appendingPathComponent("Snapshots/corpus/latex")
        let sourceURL: URL
        let referenceURL: URL
        if name == "083" {
            sourceURL = try #require(
                FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix("083-") }
            ).appendingPathComponent("main.tex")
            referenceURL = root.appendingPathComponent("Snapshots/reference/latex/083.pdf")
        } else {
            sourceURL = folder.appendingPathComponent(name + ".tex")
            referenceURL = folder.appendingPathComponent((name == "additive" ? "additive-handout" : name) + ".pdf")
        }
        let reference = try #require(PDFDocument(url: referenceURL))
        let source = DocumentSource(data: try Data(contentsOf: sourceURL), fileURL: sourceURL, format: .latex)
        let paginator = WebPaginator()
        var measurement: String?
        var listBaselines: [Double]?
        let listWords = ["Mark the", "Yard stick", "Copper sleeve", "Inner pin", "Cut", "File", "Tip"]
        let measuredPages = name == "083" ? [1, 2] : [0, 2, 3, 5, 8]
        let dumpPath = ProcessInfo.processInfo.environment["SURIMONO_LATEX_WEBKIT_LINE_DUMP"]
        if name == "083" || name == "specimen" {
            // Record the layout in the actual print view. The final PDF alone cannot show
            // whether the list pitches drifted in the DOM or only while printing its glyphs.
            paginator.inspectPrintLayout = { view in
                do {
                    if name == "specimen" {
                        listBaselines = try await self.baselines(in: view, frame: 3, words: listWords)
                    }
                    let value = try await view.evaluateForPrinting(
                        """
                        const frames = [...document.querySelectorAll('.beamer-frame')];
                        if (!frames.length) return null;
                        const result = [];
                        for (const index of indices) {
                            const frame = frames[index];
                            if (!frame) continue;
                            const root = frame.getBoundingClientRect();
                            const elems = frame.querySelectorAll('.beamer-frame-heading,.beamer-frame-body,.beamer-block-title,.beamer-block-body,li,.latex-item-mark,.beamer-bib-icon,.latex-front-date,.beamer-titlegraphic,pre');
                            const rows = [...elems].slice(0,16).map(el => {
                                const r=el.getBoundingClientRect(), cs=getComputedStyle(el);
                                const row = [el.classList[0] || el.localName, +(r.top-root.top).toFixed(2), +r.height.toFixed(2), cs.lineHeight];
                                if (el.matches('.beamer-bib-icon')) {
                                    const icon = getComputedStyle(el, '::before');
                                    row.push({iconTop:+(r.bottom-root.top-parseFloat(icon.bottom)-parseFloat(icon.height)).toFixed(2),
                                        iconHeight:icon.height});
                                }
                                return row;
                            });
                            // Two out-of-flow marks in the empty gutter locate the frame on the
                            // physical sheet independently of text metrics and PDFKit selections.
                            if (markGutter) {
                                for (const y of [16, 288]) {
                                    const mark = document.createElement('span');
                                    mark.style.cssText = 'position:absolute;left:3px;top:'+y+'px;width:4px;height:3px;background:#ff00ff';
                                    frame.append(mark);
                                }
                            }
                            result.push([index+1, +root.height.toFixed(2), rows]);
                        }
                        return JSON.stringify({dpr:devicePixelRatio,media:matchMedia('print').matches,frames:result});
                        """,
                        arguments: ["indices": measuredPages, "markGutter": dumpPath == nil], until: .now + .seconds(3))
                    if let value = value as? String { measurement = value }
                } catch { measurement = String(describing: error) }
            }
        }
        let renderer = DocumentRenderer(paginateWithResult: { request in try await paginator.paginate(request) })
        let style = PrintThemeLibrary.defaultLaTeXStyle(for: renderer.latexClassInfo(for: source))
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == style })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        let result = try await renderer.prepare(source, settings: settings)
        let pdf = result.logicalDocument
        if let measurement {
            print("Beamer \(name) DOM [page,height,[element,top,height,lineHeight]] CSS px \(measurement)")
        }
        if name == "specimen" {
            let rows = try #require(listBaselines, "\(measurement ?? "基線を取得できない")")
            try #require(rows.count == listWords.count)
            // Baseline advances in the text stream of specimen.pdf, page 3, in PDF points.
            // A tenth of a point covers the integral CSS line box between Cut and File
            // and the fractional CSS pixel used for each measured margin.
            let advances = [14.944, 12.952, 12.951, 19.527, 16.538, 19.527]
            for (index, expected) in advances.enumerated() {
                let gap = rows[index + 1] - rows[index]
                #expect(
                    abs(gap - expected) <= 0.1,
                    "\(listWords[index]) → \(listWords[index + 1]) 基線 \(gap) pt、実 TeX \(expected) pt")
            }
        }
        if measurement != nil && dumpPath == nil {
            for index in measuredPages {
                let page = try #require(pdf.page(at: index))
                let pixels = try PagePixels(page)
                var tops: [CGFloat] = []
                var inMark = false
                for row in 0..<pixels.height {
                    let y = CGFloat(row) / pixels.scale
                    let marked = (0..<32).contains { column in
                        let rgb = pixels.color(atX: CGFloat(column) / pixels.scale, y: y)
                        return rgb.red > 200 && rgb.blue > 200 && rgb.green < 60
                    }
                    if marked && !inMark { tops.append(y) }
                    inMark = marked
                }
                print(
                    "Beamer \(name) p\(index + 1) DOM y=[16,288]px PDF y=\(tops)pt crop=\(page.bounds(for: .cropBox)) media=\(page.bounds(for: .mediaBox))"
                )
            }
        }
        if let path = dumpPath {
            #expect(pdf.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".pdf")))
        }
        let size = try #require(reference.page(at: 0)).bounds(for: .mediaBox)
        for i in 0..<pdf.pageCount {
            let actual = try #require(pdf.page(at: i)).bounds(for: .mediaBox)
            #expect(abs(actual.width - size.width) < 0.02)
            #expect(abs(actual.height - size.height) < 0.02)
        }
        if name == "overflow" {
            // TeX clips the final sounding; the reader continues it on one additional slide.
            #expect(result.facts?.continuedBeamerFrames == 1)
            #expect(result.facts?.beamerPageFrames == [1, 2, 2, 3, 3, 4])
            #expect(pdf.pageCount == reference.pageCount + 1)
            for (page, line) in [(3, "West bank"), (4, "East bank")] {
                #expect(pdf.page(at: page)?.string?.contains(line) == true)
                #expect(reference.page(at: page - 1)?.string?.contains(line) == true)
            }
            #expect(pdf.findString("Last sounding", withOptions: []).count == 1)
            #expect(pdf.findString("First sounding", withOptions: []).count == 1)
            #expect(pdf.findString("Last mark", withOptions: []).count == 1)
        } else {
            #expect(pdf.pageCount == reference.pageCount)
        }
        try compareBeamerReference(pdf, to: reference, fixture: name)
        if name == "swap" {
            #expect(pdf.page(at: 0)?.string?.contains("Low water") == true)
            #expect(pdf.page(at: 1)?.string?.contains("High water") == true)
            #expect(pdf.findString("next mark", withOptions: []).count == 1)
        }
        if name == "handout" {
            #expect(pdf.findString("Mark the page", withOptions: []).count == 1)
            #expect(pdf.findString("Projection copy", withOptions: []).isEmpty)
        }
    }
}

import AppKit
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

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
        if name == "083" || name == "specimen" {
            // Record the layout in the actual print view. The final PDF alone cannot show
            // whether the list pitches drifted in the DOM or only while printing its glyphs.
            paginator.inspectPrintLayout = { view in
                do {
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
                                return [el.classList[0] || el.localName, +(r.top-root.top).toFixed(2), +r.height.toFixed(2), cs.lineHeight];
                            });
                            result.push([index+1, +root.height.toFixed(2), rows]);
                        }
                        return JSON.stringify({dpr:devicePixelRatio,media:matchMedia('print').matches,frames:result});
                        """,
                        arguments: ["indices": name == "083" ? [1, 2] : [0, 2, 3, 5, 8]], until: .now + .seconds(3))
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
        if let path = ProcessInfo.processInfo.environment["SURIMONO_LATEX_WEBKIT_LINE_DUMP"] {
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

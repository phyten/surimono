import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXLatinPrintingTests {
    @Test("明示した細い空きは六分の一emで組み、直書きした狭い空白は書体の幅を保つ", .timeLimit(.minutes(1)))
    func explicitThinSpace() async throws {
        let source = #"""
            \documentclass{article}\usepackage[main,final]{neurips_2026}\begin{document}
            We measured 0.06\,mm then 0.06 mm on the rail and checked the scale.
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
        let probe =
            try LaTeXFlowPaginator.latinLineScript() + #"""

                document.body.style.width = '400px';
                document.body.style.zoom = '32';
                document.body.style.transform = 'scale(0.03125)';
                document.body.style.transformOrigin = 'top left';
                document.body.getBoundingClientRect(); await document.fonts.ready;
                globalThis.surimonoLatinDiagnostics = globalThis.surimonoLatinBoxDiagnostics = true;
                const p = document.querySelector('p'), text = p.textContent;
                const paragraph = latinCompose(document.body).paragraphs[0];
                if (paragraph.fallback) return paragraph.fallback;
                const words = paragraph.boxDiagnostics.words;
                const kern = p.querySelector('.latex-line [data-latex-thin-space]');
                if (!kern) return p.outerHTML;
                const em = parseFloat(getComputedStyle(p).fontSize);
                return JSON.stringify([kern?.getBoundingClientRect().width/em,
                    (words[4].width-words[2].width)/em, Number(text === p.textContent)]);
                """#
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: probe, timeout: .seconds(15))
        let json = try #require(result.preparationResult)
        try #require(json.first == "[", Comment(rawValue: json))
        let values = try JSONDecoder().decode([Double].self, from: Data(json.utf8))
        try #require(values.count == 3)
        #expect(abs(values[0] - 0.16667) < 0.001)
        #expect(abs(values[1] - (0.2 - 0.16667)) < 0.001)
        #expect(values[2] == 1)
    }

    @Test("数式と一緒に折り返す句点も次の語間を文末の空きにする", .timeLimit(.minutes(1)))
    func punctuationAfterInlineMath() async throws {
        let source = #"""
            \documentclass{article}\sloppy\begin{document}
            We measured $t$. Then we folded the paper.
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
        let probe =
            try LaTeXFlowPaginator.latinLineScript() + """

                await document.fonts.ready;
                globalThis.surimonoLatinDiagnostics = globalThis.surimonoLatinBoxDiagnostics = true;
                const words = latinCompose(document.body).paragraphs[0].boxDiagnostics.words;
                return JSON.stringify([words[0].glue, words[2].glue]);
                """
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: probe, timeout: .seconds(15))
        let json = try #require(result.preparationResult)
        let glue = try JSONDecoder().decode([[Double]].self, from: Data(json.utf8))
        try #require(glue.count == 2 && glue.allSatisfy { $0.count == 3 })
        #expect(glue[1][0] > glue[0][0])
        #expect(abs(glue[1][1] - 3 * glue[0][1]) < 0.001)
        #expect(abs(3 * glue[1][2] - glue[0][2]) < 0.001)
    }

    private struct Measurement: Decodable {
        struct Paragraph: Decodable {
            struct Line: Decodable {
                let measure, width, height, pitch: Double
                let minSpaceSlack: Double?
            }
            let text: String
            let lines: [Line]
            let fallback: String?
        }
        let paragraphs: [Paragraph]
    }

    @Test(
        "標準記事と学会の印刷で行末・語間・行送りを守り、検索と本文の順を保つ", .timeLimit(.minutes(1)),
        arguments: ["native", "columns", "conference"])
    func composition(route: String) async throws {
        let rich = route == "conference"
        let preamble: String
        switch route {
        case "columns": preamble = #"\documentclass[twocolumn]{article}"#
        case "conference": preamble = #"\documentclass{article}\usepackage[main,final]{neurips_2026}"#
        default: preamble = #"\documentclass{article}\sloppy"#
        }
        let linked = "the measured mark on the rail and the matching mark on the card"
        let middle =
            rich ? #"\href{https://example.org/rail}{\emph{\#(linked)}}\footnote{Inspect the folded edge.}"# : linked
        let prose =
            "A paper rail rests on the board. We check " + middle
            + " before we fold the strip. The two marks should meet when the card lies flat. "
            + "On the last pass we check the stop and record the final position."
        let fragment = LaTeXConverter.convert(preamble + #"\begin{document}\noindent "# + prose + #"\end{document}"#)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        let flow = fragment.latexClass?.resolvedStyle != nil || LaTeXFlowPaginator.needed(in: fragment.body)
        #expect(flow == (route != "native"))
        let paginator = WebPaginator()
        paginator.collectsLatinLineDiagnostics = true
        let result = try await paginator.paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 23),
            allowsJavaScript: false, composesLaTeXParagraphs: true, latexFlow: flow,
            timeout: .seconds(15))
        #expect(result.issues.isEmpty)
        let json = try #require(paginator.latinLineDiagnostics)
        let measurement = try JSONDecoder().decode(Measurement.self, from: Data(json.utf8))
        let paragraph = try #require(measurement.paragraphs.first { $0.text.hasPrefix("A paper rail") })
        try #require(paragraph.fallback == nil, "段落の復元理由 \(paragraph.fallback ?? "")")
        try #require(paragraph.lines.count >= 2)
        #expect(paragraph.text.contains(linked + (rich ? "1" : "") + " before"))
        for line in paragraph.lines {
            if let slack = line.minSpaceSlack { #expect(slack >= -0.001) }
            #expect(abs(line.height - line.pitch) <= 0.1)
        }
        for line in paragraph.lines.dropLast() {
            #expect(abs(line.width - line.measure) / WebPaginator.printPixelsPerPoint <= 0.3)
        }
        let pdf = result.document
        #expect(pdf.findString("A paper rail", withOptions: []).count == 1)
        let text = try #require(pdf.string)
        let words = text.filter { !$0.isWhitespace && $0 != "-" }
        let expected = prose.replacingOccurrences(of: middle, with: linked + (rich ? "1" : ""))
        #expect(words.contains(expected.filter { !$0.isWhitespace }))
        if rich { #expect(pdf.findString("Inspect the folded edge", withOptions: []).count == 1) }
    }

    @Test("複数行にまたがるリンクと強調を複製し、復元時には同じノードと属性に戻す", .timeLimit(.minutes(1)))
    func inlineIdentityAndRollback() async throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let tex = #"\documentclass{article}\usepackage[main,final]{neurips_2026}\begin{document}Body.\end{document}"#
        let fragment = LaTeXConverter.convert(tex)
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        let probe =
            try LaTeXFlowPaginator.latinLineScript() + #"""

                document.body.style.width = '190px';
                document.body.style.textAlign = 'justify';
                const a = document.createElement('a');
                a.href = 'https://example.org/fold';
                a.id = 'material';
                const em = document.createElement('em');
                em.textContent = 'the board and the stop on the card with the marks on the rail and the frame';
                a.append(em);
                const p = document.querySelector('p');
                p.replaceChildren('Fold at ', a, ' to read the scale.');
                const original = p.outerHTML;
                const bad = p.cloneNode(true);
                bad.querySelector('a').id = 'duplicate-check';
                bad.id = 'rollback';
                const first = bad.firstChild, inside = bad.querySelector('em'), before = bad.outerHTML;
                document.body.append(bad);
                const style = document.createElement('style');
                // Introduce a post-insertion pitch error. Restoring source nodes must also preserve their identity.
                style.textContent = '#rollback .latex-line {min-height: 120px!important}';
                document.head.append(style);
                p.getBoundingClientRect();
                await document.fonts.ready;
                globalThis.surimonoLatinDiagnostics = true;
                const undo = [];
                const sample = document.createElement('p');
                sample.textContent = 'A natural line in the regular face and another natural line with more text. '.repeat(3);
                document.body.append(sample);
                const sampleRange = document.createRange();
                sampleRange.selectNodeContents(sample);
                const nativePitch = sample.getBoundingClientRect().height / sampleRange.getClientRects().length;
                sample.remove();
                const result = latinCompose(document.body, 1, undo);
                const links = [...p.querySelectorAll('.latex-line a')];
                const intact = links.length > 1 && links.every(a => a.getAttribute('href') === 'https://example.org/fold'
                    && a.querySelector('em')) && links.map(a => a.textContent).join('') === em.textContent &&
                    p.querySelectorAll('[id="material"]').length === 1;
                const pitch = result.paragraphs[0]?.lines[0]?.pitch;
                const measured = Math.abs(pitch-nativePitch) < .06;
                const failed = result.fallbacks === 1 && bad.outerHTML === before &&
                    bad.firstChild === first && bad.querySelector('em') === inside;
                for (const restore of undo.reverse()) restore();
                return JSON.stringify([intact, failed, measured, p.outerHTML === original && p.querySelector('a') === a]);
                """#
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: probe, timeout: .seconds(15))
        #expect(result.preparationResult == "[true,true,true,true]")
    }

    @Test("ネイティブよりも行数が増える計画を採らない", .timeLimit(.minutes(1)))
    func preservesShorterNativeParagraph() async throws {
        let source =
            #"\documentclass{article}\sloppy\begin{document}\noindent Fold. Press. Unfold. Measure. Repeat. Record the result.\end{document}"#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
        let probe =
            try LaTeXFlowPaginator.latinLineScript() + #"""
                const p = document.querySelector('p');
                p.style.width = '116px';
                const first = p.firstChild, original = p.outerHTML;
                globalThis.surimonoLatinDiagnostics = true;
                globalThis.surimonoLatinBoxDiagnostics = true;
                await document.fonts.ready;
                const paragraph = latinCompose(document.body).paragraphs[0];
                return JSON.stringify([paragraph.fallback, paragraph.boxDiagnostics.nativeLines,
                    paragraph.boxDiagnostics.ratios.length, p.outerHTML === original && p.firstChild === first]);
                """#
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: probe, timeout: .seconds(15))
        #expect(result.preparationResult == #"["more lines than native",3,4,true]"#)
    }

    @Test("タイの両側は同じ行で伸び、著者年の引用内ではリンクと文字を保って改行する", .timeLimit(.minutes(1)))
    func tiedAndCitedWords() async throws {
        let source = #"\documentclass{article}\usepackage[main,final]{neurips_2026}\begin{document}Body.\end{document}"#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
        let probe =
            try LaTeXFlowPaginator.latinLineScript() + #"""

                const p = document.querySelector('p');
                p.style.textIndent = '0';
                p.innerHTML = '<span id="rail">Rail</span>&nbsp;<span id="desk">Desk</span> <span id="fits">fits</span> ' +
                    '<span class="latex-cite" data-latex-cite-text>(<a href="#model" id="cited">Model Rail Desk and ' +
                    'the Windows Fixture Room Group, 2025</a>)</span> with other realistic scales.';
                document.body.style.width = '127px';
                const text = p.textContent;
                document.body.getBoundingClientRect();
                await document.fonts.ready;
                globalThis.surimonoLatinDiagnostics = true;
                const result = latinCompose(document.body);
                const row = result.paragraphs[0];
                const rail = document.querySelector('#rail'), desk = document.querySelector('#desk'), fits = document.querySelector('#fits');
                const rect = el => { const r = document.createRange(); r.selectNodeContents(el); return r.getBoundingClientRect(); };
                const tied = rect(desk).left - rect(rail).right, normal = rect(fits).left - rect(desk).right;
                const natural = .25 * parseFloat(getComputedStyle(p).fontSize);
                const fragments = [...p.querySelectorAll('.latex-line .latex-cite a')];
                const sourceText = 'Model Rail Desk and the Windows Fixture Room Group, 2025';
                return JSON.stringify({fallback:row.fallback, tied, normal, natural,
                    adjacent:rail.closest('.latex-line') === desk.closest('.latex-line') &&
                        desk.closest('.latex-line') === fits.closest('.latex-line'),
                    fragments:fragments.length, markup:p.querySelectorAll('#cited').length === 1 &&
                        fragments.every(a => a.getAttribute('href') === '#model') &&
                        fragments.map(a => a.textContent).join('') === sourceText && p.textContent === text});
                """#
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: probe, timeout: .seconds(15))
        struct Check: Decodable {
            let fallback: String?
            let tied, normal, natural: Double
            let fragments: Int
            let adjacent, markup: Bool
        }
        let json = try #require(result.preparationResult)
        let check = try JSONDecoder().decode(Check.self, from: Data(json.utf8))
        try #require(check.fallback == nil, Comment(rawValue: json))
        #expect(check.adjacent && check.markup && check.fragments >= 2)
        #expect(abs(check.tied - check.normal) < 0.15)
        #expect(check.tied > check.natural + 0.2, Comment(rawValue: json))
    }

    @Test("段落見出しの語間と本文を同じ比率で調整し、見出しの後の空きと基線を保つ", .timeLimit(.minutes(1)), arguments: [1, 32])
    func runIn(precision: Int) async throws {
        let source = #"""
            \documentclass{article}\usepackage{aaai2026}\begin{document}
            \paragraph{Card thickness.} We read the thickness of the folded card and write down the result.
            The card rests against the rail and the mark can be read from the edge of the scale.
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
        let probe =
            try LaTeXFlowPaginator.latinLineScript() + #"""

                const wrapper = document.querySelector('.latex-runin'), p = wrapper.querySelector('p');
                document.body.style.zoom = '\#(precision)';
                document.body.style.transform = 'scale(' + (1 / \#(precision)) + ')';
                document.body.style.transformOrigin = 'top left';
                wrapper.style.width = '223px';
                wrapper.getBoundingClientRect(); await document.fonts.ready;
                const bounds = el => {const r = document.createRange(); r.selectNodeContents(el); return r.getBoundingClientRect();};
                const h = wrapper.firstElementChild, before = bounds(h);
                const ordinary = document.createRange(); ordinary.setStart(p.firstChild,0); ordinary.setEnd(p.firstChild,1);
                const rise = ordinary.getBoundingClientRect().top-before.top;
                const expectedGap = ordinary.getBoundingClientRect().left-before.right;
                h.style.backgroundColor = 'rgb(255, 250, 242)';
                const original = wrapper.outerHTML, titleText = h.firstChild, bodyText = p.firstChild, undo = [];
                const wrapped = wrapper.cloneNode(true), longHead = wrapped.firstElementChild;
                wrapped.style.width = '85px';
                longHead.removeAttribute('id');
                longHead.textContent = 'A longer heading that occupies several native lines';
                document.body.append(wrapped);
                const wrappedHTML = wrapped.outerHTML, wrappedTitle = longHead.firstChild;
                globalThis.surimonoLatinDiagnostics=true;
                const summary=latinCompose(document.body,1,undo), line=p.querySelector('.latex-line');
                const word=document.createRange();
                if (line) {word.setStart(line.firstChild,0); word.setEnd(line.firstChild,1);}
                const after=bounds(h), first=word.getBoundingClientRect();
                const space = (node,left,right) => {
                    const range = document.createRange();
                    range.setStart(node,left-1); range.setEnd(node,left);
                    const end = range.getBoundingClientRect().right;
                    range.setStart(node,right); range.setEnd(node,right+1);
                    return range.getBoundingClientRect().left-end;
                };
                const result = {reason:summary.paragraphs[0]?.fallback, lines:p.children.length,
                    gap:first.left-after.right, expectedGap, baselineError:first.top-after.top-rise,
                    headingSpace:line && space(h.firstChild,4,5), bodySpace:line && space(line.firstChild,2,3),
                    natural:.25 * parseFloat(getComputedStyle(p).fontSize)};
                result.wrapped = summary.paragraphs[1]?.fallback === 'wrapped run-in heading' &&
                    wrapped.outerHTML === wrappedHTML && wrappedTitle === longHead.firstChild;
                wrapped.remove();
                for (const restore of undo.reverse()) restore();
                result.restored = wrapper.outerHTML === original && titleText === h.firstChild && bodyText === p.firstChild;
                latinCompose(document.body);
                return JSON.stringify(result);
                """#
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size, margins: .uniform(millimeters: 20),
            allowsJavaScript: false, preparationScript: probe, timeout: .seconds(15))
        struct Geometry: Decodable {
            let reason: String?
            let lines: Int
            let gap, expectedGap, baselineError, natural: Double
            let headingSpace, bodySpace: Double?
            let restored, wrapped: Bool
        }
        let json = try #require(result.preparationResult)
        let geometry = try JSONDecoder().decode(Geometry.self, from: Data(json.utf8))
        try #require(geometry.reason == nil && geometry.lines >= 2, Comment(rawValue: json))
        #expect(abs(geometry.gap - geometry.expectedGap) < 0.2, Comment(rawValue: json))
        #expect(abs(geometry.baselineError) < 0.2)
        #expect(geometry.restored && geometry.wrapped)
        let headingSpace = try #require(geometry.headingSpace)
        let bodySpace = try #require(geometry.bodySpace)
        // Whole-pixel glyph origins make a short space read a pixel wider or narrower.
        #expect(abs(headingSpace - bodySpace) < 1.1 / Double(precision) + 0.05, Comment(rawValue: json))
        if precision > 1 {
            #expect(abs(headingSpace - geometry.natural) > 0.3, Comment(rawValue: json))
        }
        #expect(result.document.findString("Card thickness.", withOptions: []).count == 1)
        #expect(result.document.findString("We read", withOptions: []).count == 1)
    }
}

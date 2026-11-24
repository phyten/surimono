import AppKit
import PDFKit
import SurimonoCore
import Testing
import WebKit

@testable import SurimonoRendering

@MainActor
struct VerticalMixedContentTests {
    // Distinct ink colors let a PDF test find outlines and subscripts even if they have no searchable text.
    private let colors = """
        .surimono-vertical .math-display svg {color:#db009f}
        .surimono-vertical .footnotes {color:#009c3c}
        .surimono-vertical pre, .surimono-vertical pre * {color:#222 !important}
        """

    private func inkPages(in document: PDFDocument) throws -> (equations: [Int], notes: [Int], noteText: String) {
        var equations: [Int] = []
        var notes: [Int] = []
        var noteText = ""
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            let pixels = try PagePixels(page)
            if pixels.bounds(where: { r, g, b in r > g + 100 && b > g + 75 }) != nil { equations.append(index) }
            if var bounds = pixels.bounds(where: { r, g, b in g > r + 75 && g > b + 50 }) {
                notes.append(index)
                bounds.origin.y = page.bounds(for: .cropBox).maxY - bounds.maxY
                noteText += page.selection(for: bounds.insetBy(dx: -1, dy: -1))?.string ?? ""
            }
        }
        return (equations, notes, noteText)
    }

    @Test("実機の混植原稿を通常の組版経路で開くと別行数式と文末脚注のインクが紙に載る", .timeLimit(.minutes(1)))
    func manuscript() async throws {
        _ = NSApplication.shared
        let url = try #require(
            Bundle.module.url(forResource: "vertical-mix", withExtension: "md", subdirectory: "Fixtures"))
        let source = DocumentSource(data: try Data(contentsOf: url), format: .markdown)
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let theme = PrintTheme(id: style.id, name: style.name, css: style.css + "\n" + colors, flow: style.flow)
        let paper = try await DocumentRenderer().prepare(
            source, settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let ink = try inkPages(in: paper.logicalDocument)
        try #require(ink.equations.count == 1 && ink.notes.count == 1)
        #expect(ink.notes[0] >= ink.equations[0])
        #expect(ink.noteText.filter { !$0.isWhitespace }.contains("脚注は文書の終わりに置く。"))
    }

    @Test("混植原稿の各文字と各箱が一つの切片に収まり、末尾の数式と脚注まで印刷される", .timeLimit(.minutes(1)))
    func slices() async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let source = #"""
            {端|はし}*点*

            | 用紙 | 段 |
            |---|---|
            | A4 | 2 |

            ```swift
            let x = 1
            print(x)
            ```

            - 箱に続く項目

            <span id="slice-probe">\#(String(repeating: "庭の 桜", count: 560))</span>

            <p id="edge-probe" style="text-indent:0">\#(String(repeating: "本", count: 30))PDF本</p>

            > 短い引用。

            - 一つ目
            - 二つ目

            *強調*と{漢字|かんじ}、脚注[^a]。さらに[別の語](https://example.org/)[^a]。

            <span id="before">本</span><br><span id="middle">本</span>数式 $E=mc^2$ と<br><span id="after">本</span>

            $$\int_0^1 x^2\,dx=\frac13$$

            <figure><svg width="24" height="12" viewBox="0 0 24 12"><rect width="24" height="12"/></svg></figure>

            [^a]: 脚注は文書の終わりに置く。
            """#
        let size = PaperSize.a4.size
        let margins = WebPaginator.Margins(top: 36, left: 36, bottom: 36, right: 36)
        // A short containing block makes leftward overflow deterministic on every WebKit version.
        let html = HTMLDocumentBuilder.build(
            fragment: MarkdownConverter.convert(source), format: .markdown, theme: theme,
            // Change the first visibility span's advance so a capture measured before indexing loses its alignment.
            finish:
                ".surimono-vertical {block-size:160px} #slice-probe > span:first-child {padding-inline-start:1.25em}\n"
                + colors)
        let view = WKWebView(frame: CGRect(origin: .zero, size: size))
        let navigation = NavigationTracker()
        view.navigationDelegate = navigation
        view.loadHTMLString(html, baseURL: nil)
        try await WebPaginator.waitUntil(timeout: .seconds(10)) { navigation.state != .loading }
        try #require(navigation.state == .finished)
        // Record the real Markdown DOM before the paginator gets a chance to wrap or split anything.
        let setup = #"""
            await document.fonts.ready;
            globalThis.units = root => {
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                const result = [];
                for (let n = walker.nextNode(); n; n = walker.nextNode()) {
                    if (n.parentElement.closest('style,script,rp,svg')) continue;
                    const prose = n.parentElement.closest('#slice-probe');
                    for (let i = 0; i < n.length; ++i) if (prose || /\S/u.test(n.data[i])) result.push([n,i]);
                }
                return result;
            };
            globalThis.literal = document.body.textContent;
            globalThis.original = units(document.body).map(([n,i]) => n.data[i]).join('');
            globalThis.boxes = [...document.querySelectorAll('table,pre,.math-inline > svg,.math-display > svg,figure,section.footnotes')];
            return boxes.length;
            """#
        let count = try await view.evaluateForPrinting(setup, arguments: [:], until: .now + .seconds(10))
        try #require(count as? Int == 6)

        let document = try await VerticalPaginator.pages(
            in: view, pageSize: size, margins: margins, timeout: .seconds(12))
        try #require(document.pageCount >= 2)
        let check = """
            const strip = document.querySelector('.surimono-vertical'), chars = units(strip), range = document.createRange();
            const seen = new Array(chars.length).fill(0), which = boxes.map(() => []);
            const missed = [];
            const box = el => el.getBoundingClientRect();
            const cx = r => r.left + r.width/2;
            const pitch = parseFloat(getComputedStyle(strip).lineHeight);
            const before = box(document.querySelector('#before')), middle = box(document.querySelector('#middle'));
            const after = box(document.querySelector('#after')), svg = document.querySelector('.math-inline svg');
            const m = svg.getScreenCTM(), vb = svg.viewBox.baseVal, ink = svg.getBBox();
            const rect = box(svg), slot = box(svg.parentElement);
            const quote = box(document.querySelector('blockquote'));
            const marks = [...document.querySelectorAll('sup.footnote-ref')];
            const shoulder = marks.length === 2 && marks.every(mark => {
                const note = box(mark);
                range.selectNodeContents(mark.parentElement.firstChild);
                const base = range.getBoundingClientRect();
                return mark.parentElement.classList.contains('vertical-note-base') && !mark.closest('a')
                    && cx(note)>cx(base) && note.top < base.top+base.height/2 && note.bottom>=base.top;
            });
            const inside = (r, [right,left,top,bottom]) => r.width > 0 && r.height > 0 && r.left >= left-1 && r.right <= right+1
                && r.top >= top-1 && r.bottom <= bottom+1;
            const quoteText = document.querySelector('blockquote p');
            range.selectNodeContents(quoteText);
            const quoteInk = range.getBoundingClientRect();
            let rows = 0;
            for (let cut; (cut = surimonoCaptureSlice(rows)); ++rows) {
                const [right, left] = cut;
                for (const [i,[n,offset]] of chars.entries()) {
                    if (getComputedStyle(n.parentElement).visibility !== 'visible') continue;
                    range.setStart(n,offset); range.setEnd(n,offset+1);
                    const r = range.getBoundingClientRect();
                    // A written space collapsed at a soft break still belongs to its visible fragment.
                    if (inside(r,cut) || (!r.height && n.data[offset]===' ')) ++seen[i];
                    else if (missed.length < 10) missed.push([rows,i,n.data[offset],r.left,r.right,left,right]);
                }
                boxes.forEach((el,i) => {
                    if (getComputedStyle(el).visibility === 'visible' && inside(box(el),cut)) which[i].push(rows);
                });
            }
            return {
                rows, which, missed, length:chars.length,
                originalText: strip.textContent === literal,
                edgeGaps: [...strip.querySelectorAll('#edge-probe .aki')].map(gap =>
                    [...gap.getClientRects()].reduce((sum,r) => sum+r.height,0)/parseFloat(getComputedStyle(strip).fontSize)),
                indexed: parseFloat(getComputedStyle(document.querySelector('#slice-probe > span')).paddingTop)>0,
                fullColumns: [...strip.querySelectorAll('.horizontal-box-line')].every(line => {
                    const r = box(line), content = box(line.firstElementChild), stage = box(strip);
                    return Math.abs(r.top-stage.top)<1 && Math.abs(r.bottom-stage.bottom)<1 && Math.abs(content.top-r.top)<1;
                }),
                listStart: (() => {
                    const line = document.querySelector('pre').parentElement, list = line.nextElementSibling;
                    range.selectNodeContents(list.querySelector('li').firstChild);
                    const item = range.getBoundingClientRect();
                    return list.localName==='ul' && item.right<=box(line).left+1 && item.top < box(strip).top + pitch;
                })(),
                codeFrame: getComputedStyle(document.querySelector('pre')).borderTopStyle==='solid'
                    && getComputedStyle(document.querySelector('pre')).backgroundColor==='rgba(0, 0, 0, 0)',
                tableHead: getComputedStyle(document.querySelector('th')).backgroundColor==='rgb(240, 240, 240)',
                same: chars.map(([n,i]) => n.data[i]).join('') === original,
                missing:seen.filter(n => !n).length, duplicate:seen.filter(n => n>1).length,
                clockwise: m.b>0 && m.c<0 && Math.abs(m.a)+Math.abs(m.d)<0.01
                    && getComputedStyle(svg.querySelector('text')).writingMode==='horizontal-tb',
                formula: [cx(rect)-cx(middle), before.left-middle.left-pitch, middle.left-after.left-pitch],
                contained: rect.left>=slot.left-1 && rect.right<=slot.right+1 && rect.top>=slot.top-1
                    && rect.bottom<=slot.bottom+1 && ink.x>=vb.x-0.1 && ink.y>=vb.y-0.1
                    && ink.x+ink.width<=vb.x+vb.width+0.1 && ink.y+ink.height<=vb.y+vb.height+0.1,
                quote: [quote.height,quoteInk.height],
                shoulder
            };
            """
        let result = try #require(
            try await view.evaluateForPrinting(check, arguments: [:], until: .now + .seconds(10)) as? [String: Any])
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        Attachment.record(String(decoding: json, as: UTF8.self), named: "vertical-mix.json")
        #expect(result["same"] as? Bool == true)
        #expect(result["missing"] as? Int == 0 && result["duplicate"] as? Int == 0)
        #expect((result["missed"] as? [Any])?.isEmpty == true)
        let which = try #require(result["which"] as? [[Int]])
        try #require(which.count == 6 && which.allSatisfy { $0.count == 1 })
        #expect(which[0] == [0] && which[1] == [0])
        #expect(which[3][0] >= 2 && which[4][0] >= which[3][0] && which[5][0] >= which[4][0])
        for flag in [
            "clockwise", "contained", "shoulder", "originalText", "indexed", "fullColumns", "listStart", "codeFrame",
            "tableHead",
        ] { #expect(result[flag] as? Bool == true, "\(flag)") }
        let gaps = try #require(result["edgeGaps"] as? [Double])
        try #require(gaps.count == 2)
        #expect(abs(gaps[0]) < 0.06 && abs(gaps[1] - 0.25) < 0.06, "切片にした後の行端と行内の四分アキ \(gaps) em")
        let formula = try #require(result["formula"] as? [Double])
        #expect(formula.allSatisfy { abs($0) < 2 }, "数式の中心と前後の行送りのずれ \(formula) px")
        let quote = try #require(result["quote"] as? [Double])
        #expect(abs(quote[0] - quote[1]) < 2, "引用の罫と文字列の長さ \(quote) px")

        // Colored ink checks the actual PDF capture as well as the DOM visibility decisions.
        let ink = try inkPages(in: document)
        #expect(ink.equations == [which[3][0] / 2])
        #expect(ink.notes == [which[5][0] / 2])
    }
}

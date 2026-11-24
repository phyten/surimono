import AppKit
import PDFKit
import SurimonoCore
import Testing
import WebKit

@testable import SurimonoRendering

private let mixManuscript = #"""
    # 第三章 混ぜ書き

    吾輩は試し刷りの文章である。「名前はまだ無い。」（どこで刷られたか）、とんと見当がつかぬ。

    ## 表とコード

    次の表は横組みのまま置く。

    | 用紙 | 段 | 字数 | 行数 |
    |---|---|---|---|
    | A4 | 2 | 30 | 24 |
    | A5 | 1 | 42 | 18 |

    ```swift
    let pages = paginate(document, paper: .a4)
    print("pages: \(pages.count)")
    ```

    - 一つ目の項目は少し長くして、二行目がぶら下がるかを確かめるための文章である。
    - 二つ目
      - 入れ子

    1. 番号の一
    2. 番号の二

    > 引用は一字下げて右に罫を引く。

    *強調*と *emphasis* と `code` と{漢字|かんじ}、脚注[^a]。数式 $E=mc^2$ と

    $$\int_0^1 x^2\,dx=\frac13$$

    [^a]: 脚注は文書の終わりに置く。

    """#

// Distinct ink colors let a PDF test find outlines and subscripts even if they have no searchable text.
private let manuscriptInkColors = """
    .surimono-vertical .math-display svg {color:#db009f}
    .surimono-vertical .footnotes {color:#009c3c}
    .surimono-vertical pre, .surimono-vertical pre * {color:#222 !important}
    """

@MainActor
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
            // A horizontal full stop paints in the first part of its cell. PDFKit's rectangle selection
            // needs the rest of that advance even when every pixel of the glyph is already inside.
            let line = bounds.insetBy(dx: -bounds.height, dy: -1)
            noteText += page.selection(for: line)?.string ?? ""
        }
    }
    return (equations, notes, noteText)
}

@MainActor
struct VerticalMixedContentTests {
    @Test("実機の混植原稿を通常の組版経路で開くと別行数式と文末脚注のインクが紙に載る", .timeLimit(.minutes(1)))
    func manuscript() async throws {
        _ = NSApplication.shared
        let source = DocumentSource(data: Data(mixManuscript.utf8), format: .markdown)
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let theme = PrintTheme(
            id: style.id, name: style.name, css: style.css + "\n" + manuscriptInkColors, flow: style.flow)
        let paper = try await DocumentRenderer().prepare(
            source, settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let ink = try inkPages(in: paper.logicalDocument)
        try #require(ink.equations.count == 1 && ink.notes.count == 1)
        #expect(ink.notes[0] >= ink.equations[0])
        #expect(ink.noteText.filter { !$0.isWhitespace }.contains("脚注は文書の終わりに置く。"))
    }

    @Test("縦組みの本は章ごとに改ページし、番号・ルビ・傍点・右傍線・別行式・表・脚注を印刷する", .timeLimit(.minutes(1)))
    func latexBook() async throws {
        _ = NSApplication.shared
        let source = #"""
            \documentclass[tate,book,openright,twocolumn]{jlreq}
            \begin{document}
            \chapter{春}\section{庭}
            本文\tatechuyoko{25}\ruby{花}{はな}\kenten{桜}\bou{線}。
            \[x=12\]
            \begin{tabular}{c}表\end{tabular}
            \chapter*{秋}
            月\footnote{秋の注。}
            \end{document}
            """#
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let inks = """
            .surimono-vertical .bousen { color: blue; text-decoration-color: red !important; }
            .surimono-vertical .kenten { text-emphasis-color: #00baba !important; }
            """
        let theme = PrintTheme(
            id: style.id, name: style.name, css: style.css + "\n" + manuscriptInkColors + inks, formats: style.formats,
            flow: style.flow)
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(source.utf8), format: .latex),
            settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let pdf = result.logicalDocument
        try #require(pdf.pageCount == 2)
        let first = try #require(pdf.page(at: 0))
        // PDF extraction may reorder vertical lines or separate the two combined digits.
        // Distinct glyphs identify the blocks; raster ink independently locates the formula and annotations.
        let text = first.string ?? ""
        for glyph in "春庭本文25花はな桜線表" { #expect(text.contains(glyph), "一ページ目の「\(glyph)」") }
        #expect(!text.contains("秋"))
        let second = try #require(pdf.page(at: 1)?.string)
        #expect(second.contains("秋") && second.contains("月"))
        let ink = try inkPages(in: pdf)
        #expect(ink.equations == [0] && ink.notes == [1])
        #expect(ink.noteText.filter { !$0.isWhitespace }.contains("秋の注。"))
        let pixels = try PagePixels(first)
        let line = try #require(pixels.bounds { r, g, b in r > max(g, b) + 100 })
        let glyph = try #require(pixels.bounds { r, g, b in b > max(r, g) + 100 })
        #expect(line.height > line.width && line.midX > glyph.maxX && abs(line.midY - glyph.midY) < 4)
        #expect(pixels.bounds { r, g, b in min(g, b) > r + 75 && abs(g - b) < 20 } != nil)
    }

    @Test(
        "縦組みの article は A4 で指定なしなら次ページ、二段指定なら同じ紙の下段に続く", .timeLimit(.minutes(1)),
        arguments: [false, true])
    func latexArticle(twoRows: Bool) async throws {
        _ = NSApplication.shared
        let rows = Array(repeating: "本文。", count: 27).joined(separator: "\n\n")
        let source = #"""
            \documentclass[tate\#(twoRows ? ",twocolumn" : "")]{jlreq}
            \begin{document}
            \section{始}\#(rows)

            \section{終}末尾。
            \end{document}
            """#
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let theme = PrintTheme(
            id: style.id, name: style.name, css: style.css + "\n.surimono-vertical h2:last-of-type { color: red; }",
            formats: style.formats, flow: style.flow)
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(source.utf8), format: .latex),
            settings: .init(layout: .a3BookletA4, theme: theme, preset: .init(id: "none", name: "")))
        let pdf = result.logicalDocument
        try #require(pdf.pageCount == (twoRows ? 1 : 2))
        let last = try #require(pdf.page(at: pdf.pageCount - 1))
        let ink = try #require(try PagePixels(last).bounds { r, g, b in r > max(g, b) + 100 })
        let middle = last.bounds(for: .cropBox).midY
        #expect(twoRows ? ink.minY > middle : ink.maxY < middle)
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
                + manuscriptInkColors)
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
            const vb = svg.viewBox.baseVal, ink = svg.getBBox();
            const rect = box(svg), slot = box(svg.parentElement);
            const glyphs = [...svg.querySelectorAll('text')];
            const centerY = character => {
                const glyph = glyphs.find(el => el.textContent === character);
                if (!glyph) return NaN;
                const r = box(glyph);
                return r.width > 0 && r.height > 0 ? r.top + r.height/2 : NaN;
            };
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
                clockwise: rect.height > rect.width && centerY('E') < centerY('2'),
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

extension VerticalPaginatorTests {
    @Test("縦組み本文の各段落末の句点が上段・下段・次ページに印刷される", .timeLimit(.minutes(1)))
    func paragraphEndInk() async throws {
        _ = NSApplication.shared
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        // Compare the last cell of each 30-by-24 row with a full stop well inside the first column.
        let colors = ["#ff0000", "#00a000", "#0000ff"]
        let body = colors.enumerated().map { index, color in
            let start = index == 0 ? "本<span style='color:#cd00cd'>。</span>" : "本文"
            return start + String(repeating: "本", count: 717) + "<span style='color:\(color)'>。</span>"
        }.joined(separator: "\n\n")
        let theme = PrintTheme(
            id: style.id, name: style.name, css: style.css + "\n.surimono-vertical p + p {text-indent:0}",
            flow: style.flow)
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(body.utf8), format: .markdown),
            settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let pdf = result.logicalDocument
        let midpoint = PaperSize.a4.size.height / 2
        var rows = [[Int]](repeating: [], count: colors.count)
        var sizes: [CGSize] = []
        var interior: CGSize?
        for index in 0..<pdf.pageCount {
            let pixels = try PagePixels(try #require(pdf.page(at: index)))
            if index == 0 { interior = pixels.bounds { r, g, b in min(r, b) > g + 80 }?.size }
            for channel in colors.indices {
                let stop = pixels.bounds { r, g, b in
                    switch channel {
                    case 0: r > max(g, b) + 80
                    case 1: g > max(r, b) + 80
                    default: b > max(r, g) + 80
                    }
                }
                if let stop {
                    rows[channel].append(2 * index + (stop.midY > midpoint ? 1 : 0))
                    sizes.append(stop.size)
                }
            }
        }
        #expect(rows == [[0], [1], [2]])
        let reference = try #require(interior)
        #expect(reference.width >= 1 && reference.height >= 1)
        for size in sizes {
            #expect(abs(size.width - reference.width) <= 0.75 && abs(size.height - reference.height) <= 0.75)
        }
    }

    @Test("混植原稿そのものを A4 の全段に組むと別行数式と脚注全文が一度ずつ切片に載る", .timeLimit(.minutes(1)))
    func manuscriptSlices() async throws {
        _ = NSApplication.shared
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let html = HTMLDocumentBuilder.build(
            fragment: MarkdownConverter.convert(mixManuscript), format: .markdown, theme: style,
            finish: manuscriptInkColors)
        let view = WKWebView(frame: CGRect(origin: .zero, size: PaperSize.a4.size))
        let navigation = NavigationTracker()
        view.navigationDelegate = navigation
        view.loadHTMLString(html, baseURL: nil)
        try await WebPaginator.waitUntil(timeout: .seconds(10)) { navigation.state != .loading }
        try #require(navigation.state == .finished)
        // Color just the existing full stop so its printed ink can be tested independently of PDF text selection.
        let colorStop = """
            const text = document.querySelector('section.footnotes li p').lastChild;
            if (text.nodeType !== Node.TEXT_NODE || !text.data.endsWith('。')) return false;
            const range = document.createRange(), span = document.createElement('span');
            range.setStart(text,text.length-1); range.setEnd(text,text.length);
            span.style.color = '#ff0000'; range.surroundContents(span); span.parentNode.normalize();
            return true;
            """
        let marked = try await view.evaluateForPrinting(colorStop, arguments: [:], until: .now + .seconds(10))
        try #require(marked as? Bool == true)
        let document = try await VerticalPaginator.pages(
            in: view, pageSize: PaperSize.a4.size,
            margins: .init(PrintOptions().margins), timeout: .seconds(15))
        let inspect = #"""
            const q = s => document.querySelector(s);
            const formula = q('.math-block > .math-display > svg'), foot = q('section.footnotes li p');
            const table = q('table'), code = q('pre'), base = q('.vertical-note-base'), mark = base.querySelector('a');
            const range = document.createRange();
            const rect = el => el.getBoundingClientRect();
            const contains = (cut,r) => r.width>0 && r.height>0 && r.left>=cut[1]-1 && r.right<=cut[0]+1
                && r.top>=cut[2]-1 && r.bottom<=cut[3]+1;
            const owners = [[],[],[],[]];
            const boxes = [table,code,formula,foot];
            let rows = 0, leading = null;
            for (let cut; (cut=surimonoCaptureSlice(rows)); ++rows) {
                if (!rows) leading = cut[0]-surimonoVerticalX(q('h1'));
                boxes.forEach((el,i) => {
                    if (getComputedStyle(el).visibility !== 'visible' || !contains(cut,rect(el))) return;
                    if (el===formula && !contains(cut,rect(formula.closest('.math-block')))) return;
                    if (el===foot) {
                        if (!contains(cut,rect(foot.closest('section.footnotes')))) return;
                        range.selectNodeContents(foot);
                        if (![...range.getClientRects()].every(r=>contains(cut,r))) return;
                    }
                    owners[i].push(rows);
                });
            }
            range.selectNodeContents(base.firstChild);
            const glyph=range.getBoundingClientRect(), note=rect(mark);
            const width=parseFloat(getComputedStyle(q('.surimono-vertical')).getPropertyValue('--content-width'));
            return {rows, owners, note:foot.textContent, formula:formula.getAttribute('aria-label'), leading,
                horizontalNotes:getComputedStyle(foot).writingMode==='horizontal-tb'
                    && !foot.closest('section.footnotes').querySelector('.aki,.v-half,.v-close,.v-before-open'),
                remaining:width-(surimonoVerticalX(q('h1'))-rect(code).right), codeWidth:rect(code).width,
                base:base.firstChild.textContent, after:base.nextSibling.textContent, gap:note.left-glyph.right,
                top:note.top-glyph.top, em:parseFloat(getComputedStyle(base).fontSize)};
            """#
        let info = try #require(
            try await view.evaluateForPrinting(inspect, until: .now + .seconds(10)) as? [String: Any])
        let metrics = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        Attachment.record(String(decoding: metrics, as: UTF8.self), named: "vertical-manuscript.json")
        let owners = try #require(info["owners"] as? [[Int]])
        try #require(owners.count == 4 && owners.allSatisfy { $0.count == 1 })
        let rows = try #require(info["rows"] as? Int)
        #expect(document.pageCount == (rows + 1) / 2)
        let ink = try inkPages(in: document)
        #expect(ink.equations == [owners[2][0] / 2])
        #expect(ink.notes == [owners[3][0] / 2])
        #expect(ink.noteText.filter { !$0.isWhitespace }.contains("脚注は文書の終わりに置く。"))
        let pixels = try PagePixels(try #require(document.page(at: owners[3][0] / 2)))
        let stop = try #require(pixels.bounds { r, g, b in r > max(g, b) + 100 })
        #expect(stop.width >= 1 && stop.height >= 1 && stop.width < 6 && stop.height < 6)
        #expect(owners[2][0] >= owners[1][0] && owners[3][0] >= owners[2][0])
        #expect(info["note"] as? String == "脚注は文書の終わりに置く。")
        #expect(info["horizontalNotes"] as? Bool == true)
        #expect(info["formula"] as? String == #"\int_0^1 x^2\,dx=\frac13"#)
        let remaining = try #require(info["remaining"] as? Double)
        let codeWidth = try #require(info["codeWidth"] as? Double)
        #expect((owners[1] == owners[0]) == (codeWidth <= remaining))
        #expect(abs(try #require(info["leading"] as? Double)) <= 2)
        let em = try #require(info["em"] as? Double)
        #expect(info["base"] as? String == "注" && (info["after"] as? String)?.hasPrefix("。") == true)
        #expect(abs(try #require(info["gap"] as? Double)) < 0.2 * em)
        #expect(abs(try #require(info["top"] as? Double)) < 0.25 * em)
    }
}

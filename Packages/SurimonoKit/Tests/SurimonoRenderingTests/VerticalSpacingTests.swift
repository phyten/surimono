import AppKit
import CoreText
import SurimonoCore
import Testing
import WebKit

@testable import SurimonoRendering

@MainActor
struct VerticalSpacingTests {
    @Test("実際の和文の字送り・禁則・行端の四分アキ・約物半角・欧文と見出しの書体を測る", .timeLimit(.minutes(1)))
    func advances() async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        // A fractional measure forces justification even with perfectly square Japanese glyphs.
        let strictParagraphs = ["、", "。", "」", "ぁ", "ー"].enumerated().map { index, forbidden in
            #"<p class="strict" id="strict\#(index)" style="inline-size:5em;text-indent:0">本本本本本\#(forbidden)本文</p>"#
        }.joined()
        let grids = [PaperSize.a4, .a5].map { paper in
            let frame = VerticalPaginator.Frame(
                pageSize: paper.size, margins: .init(top: 36, left: 36, bottom: 36, right: 36), textScale: 1)
            return """
                <div class="surimono-vertical grid" data-paper="\(paper == .a4 ? "A4" : "A5")"
                  style="--body-size:\(frame.font)pt;--content-height:\(frame.height)pt">本文</div>
                """
        }.joined()
        let fragment = """
            <div class="surimono-vertical" lang="ja" style="--body-size:20px; --content-height:20em">
            <p id="justify" style="inline-size:5.5em">本本本本本本本本本本本本本</p>
            <p id="gap">本PDF本</p><p id="written">本 PDF 本</p>
            <p id="edge" style="inline-size:4em">本本本本PDF</p><p id="edgeBack">PDF本</p><p id="origin">PDF</p>
            <p id="close">本）。本</p><p id="pair">本、（本</p><p id="inside">本「本</p>
            <p id="punctJust" style="inline-size:5.25em;text-indent:0">本）。本本本本本本本</p>
            <p id="wrap" style="inline-size:4em">本本本本「本</p><p id="initial">「本</p>
            <p id="address" style="inline-size:4.5em;text-align:start;text-indent:0">https://example.org/path-name?q=ab&amp;x=7#end</p>
            <p id="longAddress" style="inline-size:4.5em;text-align:start;text-indent:0">https://example.org/aaaaaaaaaaaaaaaaaaaaaaaa</p>
            <p id="notes"><sup class="footnote-ref"><a>1</a></sup><sup class="footnote-ref"><a>12</a></sup></p>
            \(strictParagraphs)
            <p id="strictOpen" class="strict" style="inline-size:5em;text-indent:0">本本本本「本文</p>
            <p id="font">本ABC本<strong>太字</strong><code>some.very.long.identifier</code></p><h1>章</h1><h2>節</h2><h3>小節</h3>
            </div>\(grids)
            """
        let html = HTMLDocumentBuilder.build(
            fragment: HTMLFragment(body: fragment), format: .markdown, theme: theme,
            finish: "#gap,#written,#edge,#edgeBack,#origin,#close,#pair,#inside,#wrap,#font {text-indent:0}")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 550))
        let navigation = NavigationTracker()
        view.navigationDelegate = navigation
        view.loadHTMLString(html, baseURL: nil)
        try await WebPaginator.waitUntil(timeout: .seconds(10)) { navigation.state != .loading }
        try #require(navigation.state == .finished)
        let script = """
            const el = id => document.getElementById(id);
            const em = parseFloat(getComputedStyle(el('gap')).fontSize);
            const glyphs = id => {
                const root = el(id), range = document.createRange();
                const top = root.getBoundingClientRect().top;
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                const result = [];
                for (let text = walker.nextNode(); text; text = walker.nextNode()) {
                    for (let i = 0; i < text.length; ++i) {
                        range.setStart(text, i);
                        range.setEnd(text, i + 1);
                        const r = range.getBoundingClientRect();
                        result.push({ch:text.data[i], x:r.left, y:(r.top-top)/em});
                    }
                }
                return result;
            };
            const lines = id => {
                const rows = [];
                for (const g of glyphs(id)) {
                    if (!rows.length || Math.abs(rows.at(-1)[0].x - g.x) > em/2) rows.push([]);
                    rows.at(-1).push(g);
                }
                return rows;
            };
            const wordTop = id => (el(id).querySelector('.v-latin').getBoundingClientRect().top
                - el(id).getBoundingClientRect().top) / em;
            function gaps(id) {
                const before = wordTop(id), after = glyphs(id).at(-1).y;
                for (const gap of el(id).querySelectorAll('.aki')) gap.style.display = 'none';
                const first = before - wordTop(id);
                return [first, after - glyphs(id).at(-1).y - first];
            }
            const selection = window.getSelection();
            selection.selectAllChildren(el('gap'));
            const selected = selection.toString();
            const copiedMarks = ['close','pair','inside','wrap','initial'].map(id => {
                selection.selectAllChildren(el(id));
                return selection.toString();
            });
            selection.removeAllRanges();
            const rows = lines('justify');
            const strict = [...document.querySelectorAll('.strict')].flatMap(p => lines(p.id));
            const origin = glyphs('justify')[0].y;
            const westernHeight = el('origin').querySelector('.v-latin').getBoundingClientRect().height;
            el('edgeBack').style.inlineSize = (westernHeight + 0.5) + 'px';
            const usedSpace = id => [...el(id).querySelector('.aki').getClientRects()]
                .reduce((height,r) => height + r.height/em, 0);
            el('justify').style.textJustify = 'auto';
            const autoRows = lines('justify');
            el('justify').style.removeProperty('text-justify');
            const advance = id => glyphs(id).at(-1).y - glyphs(id)[0].y;
            const css = selector => getComputedStyle(document.querySelector(selector));
            const defaultLatin = css('#font .v-latin').fontFamily === css('#font').fontFamily;
            el('font').style.setProperty('--vertical-latin-font', '"Times New Roman"');
            const addressLines = lines('address').map(row => row.map(g => g.ch).join(''));
            selection.selectAllChildren(el('address'));
            const copiedAddress = selection.toString();
            selection.removeAllRanges();
            const noteCells = [...el('notes').querySelectorAll('a')].map(a => {
                const mark = a.querySelector('.tcy');
                return mark && (getComputedStyle(mark).textCombineUpright === 'all'
                    || getComputedStyle(mark).getPropertyValue('-webkit-text-combine') === 'horizontal')
                    ? a.getBoundingClientRect().height / parseFloat(getComputedStyle(a).fontSize) : 0;
            });
            return {
                paperGrids: [...document.querySelectorAll('.grid')].map(el => ({paper:el.dataset.paper,
                    fontSizePt:parseFloat(getComputedStyle(el).fontSize)*72/96, lineLengthPt:el.getBoundingClientRect().height*72/96})),
                addressLines, copiedAddress, noteCells, emergencyLines: lines('longAddress').map(row => row.map(g => g.ch).join('')),
                headingSpaces: ['h1','h2','h3'].flatMap(h => [parseFloat(css(h).paddingRight)/em, parseFloat(css(h).paddingLeft)/em]),
                inlineCode: css('#font code').backgroundColor,
                bodyFont: css('#gap').fontFamily, spaceFont: css('#gap .aki').fontFamily, fontSizeCSSPx: em, lineLengthCSSPx: el('justify').getBoundingClientRect().height,
                fontFeatures: css('#gap').fontFeatureSettings, kerning: css('#gap').fontKerning,
                justified: rows.slice(0,-1).map(row => row.at(-1).y - origin + 1),
                steps: rows[0].slice(1).map((g,i) => g.y-rows[0][i].y),
                last: rows.at(-1).map(g => g.y-origin),
                strict: strict.map(row => row.map(g=>g.ch).join('')),
                overflow: Math.max(...strict.flatMap(row => row.map(g => g.y-origin+1-5))),
                autoJustified: autoRows.slice(0,-1).map(row => row.at(-1).y - origin + 1),
                autoSteps: autoRows[0].slice(1).map((g,i) => g.y-autoRows[0][i].y),
                interCharacter: CSS.supports('text-justify','inter-character'),
                implicit: gaps('gap'), written: gaps('written'),
                edge: [lines('edge')[0].length, wordTop('edge') - wordTop('origin'),
                    glyphs('edgeBack').at(-1).y - origin, usedSpace('edge'), usedSpace('edgeBack')],
                punctJust: lines('punctJust').slice(0,-1).map(row => row.at(-1).y - origin + 1),
                copiedMarks, punctuation: [advance('close'), advance('pair'), advance('inside'),
                    glyphs('wrap').at(-1).y-origin, glyphs('initial').at(-1).y-origin],
                source: selected === '本PDF本' && el('gap').textContent === '本PDF本' && el('written').textContent === '本 PDF 本',
                fonts: defaultLatin && css('#font .v-latin').fontFamily.includes('Times New Roman')
                    && css('#font code .long-token').fontFamily === css('#font code').fontFamily
                    && !css('#font').fontFamily.includes('Times New Roman') && css('strong').fontFamily.includes('Hiragino Sans')
                    && ['h1','h2','h3'].every(h => css(h).fontFamily === css('#font').fontFamily
                        && Number(css(h).fontWeight) >= 600),
                headings: ['h1','h2','h3'].map(h => parseFloat(css(h).fontSize)/em)
            };
            """
        var result = try #require(
            try await view.evaluateForPrinting(script, arguments: [:], until: .now + .seconds(10)) as? [String: Any])
        let pointSize = try #require(result["fontSizeCSSPx"] as? Double) * 72 / 96
        for (fontKey, prefix, sample) in [("bodyFont", "font", "本"), ("spaceFont", "spaceFont", " ")] {
            let family = try #require((result[fontKey] as? String)?.components(separatedBy: ",").first)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            let face = CTFontCreateForString(
                CTFontCreateWithName(family as CFString, pointSize, nil), sample as CFString,
                CFRange(location: 0, length: 1))
            result[prefix + "PostScript"] = CTFontCopyPostScriptName(face) as String
            result[prefix + "Version"] = try #require(CTFontCopyName(face, kCTFontVersionNameKey) as String?)
        }
        let webKit = Bundle(for: WKWebView.self)
        result["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        result["webKitBuild"] = try #require(webKit.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        result["fontSizePt"] = pointSize
        let metrics = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        Attachment.record(String(decoding: metrics, as: UTF8.self), named: "vertical-spacing.json")
        func check(_ key: String, _ expected: [Double], tolerance: Double = 0.06) throws {
            let values = try #require(result[key] as? [Double])
            #expect(values.count == expected.count, "\(key) \(values)")
            for (actual, wanted) in zip(values, expected) {
                #expect(abs(actual - wanted) < tolerance, "\(key) 実測 \(values) em、期待 \(expected) em")
            }
        }
        let paperGrids = try #require(result["paperGrids"] as? [[String: Any]])
        #expect(paperGrids.compactMap { $0["paper"] as? String } == ["A4", "A5"])
        for (grid, length) in zip(paperGrids, [315.0, 441.0]) {
            #expect(abs((grid["fontSizePt"] as? Double ?? 0) - 10.5) < 0.05)
            #expect(abs((grid["lineLengthPt"] as? Double ?? 0) - length) < 0.05)
        }
        #expect(result["kerning"] as? String == "none")
        let features = try #require(result["fontFeatures"] as? String)
        let disabled = features.components(separatedBy: ",").filter { $0.hasSuffix(" 0") || $0.hasSuffix(" off") }
        for tag in ["halt", "vhal", "chws", "vchw", "palt", "vpal"] {
            #expect(disabled.contains { $0.contains(tag) }, "\(features)")
        }
        let supports = result["interCharacter"] as? Bool == true
        let full = try #require(result["justified"] as? [Double])
        #expect(
            full.count == 2 && full.allSatisfy { abs($0 - 5.5) < 0.06 }, "行長 \(full) em、inter-character \(supports)")
        try check("steps", Array(repeating: 1.125, count: 4))
        try check("last", [0, 1, 2])
        let strict = try #require(result["strict"] as? [String])
        #expect(strict.count == 12)
        let overflow = try #require(result["overflow"] as? Double)
        #expect(overflow < 0.06, "行末のはみ出し \(overflow) em")
        for row in strict {
            #expect(row.first.map { !"、ぁー」。".contains($0) } == true && row.last != "「", "禁則の行分け \(strict)")
        }
        try check("implicit", [0.25, 0.25])
        try check("written", [0.25, 0.25])
        try check("edge", [4, 0, 0, 0, 0])
        try check("punctJust", [5.25])
        #expect(result["copiedMarks"] as? [String] == ["本）。本", "本、（本", "本「本", "本本本本「本", "「本"])
        try check("punctuation", [2.5, 2.5, 2, 0.5, 1.5])
        try check("headings", [1.4, 1.2, 1.05], tolerance: 0.01)
        try check("headingSpaces", [3.5, 1.75, 2.625, 0.875, 1.75, 0])
        try check("noteCells", [1, 1], tolerance: 0.15)
        #expect(result["inlineCode"] as? String == "rgb(243, 243, 243)")
        let address = try #require(result["addressLines"] as? [String])
        let literal = "https://example.org/path-name?q=ab&x=7#end"
        #expect(address.joined() == literal && result["copiedAddress"] as? String == literal)
        #expect(
            address.count > 1
                && address.dropLast().allSatisfy { row in row.last.map { "/.-_?&=#".contains($0) } == true },
            "URL の折返し \(address)")
        let emergency = try #require(result["emergencyLines"] as? [String])
        #expect(emergency.dropLast().contains { $0.hasSuffix("aaa") }, "長い URL の折返し \(emergency)")
        #expect(result["source"] as? Bool == true)
        #expect(result["fonts"] as? Bool == true)
    }
}

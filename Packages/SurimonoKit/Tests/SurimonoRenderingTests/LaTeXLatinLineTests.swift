import JavaScriptCore
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXLatinLineTests {
    private func context() throws -> JSContext {
        let js = try #require(JSContext())
        js.evaluateScript(try LaTeXFlowPaginator.latinLineScript())
        js.evaluateScript(
            """
            const points = latinHyphenator(surimonoEnglishPatterns);
            function dashed(word, lookup = points) {
                const offsets = lookup(word);
                return [...word].map((c,i) => (offsets.includes(i) ? '-' : '') + c).join('');
            }
            function sample(source, width, options = {}, indent = 0) {
                const words = source.split(' ').map(text => ({
                    text, width:text.length, glue:[1,.5,1/3],
                    breaks:auto => auto ? points(text).map(offset => ({offset,hyphen:true})) : [],
                    fragment:(a,b,hyphen) => b-a+Number(hyphen)
                }));
                return latinBreakPlan(words, width, indent, options);
            }
            """)
        try #require(js.exception == nil)
        return js
    }

    @Test("英語六十語の分綴位置が実際の plain TeX の出力に一致する")
    func hyphenation() throws {
        let js = try context()
        // Obtained with plain TeX 2026, one showhyphens per word, left/right minima 2/3.
        let reference = """
            hy-phen-ation al-go-rithm manuscript ta-ble presents mea-sure-ment as-so-ciate as-so-ciates
            dec-li-na-tion oblig-a-tory phil-an-thropic present project projects reci-procity re-cog-ni-zance
            ref-or-ma-tion ret-ri-bu-tion ty-pog-ra-phy para-graph com-po-si-tion jus-ti-fied uni-form ex-cep-tion
            dis-cre-tionary bib-li-og-ra-phy bib-li-o-graph-i-cal com-pu-ta-tional pro-ceed-ings dic-tio-nary
            stretch-ing tol-er-ance prepa-ra-tion con-se-quences align-ment math-e-mat-ics math-e-mat-i-cal
            com-par-i-son con-fer-ence ex-per-i-ments ob-jec-tive min-i-mum in-te-ger fit-ness nat-u-ral
            fea-si-ble pro-gram-ming hy-poth-e-sis ref-er-ence avail-able co-her-ence penal-ties di-a-gram
            anal-y-sis char-ac-ter lan-guage pro-ce-dure es-ti-mate in-ter-pre-ta-tion au-to-matic
            """.split(whereSeparator: \.isWhitespace).map(String.init)
        #expect(reference.count == 60)
        let words = reference.map { $0.replacingOccurrences(of: "-", with: "") }
        js.setObject(words, forKeyedSubscript: "words" as NSString)
        #expect(js.evaluateScript("words.map(word => dashed(word))")?.toArray() as? [String] == reference)
    }

    @Test("文書の例外で同梱例外を置き換え、別文書と混ざらない")
    func documentExceptions() throws {
        let js = try context()
        let actual =
            js.evaluateScript(
                """
                (() => {
                    const lookup = latinHyphenator(surimonoEnglishPatterns, 'ta-ble pro-ject associate');
                    return [dashed('PROJECT', lookup), dashed('associate', lookup), dashed('project')];
                })()
                """)?.toArray() as? [String]
        #expect(actual == ["PRO-JECT", "associate", "project"])
    }

    @Test("通常、分綴あり、緊急の順に成功した回だけを使い、不可能な段落は任せる")
    func passes() throws {
        let js = try context()
        #expect(js.evaluateScript("sample('aa bb cc dd',5).pass")?.toInt32() == 1)
        #expect(js.evaluateScript("sample('zero algorithm',8).pass")?.toInt32() == 2)
        #expect(js.evaluateScript("sample('zero algorithm',8).lines[0].hyphen")?.toBool() == true)
        #expect(js.evaluateScript("sample('aa bb ccccc',8,{emergencystretch:3}).pass")?.toInt32() == 3)
        #expect(js.evaluateScript("sample('aa bb ccccc',8,{emergencystretch:3}).lines[0].ratio")?.toDouble() == 6)
        #expect(js.evaluateScript("sample('longest word',5)")?.isNull == true)
        #expect(js.evaluateScript("sample('algorithm',4)")?.isNull == true)
        #expect(js.evaluateScript("sample('aa bb cc dd',5,{},2)")?.isNull == true)
    }

    @Test("実 TeX の語幅とグルーで学会原稿の分綴と全行末を再現する", arguments: ["115", "121", "123"])
    func conferenceBreaks(corpus: String) throws {
        let js = try context()
        // pdfLaTeX with each corpus kit: widths are \wd of shaped word/fragment hboxes
        // (including inline math and the thin kern). Glue triples are \the\lastskip after
        // a word and space. All are TeX points. The expected ends come from the reference PDF.
        let url = try #require(
            Bundle.module.url(
                forResource: "latin-paragraph-" + corpus, withExtension: "json",
                subdirectory: "Fixtures"))
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        js.setObject(fixture, forKeyedSubscript: "fixture" as NSString)
        let result =
            js.evaluateScript(
                #"""
                (() => {
                    const {words,widths,glue,glueAfter,noBreakAfter,measure} = fixture;
                    const items = words.split(' ').map((text,i) => ({
                        text, width:widths[text], glue:glue[glueAfter[i]], noBreakAfter:noBreakAfter.includes(i),
                        fragment:(a,b,hyphen) => widths[text.slice(a,b) + (hyphen ? '-' : '')],
                        breaks:auto => {
                            const breaks = [...text.matchAll(/-/g)].map(m => ({offset:m.index+1, hyphen:false}));
                            const letters = /^([a-z]+)[.,)]*$/i.exec(text);
                            if (auto && letters) breaks.push(...points(letters[1]).map(offset => ({offset,hyphen:true})));
                            return breaks;
                        }
                    }));
                    const plan = latinBreakPlan(items, measure, 0, {tolerance:9999, emergencystretch:30});
                    return [String(plan.pass), ...plan.lines.map(line =>
                        items[line.endWord].text.slice(0,line.endOffset) + (line.hyphen ? '-' : ''))];
                })()
                """#)?.toArray() as? [String]
        let expected = [
            "115": ["2", "thick-", "stock.", "fol-", "choice", "is", "more", "Frame", "spacers", "once."],
            "121": ["2", "each", "two-layer", "c=h₂−2t.", "of", "the", "layers."],
            "123": ["2", "The", "Equa-", "the", "predicted", "layers."],
        ]
        #expect(result == expected[corpus])
    }

    @Test("実 TeX のリスト・脚注・参考文献・図説明の箱と糊で行末と伸縮率を再現する", arguments: ["list", "footnote", "bibliography", "caption"])
    func contextBoxes(category: String) throws {
        // The reference PDFs were made with pdfLaTeX. The page box dump gives
        // the line measure, initial label box, interword glue and penalties.
        // Each word width sums its actual fontcharwd values and kern nodes,
        // including ligatures and the change of face before punctuation.
        let url = try #require(
            Bundle.module.url(forResource: "latin-context-boxes", withExtension: "json", subdirectory: "Fixtures"))
        let records = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let fixture = try #require(records.first { $0["category"] as? String == category })
        let js = try context()
        js.setObject(fixture, forKeyedSubscript: "fixture" as NSString)
        let result = js.evaluateScript(
            """
            const items = fixture.boxes.map(([text,width,glue,penalty]) => {
                const cuts = fixture.discretionaries[text] || [];
                return {text,width,glue:fixture.glue[glue],noBreakAfter:penalty===10000,
                    breaks:() => cuts.map(([offset]) => ({offset,hyphen:false})),
                    fragment:(from,to) => from === 0 && to === text.length ? width :
                        from === 0 ? cuts.find(([offset]) => offset===to)[1] : cuts.find(([offset]) => offset===from)[2]};
            });
            latinBreakPlan(items,fixture.measure,fixture.indent,{tolerance:9999}).lines.map(line =>
                [items[line.endWord].text.slice(0,line.endOffset),line.ratio]);
            """)
        let lines = try #require(result?.toArray() as? [[Any]])
        #expect(lines.compactMap { $0.first as? String } == fixture["ends"] as? [String])
        let firstRatio = try #require(lines.first?.last as? Double)
        let expected = try #require(
            ["list": 0.07689, "footnote": 0.03535, "bibliography": 0.12616, "caption": 0.03755][category])
        #expect(abs(firstRatio - expected) < 0.0001)
    }

    @Test(
        "参考文献の実 TeX の箱・ブロック間の糊・分綴候補から各パスと全行末を再現する",
        arguments: ["plain-unsrt", "abbrv", "alpha-collection", "alpha-report", "cvpr-first", "cvpr-last"])
    func bibliographyBoxes(name: String) throws {
        // Word and fragment widths are pdfTeX hboxes in the corpus font. Glue
        // includes both adjacent nodes at a newblock. The page box and paragraph
        // traces supply the expected glue sets, pass and line ends (including backrefs).
        let url = try #require(
            Bundle.module.url(forResource: "latin-bibliography-boxes", withExtension: "json", subdirectory: "Fixtures"))
        let records = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]])
        let entry = try #require(records[name])
        let js = try context()
        js.setObject(entry, forKeyedSubscript: "entry" as NSString)
        let result = js.evaluateScript(
            #"""
            const words = entry.items.map(([text,width,g,fragments],i) => ({
                text,width,glue:entry.glue[g],noBreakAfter:entry.ties.includes(i),
                breaks:auto => {
                    const breaks = [...text.matchAll(/–/g)].map(m => ({offset:m.index+1,hyphen:false}));
                    if (auto) for (const offset of points(text.replace(/[.,]+$/,''))) breaks.push({offset,hyphen:true});
                    return breaks;
                },
                fragment:(a,b) => a===0 && b===text.length ? width : fragments[[a,b]]
            }));
            const plan = latinBreakPlan(words,entry.measure,0,{tolerance:9999,emergencystretch:30});
            [plan.pass,plan.lines.map(l => words[l.endWord].text.slice(0,l.endOffset)+(l.hyphen?'-':'')),
                plan.lines.map(l => l.ratio)];
            """#)
        let values = try #require(result?.toArray())
        #expect(values[0] as? Int == entry["passNumber"] as? Int)
        #expect(values[1] as? [String] == entry["ends"] as? [String])
        let ratios = try #require(values[2] as? [Double])
        for (actual, expected) in zip(ratios, try #require(entry["ratios"] as? [Double])) {
            #expect(abs(actual - expected) < 0.001)
        }
    }

    @Test("同じ適合度で減点が同じなら、実 TeX が残す後の分綴点を選ぶ")
    func equalDemerits() throws {
        let js = try context()
        // In a 10pt TeX hbox trace both discretionaries have b=2, d=2644.
        // At the forced break both cost 7744; TeX prints the first line at -0.25.
        let ratio = js.evaluateScript(
            """
            const items = [
                {text:'x',width:5,glue:[2,2,2],breaks:()=>[],fragment:()=>5},
                {text:'abc',width:7,glue:[2,2,2],breaks:()=>[1,2].map(offset=>({offset,hyphen:false})),
                    fragment:(a,b)=>[0,2.5,3.5,7][b]-[0,2.5,3.5,7][a]},
                {text:'z',width:3.5,glue:[0,0,0],breaks:()=>[],fragment:()=>3.5}
            ];
            latinBreakPlan(items,10,0).lines[0].ratio;
            """)?.toDouble()
        #expect(ratio == -0.25)
    }

    @Test("八・九ポイントの脚注と小組の CM は字形別の設計糊を選ぶ")
    func smallDesignSizes() throws {
        let js = try context()
        let actual =
            js.evaluateScript(
                """
                [8,9].flatMap(size => ['normal','italic','bold','bold-italic'].map(shape =>
                    latinGlue('cm',shape.includes('italic')?'italic':'normal',shape.includes('bold')?700:400,
                        1,0,'word',false,size)));
                """)?.toArray() as? [[Double]]
        #expect(
            actual == [
                [0.354172, 0.177086, 0.118057], [0.384029, 0.164583, 0.109722], [0.408337, 0.204168, 0.136112],
                [0.414441, 0.176664, 0.117777], [0.34259, 0.171295, 0.114197], [0.36729, 0.15741, 0.104939],
                [0.39444, 0.19722, 0.13148], [0.414441, 0.176664, 0.117777],
            ])
    }

    @Test("書誌ではピリオドだけ通常空きになり、別の Times 書体の伸縮量も保つ")
    func bibliographyPeriod() throws {
        let js = try context()
        let actual =
            js.evaluateScript(
                """
                ['item.','what?','some,'].map(word => latinGlue('newtx','italic',400,10,0,word,false,10,1000));
                """)?.toArray() as? [[Double]]
        let expected = [[2.5, 2.0, 1.0], [3.61, 6.0, 1.0 / 3.0], [2.5, 2.5, 0.8]]
        let lines = try #require(actual)
        #expect(lines.count == expected.count)
        for (line, values) in zip(lines, expected) {
            #expect(zip(line, values).allSatisfy { abs($0 - $1) < 0.000001 })
        }
    }

    @Test("タイの空きは伸ばせるが、タイの位置を行末には選べない")
    func tiedGlue() throws {
        let js = try context()
        let result =
            js.evaluateScript(
                """
                (() => {
                    const items = ['aa','bb','cc','dd'].map(text => ({
                        text, width:2, glue:[1,1,.5], breaks:() => [], fragment:() => 2
                    }));
                    items[0].noBreakAfter = true;
                    const fits = latinBreakPlan(items,6,0);
                    items[1].noBreakAfter = true;
                    return [fits.lines[0].endWord, fits.lines[0].ratio, latinBreakPlan(items,6,0) === null ? 1 : 0];
                })()
                """)?.toArray() as? [Int]
        #expect(result == [1, 1, 1])
    }

    @Test("縮みの限界を超えた行は最終行も緊急時も採用しない")
    func minimumGlue() throws {
        let js = try context()
        #expect(js.evaluateScript("sample('aa bb',4.66,{emergencystretch:1000})")?.isNull == true)
        let ratio = try #require(js.evaluateScript("sample('aa bb',4.7).lines[0].ratio")?.toDouble())
        #expect(abs(ratio + 0.9) < 0.000001)
        #expect(
            js.evaluateScript(
                """
                Array.from({length:90}, (_,i) => sample('aa bb cc dd ee ff gg hh', 2 + i/10,
                    {tolerance:9999,emergencystretch:100})).every(plan => !plan || plan.lines.every(l => l.ratio >= -1))
                """)?.toBool() == true)
    }

    @Test("整数近似の悪さ、適合度の飛び、連続分綴と最終分綴を TeX の減点に含める")
    func demerits() throws {
        let js = try context()
        let result =
            js.evaluateScript(
                """
                (() => {
                    const previous = {cost:7,fitness:1,discretionary:true};
                    return [latinBadness(1,1), latinBadness(.5,1), latinBadness(100,1),
                        latinDemerits(previous,3,100,50,true,false,latinDefaults),
                        latinDemerits(previous,1,0,-10000,false,true,latinDefaults),
                        latinDemerits(previous,1,20,-10,false,false,latinDefaults)];
                })()
                """)?.toArray() as? [Int]
        #expect(result == [100, 12, 10000, 34607, 5107, 807])
    }

    @Test("十二ポイントの標準本文では同じ文字サイズでも十二ポイント設計の CM のグルーを使う")
    func standardTwelvePointGlue() throws {
        let js = try context()
        let result =
            js.evaluateScript(
                """
                ['normal', 'italic', 'bold', 'bold-italic'].map(shape =>
                    latinGlue('cm', shape.includes('italic') ? 'italic' : 'normal',
                        shape.includes('bold') ? 700 : 400, 1, 0, 'word', false, 12))
                """)?.toArray() as? [[Double]]
        #expect(
            result == [
                [0.3263855, 0.163193, 0.108795], [0.350003, 0.150002, 0.100001],
                [0.375, 0.1875, 0.125], [0.414441, 0.176664, 0.117777],
            ])
    }

    @Test("文末空きと大文字の略号とフランス式空きがフォントの伸縮量に反映される")
    func sentenceGlue() throws {
        let js = try context()
        let result =
            js.evaluateScript(
                """
                ['period.', 'A.', 'Why?', 'stop:', 'some;', 'other,', 'end.”'].map(word =>
                    latinGlue('Times New Roman','normal',400,10,2.5,word,false))
                    .concat([latinGlue('Times New Roman','normal',400,10,2.5,'period.',true)])
                """)?.toArray() as? [[Double]]
        let actual = try #require(result)
        let expected = [
            [3.099985, 4.5, 0.199995], [2.5, 1.5, 0.599985], [3.099985, 4.5, 0.199995],
            [3.099985, 3.0, 0.2999925], [2.5, 2.25, 0.39999], [2.5, 1.875, 0.479988],
            [3.099985, 4.5, 0.199995], [2.5, 1.5, 0.599985],
        ]
        #expect(actual.count == expected.count)
        for (line, values) in zip(actual, expected) {
            #expect(line.count == values.count)
            #expect(zip(line, values).allSatisfy { abs($0 - $1) < 0.000001 })
        }
    }
}

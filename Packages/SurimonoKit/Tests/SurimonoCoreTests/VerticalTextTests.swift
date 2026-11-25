import Testing

@testable import SurimonoCore

struct VerticalTextTests {
    private let aki = #"<span class="aki"></span>"#
    private func latin(_ text: String) -> String { #"<span class="v-latin">\#(text)</span>"# }
    private func url(_ marked: String) -> String { #"<span class="v-latin v-url">\#(marked)</span>"# }
    private func close(_ text: String) -> String { #"<span class="v-close">\#(text)</span>"# }

    @Test("和欧の境にだけ四分アキを置き、原稿の空白と URL・縦中横を保つ")
    func boundarySpacing() throws {
        let spaced = #"<span class="aki"> </span>"#
        #expect(try VerticalText.marked("重さは10kg、") == "重さは" + aki + latin("10kg") + "、")
        #expect(
            try VerticalText.marked("macOS の PDF で") == latin("macOS") + spaced + "の" + spaced + latin("PDF") + spaced
                + "で")
        #expect(try VerticalText.marked("日 本") == "日 本")
        #expect(try VerticalText.marked("本当か!?　macOS") == #"本当か<span class="tcy">!?</span>　"# + latin("macOS"))
        #expect(
            try VerticalText.marked("本https://example.org/12を見る") == "本" + aki
                + url("https:/<wbr>/<wbr>example.<wbr>org/<wbr>12") + aki
                + "を見る")
        #expect(try VerticalText.marked("型<code>x12</code>式") == "型" + aki + "<code>x12</code>" + aki + "式")
        let link = #"<a href="https://example.jp/%E6%97%A5/25">"#
        #expect(
            try VerticalText.marked("本" + link + "https://example.jp/日/25</a>文")
                == "本" + link + aki + url("https:/<wbr>/<wbr>example.<wbr>jp/<wbr>日/<wbr>25") + "</a>" + aki + "文")
        let formula = #"<span class="math math-inline"><svg><text>12</text></svg></span>"#
        #expect(try VerticalText.marked("式" + formula + "値") == "式" + aki + formula + aki + "値")
        #expect(try VerticalText.marked("和<em>PDF</em>文").contains(aki + "文"))
    }

    @Test("連続約物の内側を半角にし、段落頭・折返し候補の開き括弧を区別する")
    func punctuation() throws {
        let initial = #"<span class="v-half v-initial">"#
        let start = #"<span class="v-before-open"></span><span class="v-half">"#
        #expect(try VerticalText.marked("<p>（注）。</p>") == "<p>" + initial + "（</span>注" + close("）") + "。</p>")
        #expect(
            try VerticalText.marked("本文「」「」") == "本文" + start + "「</span>」"
                + #"<span class="v-pair-space" data-pair="」「"></span><span class="v-half">「</span>"# + "」")
        #expect(
            try VerticalText.marked("本。<em>」</em>、（注）") == "本" + close("。") + "<em>" + close("」") + "</em>、"
                + #"<span class="v-pair-space" data-pair="、（"></span><span class="v-half">（</span>"#
                + "注）")
    }

    @Test("テキストの改行と段落中のソフト改行を区別し、見本用に再処理しても空きは一重になる")
    func lineStarts() throws {
        let plain = try VerticalText.marked("<pre class=\"surimono-plain\">和\n「本</pre>")
        #expect(plain.contains(#"<span class="v-half v-initial">「</span>"#))
        let soft = try VerticalText.marked("<p>和\n「英」PDF と本</p>")
        #expect(soft.contains(#"<span class="v-before-open"></span><span class="v-half">「</span>"#))
        #expect(try VerticalText.marked(soft) == soft)
    }

    @Test("独立した数字と二連の約物だけを縦組み用に包む")
    func numericExpressions() throws {
        let source = "5日 25日 2026年 1,234円 3.14 10kg 50% macOS PDF A4 ２０２６年 二十五 !! !? ?! ?? ???"
        let single = "<span class=\"upright-digit\">5</span>"
        let pair = "<span class=\"tcy\">25</span>"
        let space = #"<span class="aki"> </span>"#
        let percent = latin("50%")
        let marks = ["!!", "!?", "?!", "??"].map { "<span class=\"tcy\">\($0)</span>" }.joined(separator: " ")
        let expected =
            "\(single)日 \(pair)日\(space)\(latin("2026"))\(aki)年\(space)\(latin("1,234"))\(aki)円"
            + "\(space)\(latin("3.14")) \(latin("10kg")) \(percent) \(latin("macOS")) \(latin("PDF")) \(latin("A4"))"
            + "\(space)２０２６年 二十五 \(marks) ???"
        let actual = try VerticalText.marked(source)
        #expect(actual == expected)
    }

    @Test("単位・割合と隣接記号の数字は横倒し、独立した日付だけ縦中横にする")
    func units() throws {
        for quantity in ["10kg", "50%", "12.5%", "24px"] {
            #expect(try VerticalText.marked(quantity) == latin(quantity))
        }
        for quantity in [".12", "12.", ",12", "12,", "%12", "12<em>kg</em>", "A<strong>12</strong>"] {
            #expect(try !VerticalText.marked(quantity).contains("tcy"))
        }
        for date in ["25日", "12段落", "11月"] { #expect(try VerticalText.marked(date).contains("tcy")) }
        for (digits, style) in [("1", "upright-digit"), ("12", "tcy"), ("123", "v-latin")] {
            let mark = ##"<sup class="footnote-ref"><a href="#fn">"##
            #expect(
                try VerticalText.marked("脚注" + mark + digits + "</a></sup>も")
                    == "脚注" + mark + "<span class=\"\(style)\">" + digits + "</span></a></sup>も")
        }
        let label = "https://example.org/a-b_c?q=1&amp;x=2#top"
        let expected = url(
            "https:/<wbr>/<wbr>example.<wbr>org/<wbr>a-<wbr>b_<wbr>c?<wbr>q=<wbr>1&amp;<wbr>x=<wbr>2#<wbr>top")
        #expect(try VerticalText.marked(label) == expected)
        #expect(try VerticalText.marked(expected) == expected)
        #expect(try VerticalText.marked(LongTokenMarks.opening + label + "</span>").contains(expected))
    }

    @Test("符号・指数・日時・識別子・単位の中では一部の数字だけを縦中横にしない")
    func compoundNumbers() throws {
        for token in ["-12", "+12", "1e-3", "12:30", "12/25", "2026-11-25", "foo_12"] {
            #expect(try VerticalText.marked(token) == latin(token))
        }
        #expect(try VerticalText.marked("12 kg") == latin("12 kg"))
        #expect(try VerticalText.marked("12 apples").hasPrefix(#"<span class="tcy">12</span>"#))
        for unit in ["12 <em>kg</em>", "<b>12</b> <em>kg</em>"] {
            let result = try VerticalText.marked(unit)
            #expect(result.contains(latin("12")) && result.contains(latin("kg")))
        }
        #expect(try VerticalText.marked("12人") == #"<span class="tcy">12</span>人"#)
        #expect(
            try VerticalText.marked("2026年11月25日") == latin("2026") + aki
                + #"年<span class="tcy">11</span>月<span class="tcy">25</span>日"#)
    }

    @Test("Unicode の数量・範囲・時刻は横倒しにし、和文の助数詞とラベルは独立した整数を保つ")
    func numericRuns() throws {
        func sideways(_ text: String) -> String { #"<span class="v-latin v-sideways">\#(text)</span>"# }
        for token in [
            "−12", "±12", "1e−3", "12°C", "12℃", "12Ω", "12µm", "12㎏", "12\u{202f}kg", "12\u{a0}kg",
            "12\u{2009}kg", "10〜20%", "10～20%", "10%〜20",
        ] {
            #expect(try VerticalText.marked(token) == sideways(token))
        }
        for token in [
            "A-1", "1/2", "No.12",
        ] {
            #expect(try VerticalText.marked(token) == latin(token))
        }
        #expect(try VerticalText.marked("ＡＢ") == latin("ＡＢ"))
        let two = #"<span class="tcy">12</span>"#
        #expect(try VerticalText.marked("人数:12人") == "人数:" + two + "人")
        #expect(try VerticalText.marked("count:12人") == latin("count") + ":" + two + "人")
        #expect(
            try VerticalText.marked("3〜4人")
                == #"<span class="upright-digit">3</span>〜<span class="upright-digit">4</span>人"#)
        #expect(try VerticalText.marked("3-4人") == latin("3-4") + aki + "人")
        #expect(try VerticalText.marked("第2-3章") == "第" + aki + latin("2-3") + aki + "章")
        #expect(try VerticalText.marked("2,000円") == latin("2,000") + aki + "円")
        #expect(try VerticalText.marked("午後3:00") == "午後" + aki + latin("3:00"))
        #expect(try VerticalText.marked("和−12°C文") == "和" + aki + sideways("−12°C") + aki + "文")
        #expect(
            try VerticalText.marked("12&#x202f;<b>Ω</b>人") == latin("12") + "&#x202f;<b>" + sideways("Ω") + "</b>" + aki
                + "人")
    }

    @Test("範囲の両端で時刻・分数・指数を最後まで読み、助数詞に続く整数の向きを保つ")
    func rangeEndpoints() throws {
        func sideways(_ text: String) -> String { #"<span class="v-latin v-sideways">\#(text)</span>"# }
        func pair(_ digits: String) -> String { #"<span class="tcy">\#(digits)</span>"# }
        func single(_ digit: String) -> String { #"<span class="upright-digit">\#(digit)</span>"# }
        for (source, expected) in [
            ("12:30〜13:00", sideways("12:30〜13:00")), ("1/2〜3/4", sideways("1/2〜3/4")),
            ("12〜13:30", sideways("12〜13:30")), ("10^3", latin("10^3")),
            ("3月12日〜15日", single("3") + "月" + pair("12") + "日〜" + pair("15") + "日"),
            ("1,234.5円", latin("1,234.5") + aki + "円"), ("約−3℃", "約" + aki + sideways("−3℃")),
            ("A4 2段", latin("A4") + " " + single("2") + "段"), ("第12回", "第" + pair("12") + "回"),
            ("v1.2.3", latin("v1.2.3")), ("12時30分", pair("12") + "時" + pair("30") + "分"),
            ("5%〜10%", sideways("5%〜10%")), ("2～10^−3", sideways("2～10^−3")),
            ("10^文", pair("10") + "^文"),
        ] {
            #expect(try VerticalText.marked(source) == expected)
        }
    }

    @Test("文字参照の原綴りと表示文字を保ち、同じ表示なら同じ和欧境界と縦中横を付ける")
    func references() throws {
        // Decode the fixture's references within each node, as an HTML reader would.
        // Joining first would mask a span inserted halfway through a reference.
        let references = [
            ("&#x65e5", "日"), ("&#49", "1"), ("&#50", "2"), ("&#80;", "P"), ("&Aacute;", "Á"), ("&amp", "&"),
        ]
        func visible(_ html: String) -> String {
            HTMLScanner.tokens(html).compactMap { token in
                guard case .text(let text) = token else { return nil }
                return references.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            }.joined()
        }
        for source in ["&#x65e5", "&amp 文", "&#49&#50", "和&#80;DF文", "和&Aacute;文", "和PDF文", "和Á文"] {
            let result = try VerticalText.marked(source)
            #expect(visible(result) == visible(source))
            if source.hasPrefix("和") {
                #expect(result.components(separatedBy: aki).count == 3)
            }
        }
        #expect(try VerticalText.marked("&#49&#50") == #"<span class="tcy">&#49&#50</span>"#)
    }

    @Test("縦書き前処理の前後で本文・リンク先・数式・ルビの親文字と読みを保つ")
    func protectedContents() throws {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{tarticle}\begin{document}庭25日。\tatechuyoko{$\frac{1}{2}$}\rensuji{\ruby{親}{おや}}\tatechuyoko{\href{https://example.org/12}{参照}}\end{document}"#
        )
        let before = fragment.body + "<p>葛󠄀 e\u{301} 👩‍🔬</p>"
        let after = try VerticalText.marked(before, latex: true)
        func text(_ html: String) -> String {
            HTMLScanner.tokens(html).compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
        }
        let explicit = #"<span class="explicit-tcy"><b>99</b></span>"#
        #expect(
            try VerticalText.marked("25" + explicit + "12", latex: true)
                == #"<span class="tcy">25</span>"# + explicit + #"<span class="tcy">12</span>"#)
        #expect(text(before) == text(after))
        let protected = try #require(before.firstMatch(of: /(?s)<span class="explicit-tcy">.*<\/span>/)?.output)
        #expect(protected.contains("<svg") && protected.contains("<ruby>親<rt>おや</rt></ruby>"))
        #expect(protected.contains(#"href="https://example.org/12""#))
        #expect(after.contains(protected))
    }

    @Test("横書きクラスの縦中横はスタイルを選ぶまで引数の文字と構造を保つ")
    func articleTheme() throws {
        let library = try PrintThemeLibrary.load()
        let longWord = "long_identifier_with_underscores"
        let direct = LongTokenMarks.marked(longWord)
        #expect(direct.contains("long-token"))
        #expect(
            LongTokenMarks.marked(#"<span class="explicit-tcy">\#(longWord)</span>"#)
                == #"<span class="explicit-tcy">\#(direct)</span>"#)
        let manuscript =
            #"\documentclass{article}\begin{document}和\rensuji{AB}文\tatechuyoko{123}日\rensuji{\ruby{親}{おや}}\end{document}"#
        let fragment = LaTeXConverter.convert(manuscript)
        let content =
            #"和<span class="explicit-tcy">AB</span>文<span class="explicit-tcy">123</span>日<span class="explicit-tcy"><ruby>親<rt>おや</rt></ruby></span>"#
        for name in ["standard", "tategaki"] {
            let theme = try #require(library.first { $0.id == name })
            let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
            #expect(html.contains(content))
            if name == "standard" {
                let plain = LaTeXConverter.convert(
                    manuscript.replacingOccurrences(of: #"\rensuji{AB}"#, with: "AB")
                        .replacingOccurrences(of: #"\tatechuyoko{123}"#, with: "123")
                        .replacingOccurrences(of: #"\rensuji{\ruby{親}{おや}}"#, with: #"\ruby{親}{おや}"#))
                let expected = HTMLDocumentBuilder.build(fragment: plain, format: .latex, theme: theme)
                #expect(html.replacingOccurrences(of: content, with: "和AB文123日<ruby>親<rt>おや</rt></ruby>") == expected)
            }
        }
    }

    @Test("縦書きを選んだ本文にだけ前処理を適用し、ソースコードの数字を保つ")
    func themedHTML() throws {
        let themes = try PrintThemeLibrary.load()
        let vertical = try #require(themes.first { $0.id == "tategaki" })
        let standard = try #require(themes.first { $0.id == "standard" })
        let prose = PlainTextConverter.convert("25日")
        let code = PlainTextConverter.convert("let n = 25", fileName: "sample.swift")
        let span = #"<span class="tcy">25</span>"#
        for format in [DocumentFormat.markdown, .org, .plainText, .latex] {
            #expect(HTMLDocumentBuilder.build(fragment: prose, format: format, theme: vertical).contains(span))
            #expect(!HTMLDocumentBuilder.build(fragment: prose, format: format, theme: standard).contains(span))
        }
        #expect(!HTMLDocumentBuilder.build(fragment: code, format: .plainText, theme: vertical).contains(span))
    }

    @Test("縦組み LaTeX の版面にクラスの文字サイズと本文領域を渡す")
    func latexGrid() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        for (declaration, font, rows) in [
            ("[tate]{jlreq}", 10, 1), ("[tate,11pt,twocolumn]{jlreq}", 11, 2), ("[12pt]{tbook}", 12, 1),
        ] {
            let source = #"\documentclass\#(declaration)\begin{document}本文。\end{document}"#
            let fragment = LaTeXConverter.convert(source)
            let box = try #require(fragment.latexClass).pageBox
            let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
            for (key, value) in [
                ("size", String(font)), ("vertical-rows", String(rows)),
                ("text-width", String(box.textWidth)), ("text-height", String(box.textHeight)),
            ] {
                #expect(html.contains(#"data-latex-\#(key)="\#(value)""#))
            }
        }
    }

    @Test("縦組み LaTeX の本文と見出し番号を組み、命令で指定した書式とコードを保つ")
    func latexProse() throws {
        let source = #"""
            \documentclass{tbook}
            \begin{document}
            \chapter{春}\section{朝5時}
            和25日と5日。和PDF文（注）。和\tatechuyoko{12}文\rensuji{34}日。
            \ruby{親}{読25}\kenten{点25}\kasen{線25}。
            \url{https://example.jp/a_b/25}
            \kenten{folder/abcdefghijklmnop25}\kasen{folder/abcdefghijklmnop25}
            文中式 $x=12$。
            \[x=12\]
            \begin{verbatim}
            x = 25
            \end{verbatim}
            \begin{lstlisting}
            y = 25
            \end{lstlisting}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let fragment = LaTeXConverter.convert(source)
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        for expected in [
            #"和<span class="tcy">25</span>日と<span class="upright-digit">5</span>日。和"# + aki + latin("PDF") + aki + "文",
            close("）") + "。",
            #"和<span class="explicit-tcy">12</span>文<span class="explicit-tcy">34</span>日"#,
            #"<ruby>親<rt>読25</rt></ruby><span class="kenten">点25</span><span class="bousen">線25</span>"#,
            #"<span class="secnum">第<span class="tcy">1</span>章</span>春"#,
            #"<span class="secnum">"# + latin("1.1") + #"</span>朝<span class="tcy">5</span>時"#,
            url("https:/<wbr>/<wbr>example.<wbr>jp/<wbr>a_<wbr>b/<wbr>25"),
            #"<span class="kenten">folder/abcdefghijklmnop25</span><span class="bousen">folder/abcdefghijklmnop25</span>"#,
        ] {
            #expect(html.contains(expected), "\(expected)")
        }
        // Compare with the same code decoration and SVG from the horizontal rendering.
        let reference = HTMLDocumentBuilder.build(
            fragment: fragment, format: .latex,
            theme: try #require(PrintThemeLibrary.load().first { $0.id == "standard" }))
        #expect(!reference.contains(#"<span class="tcy">25</span>"#))
        #expect(!reference.contains("data-latex-vertical-rows="))
        let protected = reference.matches(
            of:
                /(?s)<span class="math math-inline".*?<\/svg><\/span>|<pre\b.*?<\/pre>|<div class="math-block".*?<\/div>/
        )
        #expect(protected.count == 4)
        for match in protected { #expect(html.contains(match.output)) }
    }

    @Test("Markdown の日付・割合・約物は縦書きの完成 HTML で一字分の span に入る")
    func markdownProse() throws {
        let source = "これは1段落目で、2026年11月25日。全部で12段落、重さは10kg、割合は50%、円周率は3.14、値段は1,234円。本当か!?"
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let html = HTMLDocumentBuilder.build(
            fragment: MarkdownConverter.convert(source), format: .markdown, theme: theme)
        let expected = """
            これは<span class="upright-digit">1</span>段落目で、\(latin("2026"))\(aki)年<span class="tcy">11</span>月<span class="tcy">25</span>日。\
            全部で<span class="tcy">12</span>段落、重さは\(aki)\(latin("10kg"))、割合は\(aki)\(latin("50%"))、\
            円周率は\(aki)\(latin("3.14"))、値段は\(aki)\(latin("1,234"))\(aki)円。本当か<span class="tcy">!?</span>
            """
        #expect(html.contains(expected))
    }

    @Test("欧文だけの強調はアクセントや入れ子の装飾も斜体にし、和欧混植には傍点を使う")
    func emphasis() throws {
        let source = #"<em title="和文">Café <strong>PDF</strong></em> <em>PDF と日本語</em>"#
        let expected =
            #"<em title="和文" data-vertical-latin>\#(latin("Café")) <strong>\#(latin("PDF"))</strong></em> <em>\#(latin("PDF"))<span class="aki"> </span>と日本語</em>"#
        let actual = try VerticalText.marked(source)
        #expect(actual == expected)
    }

    @Test("リンク先・URL・文字参照・横組みの箱・ルビの読みは原稿のまま保つ")
    func textNodes() throws {
        let untouched = """
            <code>12</code><pre>12</pre><svg><text>12</text></svg><table><tr><td>12</td></tr></table>
            <!-- 12 -->&#39;
            """
        let source =
            untouched + " https://example.org/12?q=5&amp;n=23 https://例.jp/25"
            + #"<ruby>25<rt>12</rt></ruby><a href="a>12">5日</a><pre class="surimono-plain">12日</pre>"#
        let expected =
            untouched + " " + url("https:/<wbr>/<wbr>example.<wbr>org/<wbr>12?<wbr>q=<wbr>5&amp;<wbr>n=<wbr>23") + " "
            + url("https:/<wbr>/<wbr>例.<wbr>jp/<wbr>25")
            + #"<ruby><span class="tcy">25</span><rt>12</rt></ruby><a href="a>12"><span class="upright-digit">5</span>日</a><pre class="surimono-plain"><span class="tcy">12</span>日</pre>"#
        let note = #"<section class="footnotes"><ol><li><p>文PDFと12日。</p></li></ol></section>"#
        #expect(
            try VerticalText.marked(note).contains("文" + aki + latin("PDF") + aki + #"と<span class="tcy">12</span>日。"#))
        let actual = try VerticalText.marked(source)
        #expect(actual == expected)
    }
}

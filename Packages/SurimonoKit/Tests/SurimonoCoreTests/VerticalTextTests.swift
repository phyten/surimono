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
            \ruby{親}{読25}\kenten{点25}\bou{線25}。
            \url{https://example.jp/a_b/25}
            \kenten{folder/abcdefghijklmnop25}\bou{folder/abcdefghijklmnop25}
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
            #"和<span class="tcy">12</span>文<span class="tcy">34</span>日"#,
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

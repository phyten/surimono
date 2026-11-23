import SurimonoFormats
import Testing

/// The expected values are what Emacs 30.2 (Org 9.7.11, ox-html) printed for the same inputs, apart from the
/// markup around the contents list and the ids, which are Surimono's own.
struct OrgOptionsTests {
    private func body(_ source: String, defaults: OrgReadingDefaults = .surimono) -> String {
        OrgConverter.convert(source, defaults: defaults).body
    }

    // MARK: - Defaults

    @Test("指定のない文書は番号も目次も付けず、中括弧のある下付きと上付きだけを読む")
    func surimonoDefaults() {
        #expect(
            body("* Alpha\na_b x^2 a_{b} x^{2}\n** Beta")
                == "<h1>Alpha</h1>\n<p>a_b x^2 a<sub>b</sub> x<sup>2</sup></p>\n<h2>Beta</h2>\n")
    }

    @Test("Emacs の既定では、番号と目次が付き、中括弧のない下付きと上付きも読む")
    func emacsDefaults() {
        let html = body("* Alpha\na_b x^2\n** Beta", defaults: .emacs)
        #expect(html.contains("<nav class=\"toc\" role=\"doc-toc\"><p class=\"toc-title\">Table of Contents</p>"))
        #expect(html.contains("<h1 id=\"alpha\"><span class=\"section-number-1\">1.</span> Alpha</h1>"))
        #expect(html.contains("<h2 id=\"beta\"><span class=\"section-number-2\">1.1.</span> Beta</h2>"))
        #expect(html.contains("<p>a<sub>b</sub> x<sup>2</sup></p>"))
    }

    @Test("文書の指定は既定より優先する")
    func documentWins() {
        let html = body("#+OPTIONS: num:nil toc:nil ^:nil\n* Alpha\na_{b}", defaults: .emacs)
        #expect(html == "<h1>Alpha</h1>\n<p>a_{b}</p>\n")
    }

    @Test("あとの OPTIONS の行が前の行の同じキーを上書きし、ほかのキーは残る")
    func laterLineWins() {
        let html = body("#+OPTIONS: num:t ^:nil\n#+options: num:nil\n* Alpha\na_{b}")
        #expect(html == "<h1>Alpha</h1>\n<p>a_{b}</p>\n")
    }

    @Test("STARTUP の num は書き出しに効かない")
    func startupIsNotAnExportOption() {
        #expect(body("#+STARTUP: num\n* Alpha") == "<h1>Alpha</h1>\n")
    }

    // MARK: - Section numbers

    @Test("num:t は見出しに 1. 1.1. 1.1.1. と番号を付ける")
    func numbers() {
        let html = body("#+OPTIONS: num:t\n* A\n** B\n*** C\n** D\n* E")
        #expect(
            html == """
                <h1><span class="section-number-1">1.</span> A</h1>
                <h2><span class="section-number-2">1.1.</span> B</h2>
                <h3><span class="section-number-3">1.1.1.</span> C</h3>
                <h2><span class="section-number-2">1.2.</span> D</h2>
                <h1><span class="section-number-1">2.</span> E</h1>

                """)
    }

    @Test("num:2 は 2 階層目までに番号を付ける")
    func numberDepth() {
        let html = body("#+OPTIONS: num:2\n* A\n** B\n*** C")
        #expect(html.contains("<span class=\"section-number-2\">1.1.</span> B"))
        #expect(html.contains("<h3>C</h3>"))
    }

    @Test("num:0 と num:nil は番号を付けない", arguments: ["num:0", "num:nil"])
    func noNumbers(option: String) {
        #expect(body("#+OPTIONS: \(option)\n* A", defaults: .emacs.with(tableOfContents: .off)) == "<h1>A</h1>\n")
    }

    @Test("nil でも数でもない値は t として読む")
    func otherValuesAreTrue() {
        #expect(body("#+OPTIONS: num:yes\n* A").contains("section-number-1\">1.</span> A"))
    }

    @Test("題のある文書では、番号の span のクラスは見出しの要素の階層に合わせる")
    func numberClassFollowsTheElement() {
        let html = body("#+TITLE: T\n#+OPTIONS: num:t\n* A")
        #expect(html.contains("<h2><span class=\"section-number-2\">1.</span> A</h2>"))
    }

    @Test("UNNUMBERED の見出しとその下の見出しには番号を付けず、数にも入れない")
    func unnumbered() {
        let html = body(
            "#+OPTIONS: num:t\n* A\n* U\n:PROPERTIES:\n:UNNUMBERED: t\n:END:\n** Child\n* B")
        #expect(html.contains("<h1>U</h1>"))
        #expect(html.contains("<h2>Child</h2>"))
        #expect(html.contains("section-number-1\">2.</span> B"))
    }

    @Test("階層を飛ばした見出しは、飛ばした階層を 0 にする")
    func skippedLevel() {
        let html = body("#+OPTIONS: num:t\n* A\n*** Deep\n** B")
        #expect(html.contains("section-number-3\">1.0.1.</span> Deep"))
        #expect(html.contains("section-number-2\">1.1.</span> B"))
    }

    @Test("いちばん浅い見出しが ** の文書は、そこを 1 階層目として数える")
    func relativeLevels() {
        let html = body("#+OPTIONS: num:1\n** A\n*** B\n** C")
        #expect(html.contains("<h2><span class=\"section-number-2\">1.</span> A</h2>"))
        #expect(html.contains("<h3>B</h3>"))
        #expect(html.contains("section-number-2\">2.</span> C"))
    }

    @Test("番号は TODO キーワードの前に置く")
    func numberBeforeKeyword() {
        let html = body("#+OPTIONS: num:t\n* TODO A")
        #expect(html.contains("<span class=\"section-number-1\">1.</span> <span class=\"org-todo\">TODO</span> A</h1>"))
    }

    @Test("番号について文書が決めたかどうかを断片が伝える")
    func fragmentTellsWhoDecides() {
        #expect(!OrgConverter.convert("* A").decidesHeadingNumbers)
        #expect(OrgConverter.convert("#+OPTIONS: num:nil\n* A").decidesHeadingNumbers)
        #expect(OrgConverter.convert("#+OPTIONS: num:t\n* A").decidesHeadingNumbers)
        #expect(OrgConverter.convert("* A", defaults: .emacs).decidesHeadingNumbers)
    }

    // MARK: - Table of contents

    @Test("toc:t は題のあと本文の前に、3 階層までの目次を出す")
    func contents() {
        let html = body("#+TITLE: T\n#+OPTIONS: toc:t\nintro\n* A\n** B\n*** C\n**** D\n* E")
        #expect(
            html.contains(
                """
                </header>
                <nav class="toc" role="doc-toc"><p class="toc-title">Table of Contents</p>\
                <ul><li><a href="#a">A</a><ul><li><a href="#b">B</a><ul><li><a href="#c">C</a></li></ul></li></ul></li>\
                <li><a href="#e">E</a></li></ul></nav>
                <p>intro</p>
                <h2 id="a">A</h2>
                """))
        #expect(html.contains("<h5 id=\"d\">D</h5>"))
    }

    @Test("toc:2 は 2 階層目までを並べる")
    func contentsDepth() {
        let html = body("#+OPTIONS: toc:2\n* A\n** B\n*** C")
        #expect(html.contains("<a href=\"#b\">B</a></li></ul></li></ul></nav>"))
        #expect(!html.contains("href=\"#c\""))
    }

    @Test("H:1 のとき、toc:t の目次は 1 階層だけになる")
    func headlineLevelsLimitContents() {
        let html = body("#+OPTIONS: toc:t H:1\n* A\n** B\n* C")
        #expect(html.contains("<ul><li><a href=\"#a\">A</a></li><li><a href=\"#c\">C</a></li></ul>"))
    }

    @Test("toc:nil と toc:0 は目次を出さない", arguments: ["toc:nil", "toc:0"])
    func noContents(option: String) {
        #expect(body("#+OPTIONS: \(option)\n* A", defaults: .emacs.with(sectionNumbers: .off)) == "<h1>A</h1>\n")
    }

    @Test("番号のある文書の目次は番号を添える")
    func numberedContents() {
        let html = body("#+OPTIONS: toc:t num:t\n* A\n** B")
        #expect(html.contains("<a href=\"#a\">1. A</a><ul><li><a href=\"#b\">1.1. B</a>"))
    }

    @Test("日本語の文書の目次の題は「目次」")
    func japaneseTitle() {
        #expect(body("#+LANGUAGE: ja\n#+OPTIONS: toc:t\n* 序").contains("<p class=\"toc-title\">目次</p>"))
    }

    @Test("同じ見出しが続くときは id に連番を付け、CUSTOM_ID があればそれを使う")
    func ids() {
        let html = body("#+OPTIONS: toc:t\n* A\n* A\n* Named\n:PROPERTIES:\n:CUSTOM_ID: my-id\n:END:")
        #expect(html.contains("<h1 id=\"a\">A</h1>\n<h1 id=\"a-1\">A</h1>\n<h1 id=\"my-id\">Named</h1>"))
        #expect(html.contains("<a href=\"#my-id\">Named</a>"))
    }

    @Test("UNNUMBERED: notoc の見出しは目次に出さない")
    func excludedFromContents() {
        let html = body("#+OPTIONS: toc:t\n* A\n* B\n:PROPERTIES:\n:UNNUMBERED: notoc\n:END:\n* C")
        #expect(html.contains("<ul><li><a href=\"#a\">A</a></li><li><a href=\"#c\">C</a></li></ul>"))
    }

    @Test("目次の項目は脚注の番号とリンクを持たない")
    func contentsEntriesAreFlat() {
        let html = body("#+OPTIONS: toc:t\n* A[fn:1] [[https://example.com][link]]\n\n[fn:1] note")
        #expect(html.contains("<li><a href=\"#a-link\">A link</a></li>"))
        #expect(html.contains("<h1 id=\"a-link\">A<sup class=\"footnote-ref\">"))
    }

    @Test("見出しのない文書は目次を出さない")
    func noHeadings() {
        #expect(body("#+OPTIONS: toc:t\ntext") == "<p>text</p>\n")
    }

    @Test("#+TOC: headlines は、toc:nil でもその場所に目次を出す")
    func contentsKeyword() {
        let html = body("#+OPTIONS: toc:nil\n* A\n** B\n#+TOC: headlines 1\n* C")
        #expect(
            html.contains(
                """
                <h2 id="b">B</h2>
                <nav class="toc" role="doc-toc"><p class="toc-title">Table of Contents</p>\
                <ul><li><a href="#a">A</a></li><li><a href="#c">C</a></li></ul></nav>
                <h1 id="c">C</h1>
                """))
        #expect(html.hasPrefix("<h1 id=\"a\">A</h1>"))
    }

    @Test("#+TOC: headlines の local は、その見出しの下だけを題なしで並べる")
    func localContents() {
        let html = body("* A\n#+TOC: headlines 1 local\n** A1\n*** Deep\n** A2\n* B")
        #expect(
            html.contains(
                "<nav class=\"toc\" role=\"doc-toc\"><ul><li><a href=\"#a1\">A1</a></li><li><a href=\"#a2\">A2</a></li></ul></nav>"
            ))
    }

    // MARK: - Subscripts and superscripts

    @Test(
        "^:t は中括弧のない下付きと上付きも読む",
        arguments: [
            ("a_b x^2", "a<sub>b</sub> x<sup>2</sup>"),
            ("file_name_x", "file<sub>name</sub><sub>x</sub>"),
            ("snake_case_ H_2O", "snake<sub>case</sub>_ H<sub>2O</sub>"),
            ("x^-1 a^* a_1,2", "x<sup>-1</sup> a<sup>*</sup> a<sub>1,2</sub>"),
            ("a_b. x^2, a_1.5 a_b.c.", "a<sub>b</sub>. x<sup>2</sup>, a<sub>1.5</sub> a<sub>b.c</sub>."),
            ("a_(b) a^(1+2)", "a<sub>(b)</sub> a<sup>(1+2)</sup>"),
            ("x^+ a_ b a__b", "x^+ a_ b a_<sub>b</sub>"),
            ("a_b^c p^q^r", "a<sub>b</sub><sup>c</sup> p<sup>q</sup><sup>r</sup>"),
            ("日本_語 a_日本", "日本<sub>語</sub> a<sub>日本</sub>"),
            ("a_1e-5 a_-b", "a<sub>1e</sub>-5 a<sub>-b</sub>"),
            ("a_{b_{c}} pre_{x}post", "a<sub>b<sub>c</sub></sub> pre<sub>x</sub>post"),
            ("a_{*b*} x^{a b}", "a<sub><strong>b</strong></sub> x<sup>a b</sup>"),
            ("a_{unclosed b", "a_{unclosed b"),
            ("a (_u_) b _lead", "a (<u>u</u>) b _lead"),
            ("=a_b= ~x^2~", "<code>a_b</code> <code>x^2</code>"),
            ("/it_al/ *bo^ld*", "<em>it<sub>al</sub></em> <strong>bo<sup>ld</sup></strong>"),
        ])
    func scripts(source: String, expected: String) {
        #expect(body("#+OPTIONS: ^:t\n" + source) == "<p>\(expected)</p>\n")
    }

    @Test("^:{} は中括弧のあるものだけを読む")
    func bracedScripts() {
        #expect(
            body("#+OPTIONS: ^:{}\na_b x^2 a_(b) a^* a_{b} x^{2}")
                == "<p>a_b x^2 a_(b) a^* a<sub>b</sub> x<sup>2</sup></p>\n")
    }

    @Test("^:nil は下付きと上付きを読まない")
    func noScripts() {
        #expect(body("#+OPTIONS: ^:nil\na_b a_{b} x^{2}") == "<p>a_b a_{b} x^{2}</p>\n")
    }

    @Test("リンク先と数式と URL の中の _ は下付きにしない")
    func scriptsLeaveLinksAndMathAlone() {
        let html = body("#+OPTIONS: ^:t\n[[https://example.com/a_b][l_k]] https://example.com/c_d $x_1$")
        #expect(html.contains("<a href=\"https://example.com/a_b\">l<sub>k</sub></a> https://example.com/c_d "))
        #expect(!html.contains("x<sub>1</sub>"))
    }

    @Test("見出しと表のセルでも下付きと上付きを読む")
    func scriptsInHeadingsAndTables() {
        let html = body("#+OPTIONS: ^:t\n* H_2O\n| t_1 | x^2 |")
        #expect(html.contains("<h1>H<sub>2O</sub></h1>"))
        #expect(html.contains("<td>t<sub>1</sub></td><td>x<sup>2</sup></td>"))
    }

    @Test("閉じない中括弧が続いても時間がかからない", .timeLimit(.minutes(1)))
    func unclosedBracesStayLinear() {
        let source = String(repeating: "a_{", count: 20_000)
        #expect(body(source).contains("a_{a_{"))
    }
}

import SurimonoFormats
import Testing

/// The expected values are what Emacs 30.2 (Org 9.7.11, ox-html) printed for the same inputs, apart from the
/// markup around the contents list and the ids, which are Surimono's own.
@Suite(.timeLimit(.minutes(1)))
struct OrgOptionsTests {
    /// What Emacs does with a file that sets nothing, for the three keys read here.
    private static let likeEmacs = OrgReadingDefaults(sectionNumbers: .all, tableOfContents: .all, scripts: .all)

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

    @Test("既定を変えると、指定のない文書に番号と目次が付き、中括弧のない下付きと上付きも読む")
    func otherDefaults() {
        let html = body("* Alpha\na_b x^2\n** Beta", defaults: Self.likeEmacs)
        #expect(html.contains("<nav class=\"toc\" role=\"doc-toc\"><p class=\"toc-title\">Table of Contents</p>"))
        #expect(html.contains("<h1 id=\"alpha\"><span class=\"section-number-1\">1.</span> Alpha</h1>"))
        #expect(html.contains("<h2 id=\"beta\"><span class=\"section-number-2\">1.1.</span> Beta</h2>"))
        #expect(html.contains("<p>a<sub>b</sub> x<sup>2</sup></p>"))
    }

    @Test("文書の指定は既定より優先する")
    func documentWins() {
        let html = body("#+OPTIONS: num:nil toc:nil ^:nil\n* Alpha\na_{b}", defaults: Self.likeEmacs)
        #expect(html == "<h1>Alpha</h1>\n<p>a_{b}</p>\n")
    }

    @Test("あとの OPTIONS の行が前の行の同じキーを上書きし、ほかのキーは残る")
    func laterLineWins() {
        let html = body("#+OPTIONS: num:nil ^:t\n#+options: num:t\n* Alpha a_b")
        #expect(html == "<h1><span class=\"section-number-1\">1.</span> Alpha a<sub>b</sub></h1>\n")
    }

    @Test("キーは大文字でも小文字でも読む")
    func keysIgnoreCase() {
        let html = body("#+OPTIONS: NUM:nil TOC:1 h:3\n* A\n** B", defaults: Self.likeEmacs)
        #expect(html.contains("<ul><li><a href=\"#a\">A</a></li></ul>"))
        #expect(html.contains("<h1 id=\"a\">A</h1>\n<h2 id=\"b\">B</h2>"))
    }

    @Test("値のないキーは何も決めない")
    func emptyValue() {
        #expect(body("#+OPTIONS: num: toc:nil\n* A", defaults: Self.likeEmacs).hasPrefix("<h1><span"))
        #expect(!OrgConverter.convert("#+OPTIONS: num: toc:nil\n* A").decidesHeadingNumbers)
    }

    @Test("ほかのキーの括弧の中にある num は指定に数えず、括弧のあとのキーは読む")
    func parenthesizedValue() {
        let html = body("#+OPTIONS: toc:nil foo:(num:nil x) ^:nil\n* A a_b", defaults: Self.likeEmacs)
        #expect(html == "<h1><span class=\"section-number-1\">1.</span> A a_b</h1>\n")
    }

    @Test("前に余分な語のあるキーは読まない")
    func strayWord() {
        #expect(body("#+OPTIONS: stray num:nil toc:nil\n* A", defaults: Self.likeEmacs).hasPrefix("<h1><span"))
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

    @Test("num:2 と num:+2 は 2 階層目までに番号を付ける", arguments: ["num:2", "num:+2", "num:2."])
    func numberDepth(option: String) {
        let html = body("#+OPTIONS: \(option)\n* A\n** B\n*** C")
        #expect(html.contains("<span class=\"section-number-2\">1.1.</span> B"))
        #expect(html.contains("<h3>C</h3>"))
    }

    @Test("num:0 と num:nil は番号を付けない", arguments: ["num:0", "num:nil", "num:()"])
    func noNumbers(option: String) {
        #expect(body("#+OPTIONS: \(option) toc:nil\n* A", defaults: Self.likeEmacs) == "<h1>A</h1>\n")
    }

    @Test("nil でも 0 以上の整数でもない値は t として読む", arguments: ["num:yes", "num:-1", "num:1.5"])
    func otherValuesAreTrue(option: String) {
        let html = body("#+OPTIONS: \(option)\n* A\n** B")
        #expect(html.contains("section-number-2\">1.1.</span> B"))
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
        #expect(OrgConverter.convert("#+OPTIONS: NUM:nil\n* A").decidesHeadingNumbers)
        #expect(OrgConverter.convert("#+OPTIONS: num:t\n* A").decidesHeadingNumbers)
        #expect(OrgConverter.convert("* A", defaults: Self.likeEmacs).decidesHeadingNumbers)
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

    @Test("toc:-1 は toc:t と同じに読む")
    func negativeContentsDepth() {
        #expect(body("#+OPTIONS: toc:-1\n* A\n** B").contains("<a href=\"#a\">A</a><ul><li><a href=\"#b\">B</a>"))
    }

    @Test("H:1 のとき、toc:t の目次は 1 階層だけになる")
    func headlineLevelsLimitContents() {
        let html = body("#+OPTIONS: toc:t H:1\n* A\n** B\n* C")
        #expect(html.contains("<ul><li><a href=\"#a\">A</a></li><li><a href=\"#c\">C</a></li></ul>"))
    }

    @Test("toc:nil と toc:0 は目次を出さない", arguments: ["toc:nil", "toc:0"])
    func noContents(option: String) {
        #expect(body("#+OPTIONS: \(option) num:nil\n* A", defaults: Self.likeEmacs) == "<h1>A</h1>\n")
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

    @Test("階層を飛ばした見出しは、リンクのない項目の中のリストに入る")
    func skippedLevelInContents() {
        let html = body("#+OPTIONS: toc:t\n* A\n*** C\n** B")
        #expect(
            html.contains(
                "<ul><li><a href=\"#a\">A</a><ul><li><ul><li><a href=\"#c\">C</a></li></ul></li>"
                    + "<li><a href=\"#b\">B</a></li></ul></li></ul></nav>"))
    }

    @Test("深い見出しから始まる文書の目次も、リストは項目の中にだけ入る")
    func deepFirstContents() {
        let html = body("#+OPTIONS: toc:t\n*** C\n** B\n* A")
        #expect(
            html.contains(
                "<ul><li><ul><li><ul><li><a href=\"#c\">C</a></li></ul></li>"
                    + "<li><a href=\"#b\">B</a></li></ul></li><li><a href=\"#a\">A</a></li></ul></nav>"))
    }

    @Test("同じ見出しが続いても、連番の付いた見出しがあっても id は重ならない")
    func ids() {
        let html = body("#+OPTIONS: toc:t\n* A\n* A\n* A-1")
        #expect(html.contains("<h1 id=\"a\">A</h1>\n<h1 id=\"a-1\">A</h1>\n<h1 id=\"a-1-1\">A-1</h1>"))
    }

    @Test("脚注の id と同じ形の見出しは、別の語幹の id になる")
    func noteLikeIDs() {
        let html = body("#+OPTIONS: toc:t\n* fn-1\n* fn-1\n* fnref-1-2\n\ntext[fn:1]\n\n[fn:1] note")
        #expect(html.contains("<h1 id=\"section-fn-1\">fn-1</h1>\n<h1 id=\"section-fn-1-1\">fn-1</h1>"))
        #expect(html.contains("<h1 id=\"section-fnref-1-2\">fnref-1-2</h1>"))
        #expect(html.contains("<li id=\"fn-1\">"))
    }

    @Test("同じ題の見出しが何千あっても、id はすべて違う")
    func manyHeadingsWithOneTitle() {
        let html = body("#+OPTIONS: toc:nil\n#+TOC: headlines\n" + String(repeating: "* Same\n", count: 5_000))
        #expect(html.contains("<h1 id=\"same\">Same</h1>\n<h1 id=\"same-1\">Same</h1>"))
        #expect(html.hasSuffix("<h1 id=\"same-4999\">Same</h1>\n"))
    }

    @Test("CUSTOM_ID は後ろにあっても、前の見出しの id に取られない")
    func customIDIsReserved() {
        let html = body("#+OPTIONS: toc:t\n* Named\n* Other\n:PROPERTIES:\n:CUSTOM_ID: named\n:END:")
        #expect(html.contains("<h1 id=\"named-1\">Named</h1>\n<h1 id=\"named\">Other</h1>"))
        #expect(html.contains("<a href=\"#named\">Other</a>"))
    }

    @Test("CUSTOM_ID は目次のない文書でも見出しの id になる")
    func customIDWithoutContents() {
        let html = body("* A\n:PROPERTIES:\n:CUSTOM_ID: my-id\n:END:\n[[#my-id][go]]\n* B")
        #expect(html == "<h1 id=\"my-id\">A</h1>\n<p><a href=\"#my-id\">go</a></p>\n<h1>B</h1>\n")
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
        let html = body("#+OPTIONS: toc:nil\n* A\n** B\n#+toc: HEADLINES 1\n* C")
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

    @Test("headlines で始まるだけの #+TOC は目次にせず、見出しに id も付けない")
    func otherContentsKeyword() {
        #expect(body("* A\n#+TOC: headlinesXYZ\n#+TOC: tables") == "<h1>A</h1>\n")
    }

    @Test("#+TOC: headlines の local は、その見出しの下だけを題なしで並べる")
    func localContents() {
        let html = body("* A\n#+TOC: headlines 1 local\n** A1\n*** Deep\n** A2\n* B")
        #expect(
            html.contains(
                "<nav class=\"toc\" role=\"doc-toc\"><ul><li><a href=\"#a1\">A1</a></li><li><a href=\"#a2\">A2</a></li></ul></nav>"
            ))
    }

    @Test("local の深さがとても大きくても、見出しの深さの上限までを並べる")
    func hugeLocalDepth() {
        let html = body("* A\n#+TOC: headlines 9223372036854775807 local\n** A1\n*** A2\n**** A3")
        #expect(html.contains("<ul><li><a href=\"#a1\">A1</a><ul><li><a href=\"#a2\">A2</a></li></ul></li></ul></nav>"))
    }

    @Test("見出しの深さの上限より深い見出しの下の local は何も出さない")
    func localBelowHeadlineLevels() {
        let html = body("#+OPTIONS: H:1\n* A\n#+TOC: headlines local\n** A1")
        #expect(!html.contains("<nav"))
    }

    @Test("目次をいくつ頼まれても、並べる項目の合計には上限がある", .timeLimit(.minutes(1)))
    func contentsBudget() {
        let headings = (1...300).map { "* H\($0)" }.joined(separator: "\n")
        let keywords = String(repeating: "#+TOC: headlines\n", count: 400)
        let html = body(headings + "\n" + keywords)
        // 300 entries each: 166 tables fit in 50,000 entries.
        #expect(html.components(separatedBy: "<nav class=\"toc\"").count - 1 == 166)
        #expect(html.hasSuffix("</nav>\n"))
    }

    @Test("目次の指示が多い長い文書でも時間がかからない", .timeLimit(.minutes(1)))
    func manyKeywordsStayLinear() {
        let source = String(repeating: "#+TOC: headlines\ntext\n\n", count: 20_000)
        let html = body(source)
        #expect(html.components(separatedBy: "<p>text</p>").count - 1 == 20_000)
        #expect(!html.contains("<!--"))
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
            ("a-_word_ x_y-_z_", "a-<u>word</u> x<sub>y</sub>-<u>z</u>"),
            ("a-~x^2~ www.a_b.org", "a-<code>x^2</code> www.a<sub>b.org</sub>"),
            ("a^(b(c(d))) a^(b(c(d(e))))", "a<sup>(b(c(d)))</sup> a^(b(c(d(e))))"),
            ("a_{{}}", "a<sub>{}</sub>"),
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

    @Test("中括弧の入れ子は 2 段までを読み、それより深いものは文字のままにする")
    func braceNesting() {
        #expect(
            body("a_{b{c}} a_{b{c{d}}} a_{b{c{d{e}}}}")
                == "<p>a<sub>b{c}</sub> a<sub>b{c{d}}</sub> a_{b{c{d{e}}}}</p>\n")
    }

    @Test("行をまたぐ中括弧も読む")
    func bracesAcrossLines() {
        #expect(body("a_{b\nc} z") == "<p>a<sub>b\nc</sub> z</p>\n")
    }

    // Emacs prints `a<sup>nil</sup>` here, a word the author did not write.
    @Test("空の中括弧は文字のままにする")
    func emptyBraces() {
        #expect(body("a^{} b_{}") == "<p>a^{} b_{}</p>\n")
    }

    @Test("^:nil は下付きと上付きを読まない", arguments: ["^:nil", "^:()"])
    func noScripts(option: String) {
        #expect(body("#+OPTIONS: \(option)\na_b a_{b} x^{2}") == "<p>a_b a_{b} x^{2}</p>\n")
    }

    @Test(
        "本文の中のアドレスは、下付きと上付きの指定によらず文字を変えない",
        arguments: [
            "https://example.org/a_{b}x", "mailto:a_{b}@example.org", "HTTPS://Example.org/a^{b}",
            "file:name_{x}.txt", "ftp://x/a_{b}", "doi:10.1/a_{b}", "news:a_{b}",
        ])
    func plainLinks(address: String) {
        #expect(body("see \(address) here") == "<p>see \(address) here</p>\n")
        #expect(body("#+OPTIONS: ^:t\nsee \(address) here") == "<p>see \(address) here</p>\n")
    }

    @Test("アドレスは括弧と文末の句読点の手前で終わる")
    func plainLinkEnds() {
        let html = body("#+OPTIONS: ^:t\n(https://e.org/a_b) https://e.org/a_(b)_c. file: a_b x_https://e.org/a_b")
        #expect(
            html
                == "<p>(https://e.org/a_b) https://e.org/a_(b)_c. file: a<sub>b</sub> x<sub>https</sub>://e.org/a<sub>b</sub></p>\n"
        )
    }

    @Test("説明のないリンクは行き先をそのまま見せ、説明だけを記法として読む")
    func linksWithoutDescription() {
        let html = body("#+OPTIONS: ^:t\n[[file:file_name_x.txt]] [[https://e.org/a_{b}]] [[https://e.org/a_b][d_e]]")
        #expect(
            html == "<p><a href=\"file_name_x.txt\">file_name_x.txt</a> "
                + "<a href=\"https://e.org/a_{b}\">https://e.org/a_{b}</a> "
                + "<a href=\"https://e.org/a_b\">d<sub>e</sub></a></p>\n")
    }

    @Test("数式の中の _ は下付きにしない")
    func scriptsLeaveMathAlone() {
        #expect(!body("#+OPTIONS: ^:t\n$x_1$").contains("x<sub>1</sub>"))
    }

    @Test(
        "強調はハイフンの隣でも読み、角括弧の隣では読まない",
        arguments: [
            ("a-~x^{2}~ a-=y_{1}=", "a-<code>x^{2}</code> a-<code>y_{1}</code>"),
            ("a-*b* x-*b*-y", "a-<strong>b</strong> x-<strong>b</strong>-y"),
            ("x*b*-y", "x*b*-y"),
            ("(/i/) {*b*}", "(<em>i</em>) {<strong>b</strong>}"),
            ("[/i/] *b*]", "[/i/] *b*]"),
        ])
    func emphasisBorders(source: String, expected: String) {
        #expect(body(source) == "<p>\(expected)</p>\n")
    }

    @Test("強調のすぐあとに脚注を置ける")
    func emphasisBeforeNote() {
        #expect(body("*b*[fn:1]\n\n[fn:1] note").hasPrefix("<p><strong>b</strong><sup class=\"footnote-ref\">"))
    }

    @Test("見出しと表のセルでも下付きと上付きを読む")
    func scriptsInHeadingsAndTables() {
        let html = body("#+OPTIONS: ^:t\n* H_2O\n| t_1 | x^2 |")
        #expect(html.contains("<h1>H<sub>2O</sub></h1>"))
        #expect(html.contains("<td>t<sub>1</sub></td><td>x<sup>2</sup></td>"))
    }

    @Test("閉じない中括弧が続いても時間がかからず、そのあとの上付きを読む", .timeLimit(.minutes(1)))
    func unclosedBracesStayLinear() {
        let html = body(String(repeating: "a_{", count: 20_000) + " x^{2}")
        #expect(html.hasSuffix("a_{ x<sup>2</sup></p>\n"))
    }
}

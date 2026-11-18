import SurimonoFormats
import Testing

struct LaTeXCounterTests {
    private func body(_ source: String) -> String { LaTeXConverter.convert(source).body }

    @Test("カウンターの加減算とステップは同じ整数を更新する")
    func arithmetic() {
        let html = body(#"\newcounter{c}\setcounter{c}{6}\addtocounter{c}{-2}\stepcounter{c}\value{c}/\thec"#)
        #expect(html == "<p>5/5</p>\n")
    }

    @Test("カウンター値を別のカウンターへ渡せる")
    func assignValue() {
        let html = body(#"\newcounter{a}\newcounter{b}\setcounter{a}{7}\setcounter{b}{\value{a}}\arabic{b}"#)
        #expect(html == "<p>7</p>\n")
    }

    @Test(
        "整数の表示書式を選べる",
        arguments: [
            ("arabic", "3"), ("roman", "iii"), ("Roman", "III"), ("alph", "c"), ("Alph", "C"), ("fnsymbol", "‡"),
        ])
    func counterFormat(example: (String, String)) {
        let html = body("\\newcounter{n}\\setcounter{n}{3}\\\(example.0){n}")
        #expect(html == "<p>\(example.1)</p>\n")
    }

    @Test("newcounter の親を進めると子がゼロに戻る")
    func counterReset() {
        let html = body(#"\newcounter{card}[section]\stepcounter{card}\thecard/\stepcounter{section}\thecard"#)
        #expect(html == "<p>1/0</p>\n")
    }

    @Test("refstepcounter は次のラベルにリンク先と独自の表示番号を渡す")
    func referenceCounter() {
        let html = body(#"\newcounter{x}\renewcommand{\thex}{X-\Alph{x}}\refstepcounter{x}\label{a}\ref{a}"#)
        #expect(html.contains(##"<span id="counter-x-X-A"></span><a href="#counter-x-X-A">X-A</a>"##))
    }

    @Test("節番号の再定義を見出し・下位の節・目次・参照に使う")
    func sectionFormat() {
        let html = body(
            #"""
            \documentclass{article}\setcounter{section}{3}\renewcommand{\thesection}{S-\Roman{section}}
            \begin{document}\tableofcontents\section{Main}\label{s}\subsection{Sub}\ref{s}\end{document}
            """#)
        #expect(html.contains(#"<h2 id="sec-S-IV"><span class="secnum">S-IV</span>Main</h2>"#))
        #expect(html.contains(##"<a href="#sec-S-IV"><span class="secnum">S-IV</span>Main</a>"##))
        #expect(html.contains(#"<span class="secnum">S-IV.1</span>Sub"#))
        #expect(html.contains(##"<a href="#sec-S-IV">S-IV</a>"##))
    }

    @Test("読まない分岐と未使用のマクロにある章は節の番号を変えない")
    func unusedChapter() {
        let html = body(#"\newcommand{\unused}{\chapter{Hidden}}\iffalse\chapter{Hidden}\fi\section{First}"#)
        #expect(html == #"<h2 id="sec-1"><span class="secnum">1</span>First</h2>"# + "\n")
    }

    @Test("番号なし見出しの名前参照はその見出しへリンクする")
    func starredName() {
        let html = body(#"\section{First}\label{a}\section*{Afterword\label{b}}\nameref{b}"#)
        #expect(html.contains(##"<a href="#sec-u2">Afterword</a>"##))
    }

    @Test("章が進むと節とその下位のカウンターをすべて戻す")
    func resetDescendants() {
        let html = body(
            #"\chapter{One}\section{First}\subsection{Fine}\chapter{Two}\thechapter/\thesection/\thesubsection"#)
        #expect(html.contains("<p>2/2.0/2.0.0</p>"))
    }

    @Test("節ごとの式番号を式の横と参照に出す")
    func numberWithinEquation() {
        let html = body(
            #"""
            \numberwithin{equation}{section}\section{One}
            \begin{equation}a\label{x}\end{equation}\begin{equation}b\end{equation}
            \section{Two}\begin{equation}c\label{y}\end{equation}\eqref{x}/\eqref{y}
            """#)
        #expect(html.contains(#"<span class="eqno">(1.2)</span>"#))
        #expect(html.contains(#"<span class="eqno">(2.1)</span>"#))
        #expect(html.contains(##"<a href="#eq-1.1">(1.1)</a>/<a href="#eq-2.1">(2.1)</a>"##))
    }

    @Test("独自の式番号を数式と整列の行および参照に出す")
    func equationFormat() {
        let html = body(
            #"""
            \renewcommand{\theequation}{Q-\Roman{equation}}
            \begin{equation}a\end{equation}\begin{align}b&=c\label{b}\\d&=e\label{d}\end{align}
            \eqref{b}/\eqref{d}
            """#)
        #expect(html.contains(#"<span class="eqno">(Q-I)</span>"#))
        #expect(html.contains(##"<a href="#eq-Q-II">(Q-II)</a>/<a href="#eq-Q-III">(Q-III)</a>"##))
        #expect(!html.contains("math-error"))
    }

    @Test("独自の式番号に含まれる特殊文字を整列のタグで文字として刷る")
    func equationTagPunctuation() {
        let html = body(#"\renewcommand\theequation{\{A\%\#\}-\arabic{equation}}\begin{align}x&=1\end{align}"#)
        #expect(html.contains(#"\tag{\{A\%\#\}-1}"#))
        #expect(!html.contains("math-error"))
    }

    @Test("listing の題と番号はキャプションと名前付き参照で一致する")
    func listingFloat() {
        let html = body(#"\begin{listing}\caption{Sample}\label{code}\end{listing}\Cref{code}/\nameref{code}"#)
        #expect(html.contains("Listing 1</span>: Sample"))
        #expect(html.contains(##"<a href="#listing-1">Listing 1</a>/<a href="#listing-1">Sample</a>"##))
    }

    @Test("独自の図表番号をキャプションと参照に使う", arguments: [("figure", "Figure"), ("table", "Table")])
    func captionCounter(example: (String, String)) {
        let (kind, title) = example
        let html = body(
            "\\renewcommand{\\the\(kind)}{S-\\Roman{\(kind)}}\\begin{\(kind)}\\caption{A}\\label{x}\\end{\(kind)}\\ref{x}"
        )
        #expect(html.contains("\(title) S-I</span>"))
        #expect(html.contains(">S-I</a>"))
    }

    @Test("counterwithout は親によるリセットと親番号の接頭辞を外す")
    func counterWithout() {
        let html = body(
            #"""
            \counterwithin{figure}{section}\section{One}\begin{figure}\caption{A}\end{figure}
            \counterwithout{figure}{section}\section{Two}\begin{figure}\caption{B}\end{figure}
            """#)
        #expect(html.contains("Figure 1.1</span>"))
        #expect(html.contains("Figure 2</span>"))
    }

    @Test("番号を振り直しても先のラベルと次のラベルのリンク先が重ならない")
    func repeatedNumberIDs() {
        let html = body(#"\section{One}\label{a}\setcounter{section}{0}\section{Two}\label{b}\ref{a}/\ref{b}"#)
        #expect(html.contains(##"<a href="#sec-1">1</a>/<a href="#sec-1-1">1</a>"##))
    }

    @Test("最初の項目の前と項目の途中で enumerate のカウンターを設定できる")
    func listCounter() {
        let html = body(#"\begin{enumerate}\setcounter{enumi}{4}\item A\setcounter{enumi}{8}\item B\end{enumerate}"#)
        #expect(html.contains(#"<span class="item-label">5.</span>A"#))
        #expect(html.contains(#"<span class="item-label">9.</span>B"#))
    }

    @Test("subequations は親の式を一つ進めて枝番号を付ける")
    func subequations() {
        let html = body(
            #"""
            \setcounter{equation}{2}\begin{subequations}\label{group}
            \begin{equation}a\label{a}\end{equation}\begin{equation}b\label{b}\end{equation}
            \end{subequations}\begin{equation}c\end{equation}\ref{group}/\ref{a}/\ref{b}
            """#)
        #expect(html.contains(#"<span class="eqno">(4)</span>"#))
        #expect(html.contains(##"<a href="#eq-3">3</a>/<a href="#eq-3a">3a</a>/<a href="#eq-3b">3b</a>"##))
    }

    @Test("未宣言の定理・補題環境が独立した番号を持つ")
    func conventionalTheorems() {
        let html = body(#"\begin{theorem}A\end{theorem}\begin{lemma}B\end{lemma}\begin{theorem}C\end{theorem}"#)
        #expect(html.contains(">Theorem 1</span>"))
        #expect(html.contains(">Lemma 1</span>"))
        #expect(html.contains(">Theorem 2</span>"))
    }

    @Test(
        "和文クラスでは英名と和名の定理環境を日本語で刷る",
        arguments: [
            ("theorem", "定理"), ("lemma", "補題"), ("proposition", "命題"), ("corollary", "系"), ("definition", "定義"),
            ("example", "例"), ("remark", "注意"), ("補題", "補題"),
        ])
    func japaneseTheorem(example: (String, String)) {
        let html = body(
            "\\documentclass{jsarticle}\\begin{document}\\begin{\(example.0)}本文\\end{\(example.0)}\\end{document}")
        #expect(html.contains(">\(example.1) 1</span> 本文"))
    }

    @Test("declaretheorem は指定された名前と書式・節ごとの番号・共有する番号を読む")
    func declareTheorem() {
        let html = body(
            #"""
            \documentclass{article}\declaretheorem[name={Main result},numberwithin=section,style=definition]{result}
            \declaretheorem[name=Consequence,sibling=result,style=remark]{fact}
            \begin{document}\section{First}\begin{result}A\end{result}\begin{fact}B\end{fact}
            \section{Second}\begin{fact}C\end{fact}\end{document}
            """#)
        #expect(html.contains(#"class="latex-theorem latex-theorem-definition""#))
        #expect(html.contains(#"class="latex-theorem latex-theorem-remark""#))
        #expect(html.contains(">Main result 1.1</span>"))
        #expect(html.contains(">Consequence 1.2</span>"))
        #expect(html.contains(">Consequence 2.1</span>"))
    }
}

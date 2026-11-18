import SurimonoFormats
import Testing

struct LaTeXMacroTests {
    private func body(_ source: String) -> String {
        LaTeXConverter.convert(source).body
    }

    @Test("前置きの環境は省略値と必須引数を開始コードに渡す")
    func environmentArguments() {
        let html = body(
            #"\newenvironment*{entry}[2][標準]{\begin{quote}#1/#2:}{。\end{quote}}"#
                + #"\begin{document}\begin{entry}{A}本文\end{entry}\end{document}"#)
        #expect(html.contains("<blockquote>\n<p>標準/A:本文。</p>\n</blockquote>"))
    }

    @Test("同じ利用者定義環境を入れ子にできる")
    func nestedEnvironment() {
        let html = body(#"\newenvironment{a}[1]{(#1:}{)}\begin{a}{X}\begin{a}{Y}中\end{a}後\end{a}"#)
        #expect(html == "<p>(X:(Y:中)後)</p>\n")
    }

    @Test("本文で再定義した環境はそこから組み込み環境より優先する")
    func renewBuiltInEnvironment() {
        let html = body(
            #"\begin{quote}前\end{quote}\renewenvironment*{quote}[1][中]{〈#1}{〉}\begin{quote}[後]文\end{quote}"#)
        #expect(html == "<blockquote>\n<p>前</p>\n</blockquote>\n<p class=\"latex-noindent\">〈後文〉</p>\n")
    }

    @Test("区切り付き引数はグループ内の区切りを飛ばし一重の括弧を外す")
    func delimitedDefinition() {
        let html = body(#"\def\pair(#1,#2){#2/#1}\pair({one,two},three)"#)
        #expect(html == "<p>three/one,two</p>\n")
    }

    @Test("制御綴を区切りとする引数を読む")
    func delimiterIsAControlWord() {
        #expect(body(#"\def\until#1\stop{<#1>}\until 中\stop"#) == "<p>&lt;中&gt;</p>\n")
    }

    @Test("let は再定義前の本体と引数の取り方を保存する")
    func letCopiesMeaning() {
        #expect(body(#"\def\a(#1){[#1]}\let\b=\a\def\a{後}\b(前)\a"#) == "<p>[前]後</p>\n")
    }

    @Test("let は元の組み込みコマンドの意味を保存する")
    func letCopiesPrimitive() {
        let html = body(#"\let\strong\textbf\renewcommand\textbf[1]{後}\strong{前}"#)
        #expect(html == "<p><strong>前</strong></p>\n")
    }

    @Test("星付き定義と堅牢な定義を本文で使える")
    func robustCommand() {
        #expect(body(#"\newcommand*\a{甲}\DeclareRobustCommand{\b}[1]{#1乙}\b{\a}"#) == "<p>甲乙</p>\n")
    }

    @Test("既定義のコマンドは providecommand で上書きしない")
    func provide() {
        let html = body(#"\def\a{元}\providecommand{\a}{新}\providecommand{\textbf}[1]{新}\a\textbf{字}"#)
        #expect(html == "<p>元<strong>字</strong></p>\n")
    }

    @Test("xparse の任意引数は省略と空の指定を区別する")
    func xparseMissing() {
        let html = body(
            #"\NewDocumentCommand{\say}{o}{\IfNoValueTF{#1}{省略}{指定}\IfValueTF{#1}{有}{無}}\say/\say[]"#)
        #expect(html == "<p>省略無/指定有</p>\n")
    }

    @Test("xparse の星・省略値・必須引数を指定順に渡す")
    func xparseArgs() {
        let html = body(#"\NewDocumentCommand{\say}{s O{内} m}{\IfBooleanTF{#1}{★}{・}#2#3}\say{甲}/\say*[外]{乙}"#)
        #expect(html == "<p>・内甲/★外乙</p>\n")
    }

    @Test("RenewDocumentCommand は以降の引数の読み方も変える")
    func xparseRedefinition() {
        let html = body(#"\NewDocumentCommand\a{m}{<#1>}\a{A}\RenewDocumentCommand\a{s}{\IfBooleanTF{#1}{B}{C}}\a*"#)
        #expect(html == "<p>&lt;A&gt;B</p>\n")
    }

    @Test("xparse 環境は前置きで定義した引数仕様を使う")
    func xparseEnvironment() {
        let html = body(
            #"\NewDocumentEnvironment{book}{O{既定} m}{[#1:#2]}{終}\begin{document}\begin{book}{題}文\end{book}\end{document}"#
        )
        #expect(html == "<p>[既定:題]文終</p>\n")
    }

    @Test("csname は組み立てたコマンド名から引数付きマクロを呼ぶ")
    func constructedName() {
        #expect(body(#"\def\prefix{tw}\def\two#1{#1#1}\csname\prefix o\endcsname{文}"#) == "<p>文文</p>\n")
    }

    @Test("csname で定義した名前は数字を含んでもその名前で引ける")
    func defineConstructedName() {
        #expect(body(#"\expandafter\def\csname entry1\endcsname#1{:#1:}\csname entry1\endcsname{語}"#) == "<p>:語:</p>\n")
    }

    @Test("引数を差し込んでも制御綴の前後にある英字は別のトークンのまま")
    func parameterTokenBoundaries() {
        let html = body(#"\def\word{A}\def\both#1#2{\word#1#2x}\both{B}{\word}"#)
        #expect(html == "<p>ABAx</p>\n")
    }

    @Test("任意引数に書いた NoValue の文字は省略と見なさない")
    func literalMissingArgument() {
        let html = body(#"\NewDocumentCommand\a{o}{\IfNoValueTF{#1}{省略}{指定}}\a[-NoValue-]"#)
        #expect(html == "<p>指定</p>\n")
    }

    @Test("環境で開いた書体と定義は環境の末尾で閉じる")
    func scopedEnvironment() {
        let html = body(#"\def\a{外}\newenvironment{x}{\bfseries\def\a{内}}{}\a\begin{x}\a\end{x}\a"#)
        #expect(html == "<p>外<strong>内</strong>外</p>\n")
    }

    @Test("let はエスケープした記号の意味を保存する")
    func controlSymbolAlias() {
        #expect(body(#"\let\pct=\%\pct"#) == "<p>%</p>\n")
    }

    @Test("読み取れる箱のコマンドは定義済みの分岐に入る")
    func builtinDefinition() {
        #expect(body(#"\ifdefined\resizebox 読む\else 読まない\fi"#) == "<p>読む</p>\n")
    }

    @Test("数式中の xparse コマンドは星と任意引数を判定してから描く")
    func xparseMath() {
        let html = body(
            #"\NewDocumentCommand\term{s o m}{\IfBooleanTF{#1}{-}{+}\IfNoValueTF{#2}{1}{#2}#3}$\term*[2]{x}\term{y}$"#)
        #expect(html.contains(#"aria-label="-2x+1y""#))
        #expect(!html.contains("math-error"))
    }

    @Test("通常のマクロを経由した数式中の xparse 定義も読む")
    func xparseMathViaDefinition() {
        let html = body(#"\def\wrap#1{\term{#1}}\NewDocumentCommand\term{m}{#1^2}$\wrap{x}$"#)
        #expect(html.contains(#"aria-label="x^2""#))
    }

    @Test("数式用の環境は本文と開始・終了コードを数式として描く")
    func xparseMathEnvironment() {
        let html = body(#"\NewDocumentEnvironment{bracket}{m}{\left(#1+}{\right)}$\begin{bracket}{1}x\end{bracket}$"#)
        #expect(html.contains(#"aria-label="\left(1+x\right)""#))
    }

    @Test("拡張定義を含む文書でも使わない数式の原文と SwaTex のマクロを保つ")
    func untouchedMath() {
        let html = body(#"\NewDocumentCommand\myterm{m}{#1}\def\R{\mathbb{R}}$\text{Cost }\$5,\quad x\in\R$"#)
        #expect(html.contains(#"aria-label="\text{Cost }\$5,\quad x\in\R""#))
        #expect(!html.contains("math-error"))
    }

    @Test("数式中では共有カウンターの現在値を指定形式で読む")
    func explicitMathCounter() {
        let html = body(#"\newcounter{x}\setcounter{x}{2}$\alpha\Roman{x}+\value{x}+\thex$"#)
        #expect(html.contains(#"aria-label="\alpha II+2+2""#))
        #expect(!html.contains("math-error"))
    }

    @Test("式中の式番号はその式に振った番号になる")
    func currentEquationCounter() {
        let html = body(
            #"\setcounter{equation}{2}\renewcommand\theequation{Q\arabic{equation}}\begin{equation}x=\theequation\end{equation}"#
        )
        #expect(html.contains(#"aria-label="x=Q3""#))
    }

    @Test("align の各行の式中でその行のカウンター値を使う")
    func rowCountersInMath() {
        let html = body(#"\begin{align}x&=\theequation\\y&=\theequation\end{align}"#)
        #expect(html.contains(#"x&amp;=1\\y&amp;=2"#))
    }

    @Test("数式用の番号を読むときは書式に紛れたカウンター代入を実行しない")
    func mathCounterDoesNotExecuteAssignments() {
        let html = body(#"\newcounter{x}\renewcommand\thex{\stepcounter{x}\arabic{x}}$\thex$ 最後=\arabic{x}"#)
        #expect(html.contains("最後=0"))
    }

    @Test("数式環境でも選ばれなかったマクロ引数のラベルを登録しない")
    func discardedMathLabel() {
        let html = body(
            #"\NewDocumentCommand\pick{s m m}{\IfBooleanTF{#1}{#2}{#3}}"#
                + #"\begin{equation}\pick*{x\label{hit}}{y\label{miss}}\end{equation}"#
                + #"\ref{hit}/\ref{miss}"#)
        #expect(
            html.contains(##"<a class="latex-number-ref" href="#eq-1">1</a>/<span class="latex-missing">??</span>"##))
    }

    @Test("数式中の自己参照も本文と同じ展開上限で止まる", .timeLimit(.minutes(1)))
    func xparseMathBudget() {
        let fragment = LaTeXConverter.convert(#"\NewDocumentCommand\a{}{\a}$x+\a$後"#)
        #expect(fragment.readingIssues == ["LaTeX expansion limit reached"])
        #expect(fragment.body.contains("後"))
    }

    @Test("自己呼び出しは上限で止まり本文と一件の警告を残す", .timeLimit(.minutes(1)))
    func recursionBudget() {
        let fragment = LaTeXConverter.convert(#"前\def\a{\a}\a 後"#)
        #expect(fragment.body == "<p>前後</p>\n")
        #expect(fragment.readingIssues == ["LaTeX expansion limit reached"])
    }
}

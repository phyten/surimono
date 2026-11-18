import Testing

@testable import SurimonoFormats

struct LaTeXControlTests {
    private func body(_ source: String) -> String { LaTeXConverter.convert(source).body }

    @Test("定義内と未採用の枝にある文書境界は本文を開始・終了しない")
    func documentBoundaries() {
        let source =
            #"\def\fake{\begin{document}}\iffalse\begin{document}\fi\begin{document}A\iffalse\end{document}\fi B\end{document}C"#
        #expect(body(source) == "<p>AB</p>\n")
    }

    @Test("プリミティブ条件の採用した枝だけが定義や本文を変更できる")
    func branches() {
        let source = #"\iftrue A\iffalse BAD\else B\fi\else\def\word{BAD}\fi\ifdefined\word BAD\else C\fi"#
        #expect(body(source) == "<p>ABC</p>\n")
    }

    @Test(
        "条件名を比較・定義する枝と内部のループは外側の条件を閉じない",
        arguments: [
            #"\iftrue\ifdefined\ifLuaTeX A\fi\else BAD\fi"#,
            #"\iftrue\newif\ifdraft\drafttrue\ifdraft A\fi\else BAD\fi"#,
            #"\iftrue\loop A\iffalse\repeat\else BAD\fi"#,
        ])
    func structuralTokens(_ source: String) {
        #expect(body(source) == "<p>A</p>\n")
    }

    @Test("採用した枝の末尾のコマンドは条件の外の引数を読める")
    func followingArgument() {
        #expect(body(#"\iftrue\textbf\else\textit\fi{Paper}"#) == "<p><strong>Paper</strong></p>\n")
    }

    @Test("if はマクロを展開した文字を比較する")
    func characterTokens() {
        #expect(body(#"\def\a{A}\def\b{B}\if\a\b BAD\else YES\fi"#) == "<p>YES</p>\n")
    }

    @Test("ifx はトークンまたはマクロの定義を比較する")
    func meanings() {
        let source = #"\def\a#1{#1!}\def\b#1{#1!}\ifx\a\b A\fi\ifx az BAD\else B\fi"#
        #expect(body(source) == "<p>AB</p>\n")
    }

    @Test("ifcsname は名前で定義を探す")
    func dynamicName() {
        #expect(body(#"\def\test{!}\ifcsname test\endcsname YES\else NO\fi"#) == "<p>YES</p>\n")
    }

    @Test("ifnum は符号付き整数とカウンター値を比較する")
    func integers() {
        #expect(body(#"\setcounter{section}{3}\ifnum\value{section}>-2 YES\else NO\fi"#) == "<p>YES</p>\n")
    }

    @Test("ifodd は負の奇数にも真になる")
    func odd() {
        #expect(body(#"\ifodd-3 YES\else NO\fi"#) == "<p>YES</p>\n")
    }

    @Test("ifdim は長さを共通の単位で比較する")
    func lengths() {
        #expect(body(#"\ifdim 1cm<11mm YES\else NO\fi"#) == "<p>YES</p>\n")
    }

    @Test("ifcase はゼロ始まりの枝を選び、範囲外では else を読む")
    func cases() {
        #expect(body(#"\ifcase1 A\or B\or C\fi\ifcase-1 A\or B\else D\fi"#) == "<p>BD</p>\n")
    }

    @Test("newif のスイッチは前置きと本文にまたがって有効になる")
    func switchDefinition() {
        let source =
            #"\newif\ifdraft\drafttrue\ifdraft\def\word{YES}\fi\begin{document}\word\draftfalse\ifdraft NO\fi\end{document}"#
        #expect(body(source) == "<p>YES</p>\n")
    }

    @Test("エンジン判定は LuaTeX の枝を選ぶ", arguments: ["ifpdf", "ifxetex", "ifluatex", "ifPDFTeX", "ifXeTeX", "ifLuaTeX"])
    func engine(_ name: String) {
        #expect(
            body("\\\(name) YES\\else NO\\fi") == (name.lowercased() == "ifluatex" ? "<p>YES</p>\n" : "<p>NO</p>\n"))
    }

    @Test("ifthen の括弧で結合した条件は未採用の枝を読み飛ばす")
    func logicalTest() {
        let source =
            #"\newboolean{x}\setboolean{x}{true}\ifthenelse{\boolean{x}\and\not\(\isodd{2}\or\equal{a}{b}\)}{YES}{NO}"#
        #expect(body(source) == "<p>YES</p>\n")
    }

    @Test(
        "etoolbox の名前・文字列・数・論理値を判定する",
        arguments: [
            #"\newbool{x}\booltrue{x}\ifbool{x}"#, #"\newbool{x}\notbool{x}"#,
            #"\newbool{x}\setbool{x}{true}\ifbool{x}"#, #"\newtoggle{x}\toggletrue{x}\iftoggle{x}"#,
            #"\newtoggle{x}\togglefalse{x}\nottoggle{x}"#, #"\def\foo{}\ifdef\foo"#,
            #"\ifundef\absent"#, #"\def\foo{}\ifcsdef{foo}"#, #"\ifstrequal{a}{a}"#,
            #"\ifstrempty{}"#, #"\ifblank{  }"#, #"\ifnumequal{1}{1}"#,
            #"\ifnumgreater{2}{1}"#, #"\ifnumless{-1}{0}"#, #"\def\foo{}\ifdefempty\foo"#,
        ])
    func predicates(_ start: String) {
        #expect(body(start + "{YES}{NO}") == "<p>YES</p>\n")
    }

    @Test("foreach はリストと範囲を読み、反復が終わると同名の変数を戻す")
    func foreachLoop() {
        let source = #"\def\x{Z}\foreach \x in {a,b}{\x}\foreach \x in {0,2,...,6}{\x}\x"#
        #expect(body(source) == "<p>ab0246Z</p>\n")
    }

    @Test("foreach の小数の範囲は刻みが終点に達するまで読む")
    func decimalRange() {
        #expect(body(#"\foreach \x in {0,0.1,...,0.3}{[\x]}"#) == "<p>[0][0.1][0.2][0.3]</p>\n")
    }

    @Test("foreach の複数変数と入れ子は外側の変数を保持する")
    func nestedLoop() {
        let source = #"\foreach \x/\y in {a/b,c/d}{\x\foreach \x in {1,...,2}{\x}\y}"#
        #expect(body(source) == "<p>a12bc12d</p>\n")
    }

    @Test("ループ内の数式は内側と外側の変数を使い、その後に定義が戻る")
    func mathVariables() {
        let html = body(#"\def\x{7}\foreach\x in {2}{\foreach\x in {3}{$\x$}$\x$}$\x$"#)
        #expect(!html.contains("math-error"))
        #expect(html.contains(">3</text>"))
        #expect(html.contains(">2</text>"))
        #expect(html.contains(">7</text>"))
    }

    @Test("後方の参照を持つ数式も反復当時の変数で描く")
    func deferredMathVariables() {
        let html = body(#"\foreach\x in {7,8}{$\x+\ref{s}$}\section{Later}\label{s}"#)
        #expect(!html.contains("math-error"))
        #expect(html.contains(">7</text>"))
        #expect(html.contains(">8</text>"))
    }

    @Test("loop は条件の前を毎回読み、真の場合だけ残りを繰り返す")
    func plainLoop() {
        let source = #"\newcounter{n}\loop\stepcounter{n}\arabic{n}\ifnum\value{n}<3 +\repeat"#
        #expect(body(source) == "<p>1+2+3</p>\n")
    }

    @Test("whiledo は本文で更新した値を次の条件に使う")
    func whileLoop() {
        #expect(body(#"\whiledo{\value{section}<3}{\stepcounter{section}\arabic{section}}"#) == "<p>123</p>\n")
    }

    @Test("multido は初期値と増分を各反復の変数に渡す")
    func multido() {
        #expect(body(#"\multido{\i=1+2}{3}{\i}"#) == "<p>135</p>\n")
    }

    @Test("forloop は指定したカウンターと増分でテストを繰り返す")
    func forloop() {
        #expect(body(#"\forloop[2]{section}{1}{\value{section}<7}{\arabic{section}}"#) == "<p>135</p>\n")
    }

    @Test(
        "終了しないループと巨大な範囲は制限内で止まり、後続の本文が残る", .timeLimit(.minutes(1)),
        arguments: [
            #"\loop\iftrue\repeat"#, #"\foreach\x in {1,...,1000000}{X}"#, #"\whiledo{1=1}{}"#,
            #"\multido{\i=0+1}{1000000}{}"#, #"\forloop[0]{section}{0}{\value{section}<1}{}"#,
        ])
    func limits(_ loop: String) {
        let result = LaTeXConverter.convert("START" + loop + " END")
        #expect(result.body.contains("START"))
        #expect(result.body.contains("END"))
        #expect(result.readingIssues == ["LaTeX expansion limit reached"])
    }
}

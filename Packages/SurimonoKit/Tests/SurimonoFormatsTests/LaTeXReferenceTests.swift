import Foundation
import SurimonoFormats
import Testing

struct LaTeXReferenceTests {
    private let figures = (1...3).map { "\\begin{figure}\\caption{Plate \($0)}\\label{f\($0)}\\end{figure}" }.joined()

    private func printed(_ source: String, japanese: Bool = false) -> String {
        let body = LaTeXConverter.convert(
            "\\documentclass{\(japanese ? "jsarticle" : "article")}\\begin{document}\(source)\\end{document}"
        ).body
        return body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    @Test("斜体の定理から節・表を指す番号は立体、見出しの名前とリンクの指定文字は本文の書体を使う")
    func uprightCounterReferences() {
        let html = LaTeXConverter.convert(
            #"\section{Topic}\label{s}\begin{table}\caption{Data}\label{t}\end{table}\begin{theorem}\ref{s}/\ref{t}/\nameref{s}/\hyperref[t]{custom}\end{theorem}"#
        ).body
        #expect(
            html.contains(
                ##"<a class="latex-number-ref" href="#sec-1">1</a>/<a class="latex-number-ref" href="#tab-1">1</a>/<a href="#sec-1">Topic</a>/<a href="#tab-1">custom</a>"##
            ))
    }

    @Test("欧文の図への参照には種類と単数・複数・範囲を付ける")
    func englishFigures() {
        let source = #"\cref{f1};\Cref{f1,f2};\crefrange{f1}{f3};\namecref{f1};\labelcref{f1,f2}"# + figures
        #expect(printed(source).contains("figure 1;Figures 1 and 2;figures 1 to 3;figure;1 and 2"))
    }

    @Test("和文では図の番号を中黒と波線で結ぶ")
    func japaneseFigures() {
        let source = #"\cref{f1};\Cref{f1,f2};\crefrange{f1}{f3}"# + figures
        #expect(printed(source, japanese: true).contains("図 1;図 1・2;図 1〜3"))
    }

    @Test("節・表・式は和文文書クラスの名称を使う")
    func japaneseKinds() {
        let source =
            #"\vref{s};\autoref{t};\cref{e}\section{題}\label{s}\begin{table}\caption{名}\label{t}\end{table}\begin{equation}a\label{e}\end{equation}"#
        #expect(printed(source, japanese: true).contains("第 1 節;表 1;式 (1)"))
    }

    @Test("名称の再定義は小文字・大文字・autoref を区別する")
    func customNames() {
        let source =
            #"\crefname{figure}{plate}{plates}\Crefname{figure}{PLATE}{PLATES}\renewcommand\figureautorefname{Illustration}\cref{f1};\Cref{f1,f2};\autoref{f3}"#
        #expect(printed(source + figures).contains("plate 1;PLATES 1 and 2;Illustration 3"))
    }

    @Test("参照名は参照を書いた位置で有効な名前を使う")
    func namesAtUse() {
        let source =
            #"\autoref{f1}/\cref{f1};\renewcommand\figureautorefname{Plate}\crefname{figure}{drawing}{drawings}\autoref{f1}/\cref{f1}"#
        #expect(printed(source + figures).contains("Figure 1/figure 1;Plate 1/drawing 1"))
    }

    @Test("見出しと図題の中のラベルを nameref で前方参照できる")
    func namedTargets() {
        let source =
            #"\nameref{s}/\nameref{f}\section{A \emph{heading}\label{s}}\begin{figure}\caption{A plate\label{f}}\end{figure}"#
        #expect(printed(source).contains("A heading/A plate"))
    }

    @Test("見出し内の参照番号も nameref に現れ、リンクは入れ子にならない")
    func referenceInsideTitle() {
        let html = LaTeXConverter.convert(#"\nameref{b}\section{First}\label{a}\section{After \ref{a}}\label{b}"#).body
        #expect(html.contains(##"<a href="#sec-2">After 1</a>"##))
        #expect(!html.contains("\u{E000}"))
    }

    @Test("自分を指す見出し名の参照は未確定の印で止まる", .timeLimit(.minutes(1)))
    func cyclicTitle() {
        let html = LaTeXConverter.convert(#"\section{\nameref{x}}\label{x}"#).body
        #expect(html.contains("??"))
        #expect(!html.contains("\u{E000}"))
    }

    @Test("pageref は対象番号にページ参照のクラスを添える")
    func pageReference() {
        let html = LaTeXConverter.convert(#"\pageref{s}\section{Title}\label{s}"#).body
        #expect(html.contains(##"<a class="latex-pageref" href="#sec-1">1</a>"##))
    }

    @Test(
        "番号なしの数式内のラベルを式から取り出しリンクにする",
        arguments: [
            #"\[x\label{display}\]"#, #"$x\label{display}$"#, #"\begin{equation*}x\label{display}\end{equation*}"#,
        ])
    func unnumberedFormula(_ source: String) {
        let html = LaTeXConverter.convert(#"\section{One}"# + source + #"\eqref{display}"#).body
        #expect(!html.contains("math-error"))
        #expect(!html.contains(#"\label"#))
        #expect(html.contains("id=\"eq-t1\""))
        #expect(html.contains("<a class=\"latex-number-ref\" href=\"#eq-t1\">(1)</a>"))
    }

    @Test("式中で前方参照した番号を数式の文字として組む")
    func referenceInFormula() {
        let html = LaTeXConverter.convert(#"$x=\ref{e},y=\eqref{e}$\begin{equation}z\label{e}\end{equation}"#).body
        #expect(!html.contains("math-error"))
        #expect(html.contains(#"\text{1},y=\text{(1)}"#))
    }

    @Test("hyperref はラベルのリンク先に指定した文字を置く")
    func linkedLabel() {
        let html = LaTeXConverter.convert(#"\hyperref[s]{See \emph{here}}\section{Test}\label{s}"#).body
        #expect(html.contains("<a href=\"#sec-1\">See <em>here</em></a>"))
    }

    @Test("hypertarget と hyperlink は同じ名前のリンクで結ぶ")
    func linkPair() {
        let html = LaTeXConverter.convert(#"\hyperlink{spot}{go}\hypertarget{spot}{land}"#).body
        #expect(html.contains("<a href=\"#spot\">go</a><span id=\"spot\">land</span>"))
    }
}

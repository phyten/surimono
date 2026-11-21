import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXListingTests {
    @Test("コードの文字サイズを指定しても検索できるように語の中の字送りを保つ")
    func searchableTypewriterSize() {
        for size in ["small", "footnotesize"] {
            let html = LaTeXConverter.convert(
                #"""
                \documentclass{article}\begin{document}
                \begin{lstlisting}[basicstyle=\\#(size)\ttfamily]
                ABC
                \end{lstlisting}\end{document}
                """#
            ).body
            #expect(html.contains("ABC</code>"))
            #expect(!html.contains("latex-fixed-columns"))
            #expect(!html.contains("--latex-listing-column"))
            #expect(html.contains("--latex-listing-design-size: var(--latex-size-\(size))"))
        }
    }

    @Test("基本書体だけを名前付きの listings スタイルで指定したら本文も行内コードもトークンを色付けしない")
    func basicStyleWithoutTokenStyles() {
        let html = LaTeXConverter.convert(
            #"""
            \lstdefinestyle{mono}{basicstyle=\small\ttfamily,numbers=left}
            \lstset{style=mono,language=Python}
            \begin{lstlisting}
            if True: print("red") # note
            \end{lstlisting}
            \lstinline|return 12|
            """#
        ).body
        #expect(html.contains(#"class="code-line" data-no="1""#))
        #expect(html.contains("latex-styled-listing"))
        #expect(html.contains(#"<span class="hl-comment"># note</span>"#))
        #expect(html.contains("--latex-comment-shape: italic"))
        #expect(!html.contains("hl-keyword") && !html.contains("hl-string"))
        #expect(html.contains("return 12</code>"))
    }

    @Test("前置きのスタイルを次のリストへ適用しその場の言語指定は次へ持ち越さない")
    func defaultsAndLocalOverrides() {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{article}
            \lstdefinestyle{base}{language=R,numbers=left}
            \lstdefinestyle{numbered}{style=base,firstnumber=7}
            \lstset{style=numbered}
            \begin{document}
            \begin{lstlisting}[language=Python,caption={Test, \emph{one}},label={code:first}]
            def f():
                return 2
            \end{lstlisting}
            \begin{lstlisting}
            function(x) x
            \end{lstlisting}
            \ref{code:first}
            \end{document}
            """#)
        #expect(fragment.readingIssues.isEmpty)
        #expect(fragment.body.contains(#"class="language-python hl""#))
        #expect(fragment.body.contains(#"<span class="hl-keyword">def</span>"#))
        #expect(fragment.body.contains(#"class="language-r hl""#))
        #expect(fragment.body.contains(#"<span class="hl-keyword">function</span>"#))
        #expect(fragment.body.contains(#"data-no="7""#))
        #expect(fragment.body.contains(#"data-no="8""#))
        #expect(fragment.body.contains("Test, <em>one</em>"))
        #expect(fragment.body.contains(##"<a class="latex-number-ref" href="#listing-1">1</a>"##))
    }

    @Test("minted の行番号と開始番号を読み複数行のコメントを両方の行で色付けする")
    func numberedMinted() {
        let html = LaTeXConverter.convert(
            #"""
            \begin{minted}[linenos,firstnumber=42]{haskell}
            {- one
               two -}
            \end{minted}
            """#
        ).body
        #expect(html.contains(#"data-no="42"><span class="code-src"><span class="hl-comment">{- one</span>"#))
        #expect(html.contains(#"data-no="43"><span class="code-src"><span class="hl-comment">   two -}</span>"#))
    }

    @Test("ファイルからのコードは指定した読み取り口を使い欠けたファイルを知らせる")
    func fileListings() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("function f()\n".utf8).write(to: folder.appending(path: "source.m"))
        let fragment = LaTeXConverter.convert(
            #"""
            \lstinputlisting[language=matlab,caption={Source},label={code:m}]{source.m}
            \inputminted[linenos,firstnumber=5]{julia}{source.m}
            \inputminted{r}{missing.r}
            """#, directory: folder, readFile: { try? Data(contentsOf: $0) })
        #expect(fragment.body.contains(#"class="language-matlab hl""#))
        #expect(fragment.body.contains(#"class="language-julia hl""#))
        #expect(fragment.body.contains(#"data-no="5""#))
        #expect(fragment.body.contains("missing.r"))
        #expect(!fragment.readingIssues.isEmpty)
    }

    @Test("インラインの言語指定で色付けし verb と未知の言語はコードをそのまま保つ")
    func highlightedInline() {
        let fragment = LaTeXConverter.convert(
            #"""
            \lstset{language=R}\lstinline|function(x)| \verb|if < x|
            \mintinline{haskell}{let x = 42} \lstinline[language=unknown]!if < x!
            \textbf{\mintinline{matlab}{% example}} after
            \begin{itemize}\item \lstinline [language=TeX]|\item|\item next\end{itemize}
            """#)
        #expect(fragment.readingIssues.isEmpty)
        #expect(fragment.body.contains(#"<code class="language-r hl"><span class="hl-keyword">function</span>"#))
        #expect(fragment.body.contains(#"<code class="language-haskell hl"><span class="hl-keyword">let</span>"#))
        #expect(fragment.body.components(separatedBy: "<code>if &lt; x</code>").count == 3)
        #expect(fragment.body.contains(#"<span class="hl-comment">% example</span></code></strong> after"#))
        #expect(fragment.body.contains(#"<span class="hl-keyword">\item</span>"#))
        #expect(fragment.body.contains("<li><span class=\"latex-item-mark\">•</span>next</li>"))
    }

    @Test("listings の枠と字の大きさ・色・折り返しは指定したコードだけに適用する")
    func sourceAppearance() {
        let result = LaTeXConverter.convert(
            #"""
            \definecolor{ink}{HTML}{304050}
            \lstset{language=Python,frame=single,basicstyle=\ttfamily\small,breaklines,
              keywordstyle=\color{blue}\bfseries,commentstyle=\color{ink},stringstyle=\color{red!60!black}}
            \begin{lstlisting}
            if "str": # comment
            \end{lstlisting}
            \lstinline|if 1|
            \begin{lstlisting}[frame=tb,basicstyle=\footnotesize]
            pass
            \end{lstlisting}
            \begin{lstlisting}[frame=lines]2\end{lstlisting}
            \begin{verbatim}
                keep spaces
            \end{verbatim}
            """#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("latex-frame-single latex-wrap-code latex-sized-code"))
        #expect(result.body.components(separatedBy: "latex-frame-lines").count == 3)
        #expect(result.body.contains("--latex-code-size: 0.9em"))
        #expect(result.body.contains("--latex-code-size: 0.8em"))
        #expect(result.body.contains("--latex-keyword-ink: #0000ff; --latex-keyword-weight: bold"))
        #expect(result.body.contains("--latex-comment-ink: #304050"))
        #expect(result.body.contains("--latex-string-ink: #990000"))
        #expect(result.body.contains("class=\"latex-inline-listing latex-styled-listing\""))
        #expect(result.body.contains("<div class=\"latex-verbatim\"><pre><code>    keep spaces</code></pre>"))
    }

    @Test("PythonからCに変えても指定した色と太字だけを引き継ぎ、枠外の番号の大きさと色を個別に変えられる")
    func tokenAndNumberStyles() {
        let fragment = LaTeXConverter.convert(
            #"""
            \lstset{language=Python,basicstyle=\color{black},keywordstyle=\color{blue}\bfseries,
              commentstyle=\color{gray}\itshape,stringstyle=\color{red},numbers=left,numberstyle=\tiny}
            \begin{lstlisting}[frame=single]
            if print(2): # first
            \end{lstlisting}
            \begin{lstlisting}[language=C,numberstyle=\scriptsize\color{blue}]
            #include <stdio.h>
            int main(void) { printf("test"); return 7; }
            \end{lstlisting}
            \lstinline[language=C]|int x = 3;|
            """#)
        #expect(fragment.readingIssues.isEmpty)
        #expect(fragment.body.contains("--latex-number-size: var(--latex-number-tiny, 0.5em)"))
        #expect(
            fragment.body.contains(
                "--latex-number-size: var(--latex-number-scriptsize, 0.7em); --latex-number-ink: #0000ff"))
        #expect(fragment.body.contains("--latex-code-ink: #000000"))
        #expect(fragment.body.components(separatedBy: "--latex-keyword-weight: bold").count == 4)
        #expect(fragment.body.contains("--latex-comment-shape: italic"))
        #expect(fragment.body.contains(#"<span class="hl-keyword">if</span> print(2)"#))
        #expect(fragment.body.contains(#"<span class="hl-keyword">#include</span> &lt;stdio.h&gt;"#))
        #expect(
            fragment.body.contains(#"<span class="hl-keyword">int</span> main(<span class="hl-keyword">void</span>)"#))
        #expect(fragment.body.contains(#"printf(<span class="hl-string">&quot;test&quot;</span>)"#))
        #expect(fragment.body.contains(#"<span class="hl-keyword">return</span> 7"#))
        #expect(fragment.body.contains(#"<span class="hl-keyword">int</span> x = 3;"#))
        #expect(!fragment.body.contains("hl-number") && !fragment.body.contains("hl-function"))
        #expect(!fragment.body.contains("hl-builtin"))
    }

    @Test("自分を指すリストのスタイルは展開上限で止まり後続の本文を読める")
    func recursiveStyleIsBounded() {
        let fragment = LaTeXConverter.convert(
            #"\lstdefinestyle{cycle}{style=cycle}\lstset{style=cycle}after"#)
        #expect(fragment.readingIssues.contains("LaTeX expansion limit reached"))
        #expect(fragment.body.contains("after"))
    }
}

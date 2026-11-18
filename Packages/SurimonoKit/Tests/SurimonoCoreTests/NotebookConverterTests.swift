import Foundation
import Testing

@testable import SurimonoCore

struct NotebookConverterTests {
    func notebook(_ cells: [[String: Any]], metadata: [String: Any] = [:]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "nbformat": 4, "nbformat_minor": 5,
            "metadata": metadata, "cells": cells,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    func output(_ data: [String: Any], metadata: [String: Any] = [:]) throws -> String {
        try NotebookConverter.convert(
            notebook([
                [
                    "cell_type": "code", "source": "",
                    "outputs": [["output_type": "display_data", "data": data, "metadata": metadata]],
                ]
            ])
        ).body
    }

    @Test("別セルへの見出しリンクを解決し同じセルの重複見出しを優先する")
    func crossCellLinks() throws {
        let html = try NotebookConverter.convert(
            notebook([
                ["cell_type": "markdown", "source": "[later](#later)\n\n# Same"],
                ["cell_type": "markdown", "source": "## Later\n\n# Same\n\n[local](#same)"],
            ])
        ).body
        #expect(html.contains("href=\"#nb-2-later\""))
        #expect(html.contains("href=\"#nb-2-same\""))
    }

    @Test("HTMLの一部に描けない埋め込みがあれば静的な本文と注記を両方残す")
    func mixedHTML() throws {
        let html = try output(["text/html": "<p>Saved text</p><canvas></canvas>"])
        #expect(html.contains("Saved text"))
        #expect(html.contains("notebook-note"))
        #expect(!html.contains("<canvas"))
    }

    @Test("全テーマでNotebookのコード枠と非表示でない見出しを保持する")
    func themes() throws {
        let fragment = try NotebookConverter.convert(
            notebook(
                [
                    ["cell_type": "markdown", "source": "# Title\n\n## Section"],
                    ["cell_type": "code", "source": "print(1)"],
                ], metadata: ["language_info": ["name": "python"]]))
        for theme in try PrintThemeLibrary.load() {
            let html = HTMLDocumentBuilder.build(
                fragment: fragment, format: .notebook, theme: theme,
                code: CodeStyle(block: .init(lineNumbers: .all, languageLabel: .corner)))
            #expect(html.contains("surimono format-notebook"))
            #expect(html.contains("code-block"))
            #expect(html.contains("code-line"))
            #expect(!fragment.body.contains("secnum"))
        }
    }

    @Test("Notebook判定でも手動選択と毎回確認と自動判定の除外を尊重する")
    func clipboardSettings() throws {
        let source = try notebook([])
        #expect(
            ClipboardFormatDetector.detect(source, settings: .init(mode: .alwaysAsk)).action
                == .ask(preferred: .notebook))
        #expect(
            ClipboardFormatDetector.detect(source, settings: .init(mode: .fixed, fixedKind: .markdown)).action
                == .open(.markdown))
        let disabled = ClipboardFormatDetector.detect(source, settings: .init(automaticKinds: [.markdown]))
        #expect(disabled.action == .open(.plainText))
        #expect(disabled.choices.count == ClipboardTextKind.allCases.count)
        #expect(ClipboardContent.fileExtension(of: Data(source.utf8), format: .notebook) == "ipynb")
    }

    @Test("第4版の各minor版を読み未知のセルと出力は枠で示す", arguments: 0...5)
    func versions(_ minor: Int) throws {
        let source = #"{"nbformat":4,"nbformat_minor":\#(minor),"cells":[{"cell_type":"future","source":"x"}]}"#
        #expect(try NotebookConverter.convert(source).body.contains("notebook-note"))
    }

    @Test("各画像MIMEとテキストMIMEの優先順が固定される")
    func priorities() throws {
        let mimes = [
            "image/png", "image/jpeg", "image/gif", "image/svg+xml", "text/html", "text/markdown", "text/latex",
            "text/plain",
        ]
        let values = ["UE5H", "SlBFRw==", "R0lG", "<svg></svg>", "<b>HTML</b>", "**MARKDOWN**", "$x$", "PLAIN"]
        for index in mimes.indices {
            let data = Dictionary(
                uniqueKeysWithValues: mimes.indices.filter { $0 >= index }.map { (mimes[$0], values[$0] as Any) })
            let html = try output(data)
            if index < 4 {
                #expect(html.contains("data:" + mimes[index]))
            } else if index == 4 {
                #expect(html.contains("<b>HTML</b>"))
            } else if index == 5 {
                #expect(html.contains("<strong>MARKDOWN</strong>"))
            } else if index == 6 {
                #expect(html.contains("math-inline"))
            } else {
                #expect(html.contains("PLAIN"))
            }
            if index < 7 { #expect(!html.contains("PLAIN")) }
        }
    }

    @Test("stderrと例外は区別しANSIなしで保存した内容を残す")
    func errorsAndStreams() throws {
        let result = try NotebookConverter.convert(
            notebook([
                [
                    "cell_type": "code", "source": "",
                    "outputs": [
                        ["output_type": "stream", "name": "stderr", "text": ["warn", "ing"]],
                        [
                            "output_type": "error", "ename": "ValueError", "evalue": "bad",
                            "traceback": ["\u{1B}[31mframe\u{1B}[0m", "last"],
                        ],
                    ],
                ]
            ]))
        #expect(result.body.contains("notebook-stderr"))
        #expect(result.body.contains("warning"))
        #expect(result.body.contains("notebook-error"))
        #expect(result.body.contains("ValueError: bad\nframe\nlast"))
        #expect(!result.body.contains("\u{1B}"))
    }

    @Test("カーネルの言語を代替にし入力の非表示設定に従う")
    func metadata() throws {
        let result = try NotebookConverter.convert(
            notebook(
                [
                    ["cell_type": "code", "source": "print(1)"],
                    ["cell_type": "code", "source": "SECRET", "metadata": ["jupyter": ["source_hidden": true]]],
                ], metadata: ["kernelspec": ["language": "python"]]))
        #expect(result.body.contains("language-python hl"))
        #expect(!result.body.contains("SECRET"))
        #expect(result.title == nil)
    }

    @Test("日本語の文書では対話型出力の注記も日本語になる")
    func localizedNote() throws {
        let result = try NotebookConverter.convert(
            notebook([
                ["cell_type": "markdown", "source": "# 実験の結果です"],
                [
                    "cell_type": "code", "source": "",
                    "outputs": [["output_type": "display_data", "data": ["application/javascript": "alert(1)"]]],
                ],
            ]))
        #expect(result.body.contains("対話型の出力は紙に表示できません"))
    }

    @Test("不完全な構造を黙って空の文書にしない")
    func invalidStructure() {
        for text in ["[]", "{}", #"{"nbformat":true,"cells":[]}"#, #"{"nbformat":4,"cells":[{}]}"#] {
            #expect(throws: NotebookError.invalidStructure) { try NotebookConverter.convert(text) }
        }
    }

    @Test("画像の自然寸法と2倍を超えない上限を保持する")
    func imageSize() {
        let image = NotebookImage(mime: "image/svg+xml", source: #"<svg width="30" height="20"></svg>"#)
        #expect(image.html(metadata: [:]).contains("width:30px"))
        #expect(image.html(metadata: ["width": 300]).contains("width:60px"))
    }

    @Test("Markdownの数式と囲みと脚注をセル内で変換する")
    func extensions() throws {
        let html = try NotebookConverter.convert(
            notebook([
                [
                    "cell_type": "markdown",
                    "source": "# Title\n\n:::note\n本文 $x^2$\n:::\n\n注[^a]\n\n[^a]: footnote",
                ]
            ])
        ).body
        #expect(html.contains("callout-note"))
        #expect(html.contains("math-inline"))
        #expect(html.contains("footnotes"))
    }

    @Test("文字列と行配列を読み見出しと題名を保つ")
    func sourceAndTitle() throws {
        let result = try NotebookConverter.convert(
            notebook([
                ["cell_type": "markdown", "source": ["# 題名\n", "本文"]],
                ["cell_type": "raw", "source": "<raw>"],
            ]))
        #expect(result.title == "題名")
        #expect(result.body.contains("&lt;raw&gt;"))
        #expect(try NotebookConverter.convert(notebook([], metadata: ["title": "指定"])).title == "指定")
    }

    @Test("セルをまたぐ見出しと脚注のIDが重ならず目次に全見出しが載る")
    func anchors() throws {
        let result = try NotebookConverter.convert(
            notebook([
                ["cell_type": "markdown", "source": "[TOC]\n\n# Same\n\na[^x]\n\n[^x]: one"],
                ["cell_type": "markdown", "source": "# Same\n\nb[^x]\n\n[^x]: two"],
            ]))
        let headings = DocumentOutline.headings(inHTML: result.body)
        #expect(headings.count == 2)
        #expect(Set(headings.compactMap(\.id)).count == 2)
        #expect(DocumentOutline.sourceContentsEntries(inHTML: result.body) == ["Same", "Same"])
    }

    @Test("コードの色付けと実行番号を出しコードオプションの対象を保つ")
    func code() throws {
        let result = try NotebookConverter.convert(
            notebook(
                [
                    ["cell_type": "code", "source": "print(1)", "execution_count": 3],
                    ["cell_type": "code", "source": "x = 2", "execution_count": NSNull()],
                ], metadata: ["language_info": ["name": "python"]]))
        #expect(result.body.contains("[3]"))
        #expect(result.body.contains("[]"))
        #expect(result.body.contains("<pre><code class=\"language-python hl\">"))
    }

    @Test("画像をMIME順に一つだけ選び寸法を尊重する")
    func mime() throws {
        let html = try output(
            ["image/png": "AAAA", "image/jpeg": "BBBB", "text/html": "<p>table</p>"],
            metadata: ["image/png": ["width": 24, "height": 12]])
        #expect(html.contains("data:image/png;base64,AAAA"))
        #expect(!html.contains("BBBB"))
        #expect(!html.contains("<p>table</p>"))
        #expect(html.contains("width:24px"))
    }

    @Test("添付画像をdata URIにして相対画像はそのまま保つ")
    func attachments() throws {
        let result = try NotebookConverter.convert(
            notebook([
                [
                    "cell_type": "markdown",
                    "source": "![添付](attachment:image.png) ![相対](images/a.png)",
                    "attachments": ["image.png": ["image/png": "AAAA"]],
                ]
            ]))
        #expect(result.body.contains("data:image/png;base64,AAAA"))
        #expect(result.body.contains("images/a.png"))
    }

    @Test("端末の色と制御文字を取り除き進捗の最終状態を保つ")
    func terminal() {
        #expect(NotebookText.terminal("\u{1B}[31mred\u{1B}[0m\n0%\r100%\nabc\u{08}d") == "red\n100%\nabd")
        #expect(NotebookText.terminal("long\rX\u{1B}[K") == "X")
        #expect(NotebookText.terminal("a\r\nb") == "a\nb")
    }

    @Test("非表示タグとメタデータは紙から対応部分だけを除く")
    func hiding() throws {
        for tag in ["remove-cell", "hide-cell", "remove-input", "hide-input", "remove-output", "hide-output"] {
            let result = try NotebookConverter.convert(
                notebook([
                    [
                        "cell_type": "code", "source": "INPUT",
                        "metadata": ["tags": [tag]], "outputs": [["output_type": "stream", "text": "OUTPUT"]],
                    ]
                ]))
            #expect(result.body.contains("INPUT") == tag.hasSuffix("output"))
            #expect(result.body.contains("OUTPUT") == tag.hasSuffix("input"))
        }
        for metadata: [String: Any] in [["collapsed": true], ["jupyter": ["outputs_hidden": true]]] {
            let result = try NotebookConverter.convert(
                notebook([
                    [
                        "cell_type": "code", "source": "INPUT",
                        "metadata": metadata, "outputs": [["output_type": "stream", "text": "OUTPUT"]],
                    ]
                ]))
            #expect(!result.body.contains("OUTPUT"))
        }
    }

    @Test("長い出力は先頭200行と末尾50行を残し省略を明示する")
    func limits() throws {
        let html = try output(["text/plain": (1...500).map { "line\($0)" }.joined(separator: "\n")])
        #expect(html.contains("line200</pre>"))
        #expect(!html.contains("line201\n"))
        #expect(html.contains("line451\n"))
        #expect(html.contains("250"))
        let huge = try output(["text/plain": String(repeating: "あ", count: 100_000)])
        #expect(huge.utf8.count < 210_000)
        #expect(huge.contains("notebook-note"))
    }

    @Test("HTML出力からスクリプトとイベントとスタイルを除き表は残す")
    func html() throws {
        let html = try output([
            "text/html": "<style scoped>body{display:none}</style><script>x()</script>"
                + "<table class='dataframe' onclick='x()'><tr><td onmouseover=x()>42</td></tr></table>"
        ])
        #expect(html.contains("dataframe"))
        #expect(html.contains("42"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("onclick"))
        #expect(!html.contains("onmouseover"))
        #expect(!html.contains("<style"))
    }

    @Test("対話型出力は枠で知らせ有用なテキストだけ添える")
    func interactive() throws {
        let html = try output(["application/vnd.jupyter.widget-view+json": [:], "text/plain": "<Figure size 10x10>"])
        #expect(html.contains("Interactive output is not shown on paper"))
        #expect(!html.contains("Figure size"))
        let table = try output(["application/vnd.plotly.v1+json": [:], "text/plain": "Total: 42"])
        #expect(table.contains("Total: 42"))
        let script = try output(["text/html": "<div id='plot'></div><script>plot()</script>"])
        #expect(script.contains("Interactive output is not shown on paper"))
    }

    @Test("Markdownと単独の数式とSVGを既存の描画方法へ渡す")
    func rich() throws {
        #expect(try output(["text/markdown": "**bold**"]).contains("<strong>bold</strong>"))
        #expect(try output(["text/latex": "$$x^2$$"]).contains("class=\"math math-display\""))
        #expect(try output(["text/latex": "words $x$ words"]).contains("words $x$ words"))
        let svg = try output(["image/svg+xml": "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"])
        #expect(svg.contains("<img"))
        #expect(svg.contains("data:image/svg+xml;base64,"))
    }

    @Test("不正なJSONと未対応の版と第3版は意味のあるエラーになる")
    func errors() throws {
        #expect(throws: NotebookError.invalidJSON) { try NotebookConverter.convert("{") }
        #expect(throws: NotebookError.unsupportedVersion(3)) {
            try NotebookConverter.convert(#"{"nbformat":3,"worksheets":[]}"#)
        }
        #expect(throws: NotebookError.unsupportedVersion(9)) {
            try NotebookConverter.convert(#"{"nbformat":9,"cells":[]}"#)
        }
    }

    @Test("Notebookの拡張子と構造のあるクリップボードだけを判定する")
    func detection() throws {
        #expect(DocumentFormat(fileExtension: "IPYNB") == .notebook)
        #expect(DocumentFormat.notebook.usesPrintTheme)
        #expect(ClipboardFormatDetector.detect(try notebook([])).action == .open(.notebook))
        for text in [#"{"cells":[]}"#, #"{"nbformat":true,"cells":[]}"#, #"{"nbformat":4,"cells":"x"}"#] {
            #expect(ClipboardFormatDetector.detect(text).action != .open(.notebook))
        }
    }
}

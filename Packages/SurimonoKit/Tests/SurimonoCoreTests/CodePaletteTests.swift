import Foundation
import Testing

@testable import SurimonoCore

struct CodePaletteTests {
    private func palettes() throws -> [CodePalette] { try CodePaletteLibrary.load() }

    private func candidates() throws -> [CodePalette] { try palettes().filter { $0.group == .candidate } }

    private func ratio(_ color: String?, on ground: String) throws -> Double {
        let color = try #require(color)
        return try #require(CodeColor.contrast(color, ground))
    }

    @Test("既定の候補は 12 種で、暗い地は候補の外にある")
    func catalogGroups() throws {
        #expect(
            try candidates().map(\.id) == [
                "sumi", "shoinku", "wairo", "kanshoku", "danshoku", "fukamidori", "aiichi", "sepia", "nisho", "hicon",
                "vivid", "ud",
            ])
        #expect(try palettes().filter { $0.group == .inkHeavy }.map(\.id) == ["dark"])
    }

    @Test("すべての配色が 15 個のトークンの値を持つ")
    func everyPaletteHasEveryToken() throws {
        #expect(CodePalette.Token.allCases.count == 15)
        for palette in try palettes() {
            #expect(Set(palette.colors.keys) == Set(CodePalette.Token.allCases), "\(palette.id)")
        }
    }

    @Test("白い紙の配色は、全トークンが白・淡い地・最も濃い地の上で 4.5:1 以上ある")
    func candidatesReadOnPaper() throws {
        for palette in try candidates() {
            for ground in ["#ffffff", "#f4f3ef", "#eee8d5"] {
                for token in CodePalette.Token.allCases {
                    let value = try ratio(palette.colors[token], on: ground)
                    #expect(value >= 4.5, "\(palette.id) \(token) on \(ground): \(value)")
                }
            }
        }
    }

    @Test("追加と削除の行は、配色の地の上でも 4.5:1 以上ある")
    func changedLinesRead() throws {
        for palette in try palettes() {
            if let ground = palette.additionBackground {
                #expect(try ratio(palette.colors[.addition], on: ground) >= 4.5, "\(palette.id)")
            }
            if let ground = palette.deletionBackground {
                #expect(try ratio(palette.colors[.deletion], on: ground) >= 4.5, "\(palette.id)")
            }
        }
    }

    @Test("暗い地の配色は、全トークンと地の文字が自分の地の上で 4.5:1 以上ある")
    func darkGroundReads() throws {
        let dark = try #require(try palettes().first { $0.id == "dark" })
        let ground = try #require(dark.ground)
        #expect(ground == "#1f2530")
        for token in CodePalette.Token.allCases {
            let value = try ratio(dark.colors[token], on: ground)
            #expect(value >= 4.5, "\(token): \(value)")
        }
        #expect(try ratio(dark.ink, on: ground) >= 4.5)
    }

    @Test("最低のコントラストは実測の値と一致する")
    func minimumContrasts() throws {
        let measured = [
            "sumi": 5.99, "shoinku": 4.69, "wairo": 5.6, "kanshoku": 4.94, "danshoku": 5.31, "fukamidori": 5.29,
            "aiichi": 5.0, "sepia": 5.79, "nisho": 5.99, "hicon": 7.41, "vivid": 5.07, "ud": 4.92, "dark": 6.63,
        ]
        for palette in try palettes() {
            let expected = try #require(measured[palette.id])
            #expect(abs(palette.minimumContrast - expected) < 0.01, "\(palette.id)")
        }
    }

    @Test("WCAG の式で白と黒は 21:1 になる")
    func contrastFormula() {
        #expect(CodeColor.contrast("#fff", "#000") == 21)
        #expect(CodeColor.contrast("#713a8a", "#ffffff").map { abs($0 - 7.85) < 0.01 } == true)
        #expect(CodeColor.contrast("red", "#000") == nil)
    }

    @Test("インクの多さは指数を 4 段に分ける")
    func inkLevels() {
        func level(_ index: Int) -> CodePalette.InkLevel {
            CodePalette(id: "x", name: "x", colors: [:], inkIndex: index).inkLevel
        }
        #expect(level(94) == .low)
        #expect(level(95) == .normal)
        #expect(level(114) == .normal)
        #expect(level(115) == .raised)
        #expect(level(299) == .raised)
        #expect(level(300) == .high)
    }

    @Test("名前と注は 8 言語すべてにある")
    func everyLanguageHasNames() throws {
        for palette in try palettes() {
            #expect(Set(palette.localizedNames.keys) == Set(UILanguage.supported), "\(palette.id)")
            #expect(Set(palette.localizedNotes.keys) == Set(UILanguage.supported), "\(palette.id)")
        }
    }

    @Test("太字と斜体は配色の指定がなければ common.css と同じになる")
    func faces() throws {
        let palette = try #require(try palettes().first { $0.id == "sumi" })
        #expect(palette.face(for: .keyword) == CodePalette.Face(weight: 700))
        #expect(palette.face(for: .type) == CodePalette.Face(weight: 400, isItalic: true))
        #expect(palette.face(for: .number) == CodePalette.Face(weight: 400))
        let wairo = try #require(try palettes().first { $0.id == "wairo" })
        #expect(wairo.face(for: .keyword) == CodePalette.Face(weight: 600))
        #expect(wairo.face(for: .comment) == CodePalette.Face(weight: 400, isItalic: true))
    }

    @Test("テーマのスタイルシートから最後に決まったトークンの色を読む")
    func colorsInStyleSheet() {
        let css = ":root { --hl-keyword: #111; --hl-type: #222222 }\n:root { --hl-keyword: #333; --hl-tag: red; }"
        let colors = CodePalette.colors(inStyleSheet: css)
        #expect(colors[.keyword] == "#333")
        #expect(colors[.type] == "#222222")
        #expect(colors[.tag] == nil)
    }

    private func catalog(_ palette: [String: Any]) -> Data {
        var entry: [String: Any] = [
            "id": "x", "group": "candidate", "name": "X", "note": "n", "inkIndex": 100,
            "colors": Dictionary(uniqueKeysWithValues: CodePalette.Token.allCases.map { ($0.rawValue, "#000000") }),
        ]
        entry.merge(palette) { _, new in new }
        // Strings, numbers and dictionaries of them, which JSONSerialization always accepts.
        return (try? JSONSerialization.data(withJSONObject: ["palettes": [entry]])) ?? Data()
    }

    @Test("目録は、トークンの抜けや色でない値を読まない")
    func invalidCatalogs() {
        #expect(throws: CodePaletteLibrary.CatalogError.missingColor(palette: "x", token: "keyword")) {
            try CodePaletteLibrary.palettes(from: catalog(["colors": ["type": "#000000"]]))
        }
        #expect(throws: CodePaletteLibrary.CatalogError.invalidColor(palette: "x", value: "url(x)")) {
            try CodePaletteLibrary.palettes(from: catalog(["ground": "url(x)"]))
        }
        #expect(throws: CodePaletteLibrary.CatalogError.unknownGroup("other")) {
            try CodePaletteLibrary.palettes(from: catalog(["group": "other"]))
        }
        #expect(throws: CodePaletteLibrary.CatalogError.invalidFace(palette: "x", token: "keyword")) {
            try CodePaletteLibrary.palettes(from: catalog(["faces": ["keyword": "bold"]]))
        }
    }
}

struct CodeStyleSheetTests {
    private func standard() throws -> PrintTheme {
        try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
    }

    private func palette(_ id: String) throws -> CodePalette {
        try #require(try CodePaletteLibrary.load().first { $0.id == id })
    }

    @Test("既定ではスタイルシートも本文も今と同じになる")
    func defaultChangesNothing() throws {
        let theme = try standard()
        let fragment = HTMLFragment(body: "<pre><code class=\"language-swift hl\">let a\n</code></pre>\n")
        #expect(
            HTMLDocumentBuilder.styleSheet(theme: theme, code: CodeStyle())
                == HTMLDocumentBuilder.styleSheet(theme: theme))
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .markdown, theme: theme)
        #expect(html.contains(fragment.body))
        #expect(!html.contains("code-line"))
    }

    @Test("重ねる順は 共通、テーマ、コードの配色、文字の大きさ")
    func layerOrder() throws {
        let theme = PrintTheme(id: "t", name: "t", css: "/* common */\n/* theme */")
        let css = HTMLDocumentBuilder.styleSheet(
            theme: theme, textScale: 1.2, code: CodeStyle(palette: try palette("sumi")))
        let themeEnd = try #require(css.range(of: "/* theme */"))
        let palette = try #require(css.range(of: "--hl-keyword: #000000"))
        let scale = try #require(css.range(of: "html { zoom: 1.2; }"))
        #expect(themeEnd.upperBound <= palette.lowerBound)
        #expect(palette.upperBound <= scale.lowerBound)
    }

    @Test("配色はテーマが飾ったトークンの形も上書きする")
    func paletteOverridesThemeShape() throws {
        let css = CodeStyle(palette: try palette("shoinku")).css
        #expect(css.contains("body.surimono .hl-keyword { color: var(--hl-keyword); font-weight: 400;"))
        #expect(
            css.contains(
                "body.surimono .hl-deletion { color: var(--hl-deletion); font-weight: 400; "
                    + "font-style: italic; text-decoration: none; background: none; }"))
    }

    @Test("地の文字の色を持つ配色は、コードの文字の色も変える")
    func ink() throws {
        let css = CodeStyle(palette: try palette("shoinku")).css
        #expect(css.contains("{ color: #3f3f3f; }"))
    }

    @Test("暗い地はどの枠でも地を敷き、印刷でも落とさない")
    func darkGround() throws {
        let css = CodeStyle(palette: try palette("dark"), block: CodeBlockOptions(frame: .none)).css
        let last = try #require(css.range(of: "background: #1f2530", options: .backwards))
        let reset = try #require(css.range(of: "background: none; border: 0;"))
        #expect(reset.upperBound <= last.lowerBound)
        #expect(css.contains("print-color-adjust: exact"))
    }

    @Test("枠の形はコードのブロックの印にだけ付く")
    func frameLeavesPlainText() {
        for frame in CodeBlockOptions.Frame.allCases where frame != .style {
            let css = CodeStyle(block: CodeBlockOptions(frame: frame)).css
            #expect(css.hasPrefix("body.surimono pre.code-block {"), "\(frame)")
        }
    }

    @Test("枠の選択肢はそれぞれ別の形になり、スタイルのままは何も足さない")
    func framesDiffer() {
        let rules = CodeBlockOptions.Frame.allCases.map { CodeStyle(block: CodeBlockOptions(frame: $0)).css }
        #expect(Set(rules).count == CodeBlockOptions.Frame.allCases.count)
        #expect(rules[0].isEmpty)
    }
}

struct CodeBlockMarkupTests {
    private let block = "<pre><code class=\"language-swift hl\">let a\nlet b\n</code></pre>\n"

    private func apply(_ options: CodeBlockOptions, to html: String) -> String {
        CodeBlockMarkup.apply(CodeStyle(block: options), to: html)
    }

    @Test("既定のオプションでは本文を変えない")
    func defaultLeavesHTML() {
        #expect(CodeBlockMarkup.apply(CodeStyle(), to: block) == block)
    }

    @Test("既定でないときは、コードのブロックに印だけを付ける")
    func marksBlocks() {
        #expect(
            apply(CodeBlockOptions(frame: .rule, longLines: .shrink), to: block)
                == "<pre class=\"code-block\"><code class=\"language-swift hl\">let a\nlet b\n</code></pre>\n")
    }

    @Test("配色だけを選んでもブロックに印が付く")
    func paletteMarksBlocks() {
        let palette = CodePalette(id: "x", name: "x", colors: [:])
        #expect(
            CodeBlockMarkup.apply(CodeStyle(palette: palette), to: "<pre><code>a</code></pre>")
                == "<pre class=\"code-block\"><code>a</code></pre>")
    }

    @Test("行番号はコードの行ごとに要素を足し、桁数を伝える")
    func numbersEveryLine() {
        let html = apply(CodeBlockOptions(lineNumbers: .all), to: block)
        #expect(
            html == "<pre class=\"code-block code-numbered\" style=\"--code-digits: 1\">"
                + "<code class=\"language-swift hl\">"
                + "<span class=\"code-line\" data-no=\"1\"><span class=\"code-src\">let a</span></span>"
                + "<span class=\"code-line\" data-no=\"2\"><span class=\"code-src\">let b</span></span>"
                + "</code></pre>\n")
    }

    @Test("5 行ごとの番号は 5 の倍数の行にだけ付く")
    func numbersEveryFifthLine() {
        let code = (1...10).map { "line\($0)" }.joined(separator: "\n")
        let html = apply(CodeBlockOptions(lineNumbers: .everyFive), to: "<pre><code>\(code)</code></pre>")
        #expect(html.components(separatedBy: "data-no=").count == 3)
        #expect(html.contains("data-no=\"5\""))
        #expect(html.contains("data-no=\"10\""))
        #expect(html.contains("--code-digits: 2"))
    }

    @Test("行をまたぐトークンは行ごとに閉じて開き直す")
    func tokenAcrossLines() throws {
        let body = "a <span class=\"hl-comment\">/* x\ny */</span> b\n"
        let lines = try #require(CodeBlockMarkup.lines(of: body[...]))
        #expect(
            lines == [
                "a <span class=\"hl-comment\">/* x</span>", "<span class=\"hl-comment\">y */</span> b",
            ])
    }

    @Test("行の終わりで閉じるトークンは、次の行に空の要素を残さない")
    func tokenEndingWithLine() throws {
        let body = "<span class=\"hl-comment\"># x\n</span>y"
        #expect(try #require(CodeBlockMarkup.lines(of: body[...])) == ["<span class=\"hl-comment\"># x</span>", "y"])
    }

    @Test("空の行も 1 行に数える")
    func blankLines() throws {
        #expect(try #require(CodeBlockMarkup.lines(of: "a\n\nb\n"[...])) == ["a", "", "b"])
    }

    @Test("トークンの途中の空の行も、本文のない行として見分ける")
    func blankLineInsideToken() throws {
        let body = "<span class=\"hl-comment\">/* a\n\nb */</span>\n"
        #expect(
            try #require(CodeBlockMarkup.lines(of: body[...])) == [
                "<span class=\"hl-comment\">/* a</span>", "", "<span class=\"hl-comment\">b */</span>",
            ])
    }

    @Test("空の行には改行を入れて、行の高さを保つ")
    func blankLineKeepsItsHeight() {
        let plain = apply(CodeBlockOptions(lineNumbers: .all), to: "<pre><code>a\n\nb</code></pre>")
        let token = apply(
            CodeBlockOptions(lineNumbers: .all),
            to: "<pre><code><span class=\"hl-comment\">/* a\n\nb */</span></code></pre>")
        for html in [plain, token] {
            #expect(
                html.contains("<span class=\"code-line\" data-no=\"2\"><span class=\"code-src\"><br></span></span>"))
        }
        let cut = apply(CodeBlockOptions(longLines: .cut), to: "<pre><code>a\n\nb</code></pre>")
        #expect(cut.contains("<span class=\"code-line\"><span class=\"code-src\"><br></span></span>"))
    }

    @Test("生の HTML のマークアップを持つブロックは行に分けない")
    func rawMarkup() {
        #expect(
            apply(CodeBlockOptions(lineNumbers: .all), to: "<pre><code>a<b>c</b>\nd</code></pre>")
                == "<pre class=\"code-block\"><code>a<b>c</b>\nd</code></pre>")
    }

    @Test("属性を持つ pre はコードとして扱わない")
    func otherPreElements() {
        let plain = "<pre class=\"surimono-plain\">a\nb</pre>"
        #expect(apply(CodeBlockOptions(lineNumbers: .all), to: plain) == plain)
        #expect(apply(CodeBlockOptions(frame: .rule), to: plain) == plain)
        #expect(!CodeBlockMarkup.containsCode(plain))
        #expect(CodeBlockMarkup.containsCode(block))
    }

    @Test("Org の EXAMPLE の pre にも行番号が付く")
    func preWithoutCode() {
        let html = apply(CodeBlockOptions(lineNumbers: .all), to: "<pre>a\nb</pre>")
        #expect(html.contains("<span class=\"code-line\" data-no=\"2\">"))
    }

    @Test("code のない pre も、枠のときは同じ中身のコードのブロックになる")
    func preWithoutCodeBecomesABlock() {
        #expect(
            apply(CodeBlockOptions(longLines: .shrink), to: "<pre>a\nb</pre>")
                == "<pre class=\"code-block\"><code>a\nb</code></pre>")
    }

    @Test("言語名の札は表示名を pre に持たせる")
    func languageLabel() {
        func label(_ language: String) -> String {
            apply(
                CodeBlockOptions(languageLabel: .corner),
                to: "<pre><code class=\"language-\(language) hl\">a</code></pre>")
        }
        #expect(label("swift").hasPrefix("<pre class=\"code-block\" data-code-label=\"Swift\"><code"))
        #expect(label("js").contains("data-code-label=\"JavaScript\""))
        #expect(label("c++").contains("data-code-label=\"C++\""))
        #expect(label("diff").contains("data-code-label=\"diff\""))
        #expect(label("unknownlang").contains("data-code-label=\"unknownlang\""))
    }

    @Test("言語のないブロックには札を付けない")
    func noLanguage() {
        #expect(
            apply(CodeBlockOptions(languageLabel: .band), to: "<pre><code>a</code></pre>")
                == "<pre class=\"code-block\"><code>a</code></pre>")
    }

    @Test("切る印のために、番号なしでも行の要素を足す")
    func cutNeedsLines() {
        let html = apply(CodeBlockOptions(longLines: .cut), to: block)
        #expect(html.contains("<span class=\"code-line\"><span class=\"code-src\">let a</span></span>"))
        #expect(!html.contains("code-numbered"))
    }

    @Test("Markdown と Org と LaTeX のコードに同じ形で効く")
    func everyConverter() {
        let options = CodeBlockOptions(lineNumbers: .all, languageLabel: .corner)
        let bodies = [
            MarkdownConverter.convert("```swift\nlet a = 1\n```\n").body,
            OrgConverter.convert("#+BEGIN_SRC swift\nlet a = 1\n#+END_SRC\n").body,
            LaTeXConverter.convert(
                "\\begin{document}\n\\begin{lstlisting}[language=swift]\nlet a = 1\n\\end{lstlisting}\n\\end{document}\n"
            ).body,
        ]
        for body in bodies {
            let html = CodeBlockMarkup.apply(CodeStyle(block: options), to: body)
            #expect(html.contains("data-code-label=\"Swift\""), "\(body)")
            #expect(html.contains("data-no=\"1\""), "\(body)")
        }
    }
}

struct CodeBlockOptionsTests {
    @Test("オプションの既定は今の見た目")
    func defaults() {
        let options = CodeBlockOptions()
        #expect(options.frame == .style)
        #expect(options.lineNumbers == .none)
        #expect(options.longLines == .wrap)
        #expect(options.languageLabel == .none)
    }

    @Test("知らない値があっても他の選択を失わない")
    func unknownValues() throws {
        let json = #"{"frame":"neon","lineNumbers":"all","longLines":"cut","languageLabel":"banner"}"#
        let options = try JSONDecoder().decode(CodeBlockOptions.self, from: Data(json.utf8))
        #expect(options == CodeBlockOptions(lineNumbers: .all, longLines: .cut))
    }

    @Test("文書の設定はコードの配色と枠を覚え、古い記録も読める")
    func documentSettings() throws {
        let settings = DocumentSettings(
            themeID: "standard", codePaletteID: "sumi", codeBlock: CodeBlockOptions(frame: .left))
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        let old = try JSONDecoder().decode(DocumentSettings.self, from: Data(#"{"themeID":"standard"}"#.utf8))
        #expect(old.themeID == "standard")
        #expect(old.codePaletteID == nil)
        #expect(old.codeBlock == nil)
    }

    @Test("読めない枠の記録があっても文書の他の設定を失わない")
    func brokenRecord() throws {
        let json = #"{"themeID":"sumi","codePaletteID":7,"codeBlock":"x"}"#
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: Data(json.utf8))
        #expect(decoded.themeID == "sumi")
        #expect(decoded.codePaletteID == nil)
        #expect(decoded.codeBlock == nil)
    }
}

struct CodeFitScriptTests {
    @Test("折り返しでは台本を走らせない")
    func wrapNeedsNothing() {
        #expect(CodeFitScript.javaScript(for: CodeStyle(), layoutWidth: 600) == nil)
    }

    @Test("組版の幅で測り、根の zoom の座標に直す")
    func measuresAtPrintWidth() throws {
        let script = try #require(
            CodeFitScript.javaScript(
                for: CodeStyle(block: CodeBlockOptions(longLines: .shrink)), layoutWidth: 637.8))
        #expect(script.contains("(637.8 / zoom)"))
        #expect(script.contains("'pre.code-block > code'"))
    }

    @Test("切る印の文言は文字列として埋め込む")
    func quotesTheFormat() throws {
        let style = CodeStyle(block: CodeBlockOptions(longLines: .cut), cutFormat: "+%d \"字\"")
        let script = try #require(CodeFitScript.javaScript(for: style, layoutWidth: 600))
        #expect(script.contains(#"const format = "+%d \"字\"";"#))
    }

    @Test("変更の印の id が付いたコードも同じマークアップになり、id は残る")
    func codeWithSourceMap() {
        let style = CodeStyle(block: CodeBlockOptions(lineNumbers: .all, languageLabel: .corner))
        let plain = "<pre><code class=\"language-swift\">let a\nlet b\n</code></pre>\n"
        let mapped = plain.replacingOccurrences(of: "<pre>", with: "<pre data-surimono-block=\"md-1-0\">")
        let marked = CodeBlockMarkup.apply(style, to: mapped)
        #expect(marked.contains("data-surimono-block=\"md-1-0\""))
        #expect(marked.contains("class=\"code-block"))
        #expect(
            marked.replacingOccurrences(of: " data-surimono-block=\"md-1-0\"", with: "")
                == CodeBlockMarkup.apply(style, to: plain))
        #expect(CodeBlockMarkup.containsCode(mapped))
    }

    @Test("ほかの属性のある pre はコードとして扱わない")
    func otherPreStays() {
        let html = "<pre class=\"art\">図</pre>"
        #expect(!CodeBlockMarkup.containsCode(html))
        #expect(CodeBlockMarkup.apply(CodeStyle(block: CodeBlockOptions(lineNumbers: .all)), to: html) == html)
    }
}

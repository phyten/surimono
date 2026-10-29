import Foundation
import JavaScriptCore
import SurimonoCore
import Testing

struct ResourceLibraryTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("組み込みテーマは一意な10種で、日常の用途から順に並び、印刷用の共通指定を持つ")
    func themes() throws {
        let themes = try PrintThemeLibrary.load()
        #expect(
            themes.map(\.id) == [
                "standard", "mincho", "compact", "github", "academic", "modern", "large", "notes", "monochrome",
                "handout",
            ])
        for theme in themes {
            #expect(theme.isBuiltIn)
            #expect(theme.localizedNames["ja"] != nil)
            #expect(theme.css.contains("break-after: avoid"))
            #expect(theme.css.contains("break-inside: avoid"))
            #expect(theme.css.contains("max-width: 100%"))
            #expect(theme.css.contains("pre-wrap"))
            #expect(!theme.css.contains("@page"))
        }
    }

    @Test("ユーザーCSSは直下だけを読み名前順で安定して並ぶ")
    func userThemes() throws {
        try withDirectory { directory in
            try "body { color: black; }".write(
                to: directory.appendingPathComponent("Zebra.css"), atomically: true, encoding: .utf8)
            try "p { color: black; }".write(
                to: directory.appendingPathComponent("Alpha.css"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("ignored.css"), withIntermediateDirectories: true)
            let themes = try PrintThemeLibrary.load(userDirectory: directory)
            let users = themes.filter { !$0.isBuiltIn }
            #expect(users.map(\.id) == ["user:Alpha.css", "user:Zebra.css"])
            // User styles come after the built-in themes.
            #expect(themes.suffix(2).map(\.id) == ["user:Alpha.css", "user:Zebra.css"])
            #expect(users.map(\.name) == ["Alpha", "Zebra"])
            #expect(users[0].css.contains("break-after: avoid"))
            #expect(users[0].css.contains("break-inside: avoid"))
            #expect(users[0].css.contains("max-width: 100%"))
            #expect(users[0].css.hasSuffix("\np { color: black; }"))
        }
    }

    @Test("存在しないユーザーディレクトリは組み込みだけを返す")
    func absentDirectory() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(try PrintThemeLibrary.load(userDirectory: missing).count == 10)
        let result = try HTMLCleanupPresetLibrary.load(userDirectory: missing)
        #expect(result.presets.count == 4)
        #expect(result.errors.isEmpty)
    }

    @Test("組み込みプリセットは4種で誤爆しやすい広告セレクタを含まない")
    func presets() throws {
        let result = try HTMLCleanupPresetLibrary.load()
        #expect(Set(result.presets.map(\.id)) == ["none", "clean", "article", "print"])
        #expect(result.presets.allSatisfy { $0.isBuiltIn })
        #expect(result.errors.isEmpty)
        let clean = try #require(result.presets.first { $0.id == "clean" })
        #expect(clean.removeSelectors.contains("[role=banner]"))
        #expect(!clean.removeSelectors.contains { $0.contains("*=") })
        let printPreset = try #require(result.presets.first { $0.id == "print" })
        #expect(printPreset.extraCSS.contains("attr(href)"))
        #expect(Set(clean.removeSelectors).isSubset(of: Set(printPreset.removeSelectors)))
    }

    @Test("プリセットをJSONで往復でき組み込みフラグは保存しない")
    func presetRoundTrip() throws {
        let preset = HTMLCleanupPreset(
            id: "mine", name: "Mine", localizedNames: ["ja": "自作"], removeSelectors: ["nav"], keepSelectors: ["main"],
            extraCSS: "p { color: black; }", disablesJavaScript: true)
        let data = try JSONEncoder().encode(preset)
        #expect(try JSONDecoder().decode(HTMLCleanupPreset.self, from: data) == preset)
        #expect(!String(decoding: data, as: UTF8.self).contains("isBuiltIn"))
    }

    @Test("壊れたユーザーJSONを飛ばしファイル付きエラーを返す")
    func brokenJSON() throws {
        try withDirectory { directory in
            let preset = HTMLCleanupPreset(id: "custom", name: "Custom")
            try JSONEncoder().encode(preset).write(to: directory.appendingPathComponent("good.json"))
            let broken = directory.appendingPathComponent("broken.json")
            try Data("{".utf8).write(to: broken)
            let result = try HTMLCleanupPresetLibrary.load(userDirectory: directory)
            #expect(result.presets.count == 5)
            #expect(result.presets.first { $0.id == "custom" }?.isBuiltIn == false)
            #expect(result.errors.count == 1)
            #expect(result.errors[0].url.resolvingSymlinksInPath() == broken.resolvingSymlinksInPath())
            #expect(!result.errors[0].message.isEmpty)
        }
    }

    @Test("重複IDのユーザープリセットは組み込みを上書きせずエラーにする")
    func duplicateID() throws {
        try withDirectory { directory in
            try JSONEncoder().encode(HTMLCleanupPreset(id: "none", name: "Override"))
                .write(to: directory.appendingPathComponent("override.json"))
            let result = try HTMLCleanupPresetLibrary.load(userDirectory: directory)
            #expect(result.presets.count == 4)
            #expect(result.errors.count == 1)
        }
    }

    @Test("セレクタの引用符と改行をJSONとしてJSへ埋め込む")
    func scriptEscaping() throws {
        let selector = "[data-x=\"a'\\b\"]\n</script>"
        let preset = HTMLCleanupPreset(
            id: "test", name: "Test", removeSelectors: [selector], keepSelectors: ["["],
            extraCSS: "p::after { content: '\"'; }")
        let script = HTMLCleanupScript.javaScript(for: preset)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(decoding: try encoder.encode(preset), as: UTF8.self)
        #expect(script.contains(encoded))
        #expect(!script.contains(selector))
        #expect(script.contains("catch"))
        #expect(script.contains("textContent"))
    }

    @Test("noneプリセットのスクリプトは空になる")
    func noneScript() throws {
        let none = try #require(HTMLCleanupPresetLibrary.load().presets.first { $0.id == "none" })
        #expect(HTMLCleanupScript.javaScript(for: none).isEmpty)
        #expect(!none.disablesJavaScript)
    }

    @Test("生成JSは不正セレクタの後も除去と本文抽出とCSS挿入を続ける")
    func executeScript() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            const article = {};
            const nav = { remove() { this.removed = true; } };
            const document = {
              body: { contains(node) { return node === article; }, replaceChildren(node) { this.kept = node; } },
              head: { appendChild(node) { this.style = node; } },
              documentElement: {},
              querySelector(selector) {
                if (selector === '[') throw new SyntaxError('Invalid selector');
                if (selector === 'article') return article;
                throw new Error('Selectors after the first match must not run');
              },
              querySelectorAll(selector) {
                if (selector === '[') throw new SyntaxError('Invalid selector');
                return [nav];
              },
              getElementById() { return null; },
              createElement() { return { tagName: 'STYLE' }; }
            };
            """)
        let css = "p::after { content: '\"\\\n</style>'; }"
        let preset = HTMLCleanupPreset(
            id: "test", name: "Test", removeSelectors: ["[", "nav"],
            keepSelectors: ["[", "article", "main"], extraCSS: css)
        context.evaluateScript(HTMLCleanupScript.javaScript(for: preset))
        #expect(context.exception == nil)
        #expect(context.evaluateScript("document.body.kept === article && nav.removed === true")?.toBool() == true)
        #expect(context.evaluateScript("document.head.style.textContent")?.toString() == css)
    }

    @Test("生成JSは本文候補が無ければ元の本文を残す")
    func absentArticle() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            const document = {
              body: { replaceChildren() { throw new Error('Body must remain'); } },
              querySelector() { return null; }
            };
            """)
        let preset = HTMLCleanupPreset(id: "test", name: "Test", keepSelectors: ["article", "main"])
        context.evaluateScript(HTMLCleanupScript.javaScript(for: preset))
        #expect(context.exception == nil)
    }

    @Test("HTML文書にエスケープした表題とbaseと言語とテーマを付ける")
    func document() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let body = HTMLDocumentBuilder.build(
            fragment: HTMLFragment(body: "<p>本文</p>", title: "本 <&>"), format: .markdown, theme: theme,
            baseURL: URL(string: "file:///tmp/book/"))
        #expect(body.hasPrefix("<!doctype html>"))
        #expect(body.contains("<meta charset=\"utf-8\">"))
        #expect(body.contains("<html lang=\"ja\">"))
        #expect(body.contains("<title>本 &lt;&amp;&gt;</title>"))
        #expect(body.contains("<base href=\"file:///tmp/book/\">"))
        #expect(body.contains("<body class=\"surimono format-markdown\">"))
        #expect(body.contains(theme.css))
        #expect(!body.contains("@page"))
    }

    @Test("HTML文書はbase無しで組み立てCSSのstyle終端を無害化する")
    func documentWithoutBase() {
        let theme = PrintTheme(id: "test", name: "Test", css: "p::after { content: '</StYlE><script>'; }")
        let html = HTMLDocumentBuilder.build(
            fragment: HTMLFragment(body: "<p>x</p>"), format: .plainText, theme: theme, language: "en\"")
        #expect(!html.contains("<base"))
        #expect(!html.contains("</StYlE>"))
        #expect(html.contains("lang=\"en&quot;\""))
    }

    @Test(
        "組み込みプリセットの英日表示名は製品の語彙に一致する",
        arguments: [
            ("none", "Original", "そのまま"), ("clean", "Remove Noise", "ノイズ除去"),
            ("article", "Article Only", "本文のみ"), ("print", "Print-Friendly", "印刷最適化"),
        ])
    func presetNames(id: String, english: String, japanese: String) throws {
        let preset = try #require(HTMLCleanupPresetLibrary.load().presets.first { $0.id == id })
        #expect(preset.name == english)
        #expect(preset.displayName(language: "en") == english)
        #expect(preset.displayName(language: "ja") == japanese)
    }
}

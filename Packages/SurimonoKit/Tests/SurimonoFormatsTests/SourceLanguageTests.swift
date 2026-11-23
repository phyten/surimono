import Foundation
import SurimonoFormats
import Testing

struct SourceLanguageTests {
    @Test(
        "拡張子から言語を見分ける",
        arguments: [
            ("App.swift", "swift"), ("index.js", "javascript"), ("View.jsx", "javascript"),
            ("loader.mjs", "javascript"), ("legacy.cjs", "javascript"),
            ("main.ts", "typescript"), ("View.tsx", "typescript"), ("types.mts", "typescript"),
            ("types.cts", "typescript"),
            ("tool.py", "python"), ("stubs.pyi", "python"), ("window.pyw", "python"),
            ("model.rb", "ruby"), ("tasks.rake", "ruby"), ("surimono.gemspec", "ruby"), ("config.ru", "ruby"),
            ("main.go", "go"), ("lib.rs", "rust"), ("Main.java", "java"), ("Main.kt", "kotlin"),
            ("build.gradle.kts", "kotlin"),
            ("main.c", "c"), ("main.h", "c"), ("main.cpp", "cpp"), ("main.cc", "cpp"), ("main.cxx", "cpp"),
            ("main.hpp", "cpp"), ("main.hh", "cpp"), ("main.hxx", "cpp"),
            ("Program.cs", "csharp"), ("View.mm", "objectivec"), ("index.php", "php"),
            ("build.sh", "shell"), ("build.bash", "shell"), ("build.zsh", "shell"), ("build.ksh", "shell"),
            ("data.json", "json"), ("data.jsonl", "json"), ("data.ndjson", "json"), ("settings.jsonc", "json"),
            ("settings.json5", "json"), ("map.geojson", "json"),
            ("config.yaml", "yaml"), ("config.yml", "yaml"), ("Cargo.toml", "toml"),
            ("setup.ini", "ini"), ("app.properties", "ini"),
            ("App.vue", "html"), ("App.svelte", "html"),
            ("feed.xml", "xml"), ("Info.plist", "xml"), ("page.xsl", "xml"), ("page.xslt", "xml"),
            ("schema.xsd", "xml"), ("feed.rss", "xml"), ("feed.atom", "xml"), ("App.entitlements", "xml"),
            ("Main.storyboard", "xml"), ("View.xib", "xml"),
            ("site.css", "css"), ("site.scss", "css"), ("site.less", "css"),
            ("schema.sql", "sql"), ("app.dockerfile", "dockerfile"), ("rules.mk", "makefile"),
            ("rules.mak", "makefile"),
            ("fix.diff", "diff"), ("fix.patch", "diff"), ("init.lua", "lua"), ("plot.R", "r"), ("plot.r", "r"),
            ("solve.jl", "julia"), ("surimono.sty", "latex"), ("surimono.cls", "latex"), ("Main.hs", "haskell"),
        ])
    func extensions(fileName: String, id: String) {
        #expect(SourceLanguage.detect(fileName: fileName)?.id == id)
    }

    @Test("拡張子の大文字と小文字を区別しない")
    func caseInsensitiveExtension() {
        #expect(SourceLanguage.detect(fileName: "MAIN.SWIFT")?.id == "swift")
        #expect(SourceLanguage.detect(fileName: "Data.JSON")?.id == "json")
    }

    @Test(
        "決まった名前のファイルは拡張子がなくても見分ける",
        arguments: [
            ("Makefile", "makefile"), ("makefile", "makefile"), ("GNUmakefile", "makefile"),
            ("Dockerfile", "dockerfile"), ("Containerfile", "dockerfile"), ("Dockerfile.dev", "dockerfile"),
            ("Gemfile", "ruby"), ("Rakefile", "ruby"), ("Podfile", "ruby"), ("Fastfile", "ruby"),
            ("Brewfile", "ruby"), ("Vagrantfile", "ruby"), ("Guardfile", "ruby"),
            ("Cargo.lock", "toml"), ("poetry.lock", "toml"), ("uv.lock", "toml"), ("Pipfile", "toml"),
            (".zshrc", "shell"), (".bashrc", "shell"), (".bash_profile", "shell"), (".zprofile", "shell"),
            (".zshenv", "shell"), (".profile", "shell"),
            (".editorconfig", "ini"), (".gitconfig", "ini"), (".npmrc", "ini"),
            (".env", "ini"), (".env.local", "ini"), (".env.production", "ini"),
        ])
    func fileNames(fileName: String, id: String) {
        #expect(SourceLanguage.detect(fileName: fileName)?.id == id)
    }

    @Test(
        "見本や控えを表す末尾の拡張子は外して見分ける",
        arguments: [
            ("config.yaml.example", "yaml"), ("settings.json.sample", "json"), ("app.toml.dist", "toml"),
            ("main.swift.orig", "swift"), ("main.py.bak", "python"), ("Makefile.in", "makefile"),
            (".env.example", "ini"), ("config.yml.default", "yaml"), ("nginx.yaml.template", "yaml"),
        ])
    func secondaryExtensions(fileName: String, id: String) {
        #expect(SourceLanguage.detect(fileName: fileName)?.id == id)
    }

    @Test(
        "拡張子で分からないファイルは shebang で見分ける",
        arguments: [
            ("#!/bin/sh", "shell"), ("#!/bin/bash -eu", "shell"), ("#!/usr/bin/env zsh", "shell"),
            ("#! /usr/bin/env python3", "python"), ("#!/usr/bin/python3.12", "python"),
            ("#!/usr/bin/env -S python3 -u", "python"), ("#!/usr/bin/env PYTHONUNBUFFERED=1 python", "python"),
            ("#!/usr/bin/env ruby", "ruby"), ("#!/usr/bin/env node", "javascript"),
            ("#!/usr/bin/env -S deno run", "typescript"), ("#!/usr/bin/env bun", "typescript"),
            ("#!/usr/bin/php", "php"), ("#!/usr/bin/env lua5.4", "lua"), ("#!/usr/bin/env Rscript", "r"),
            ("#!/usr/bin/env julia", "julia"), ("#!/usr/bin/swift", "swift"),
            ("#!/usr/bin/env runhaskell", "haskell"), ("#!/usr/bin/make -f", "makefile"),
            ("\u{FEFF}#!/bin/sh", "shell"),
        ])
    func shebang(firstLine: String, id: String) {
        #expect(SourceLanguage.detect(fileName: "tool", firstLine: firstLine)?.id == id)
        #expect(SourceLanguage.detect(fileName: "tool.command", firstLine: firstLine)?.id == id)
    }

    @Test("ファイル名と拡張子は shebang より先に見る")
    func namesBeforeShebang() {
        #expect(SourceLanguage.detect(fileName: "tool.rb", firstLine: "#!/usr/bin/env python3")?.id == "ruby")
        #expect(SourceLanguage.detect(fileName: "Makefile", firstLine: "#!/bin/sh")?.id == "makefile")
    }

    @Test(
        "文章とログは shebang があっても色を付けない",
        arguments: ["notes.txt", "notes.text", "server.log", "README.md", "page.html", "paper.tex", "notes.org"])
    func prose(fileName: String) {
        #expect(SourceLanguage.detect(fileName: fileName, firstLine: "#!/bin/sh") == nil)
    }

    @Test(
        "見分けられないものは色なしにする",
        arguments: [
            ("README", nil), ("data.bin", nil), ("", nil), ("yarn.lock", nil), ("Gemfile.lock", nil),
            ("tool", "#!"), ("tool", "#!/usr/bin/env"), ("tool", "#!/usr/bin/perl"), ("tool", "# not a shebang"),
            ("tool", "#!/usr/bin/env -S"),
        ] as [(String, String?)])
    func unknown(fileName: String, firstLine: String?) {
        #expect(SourceLanguage.detect(fileName: fileName, firstLine: firstLine) == nil)
    }

    @Test(".m は Objective-C として読み、MATLAB の書き出しなら MATLAB にする")
    func objectiveCOrMATLAB() {
        #expect(
            SourceLanguage.detect(fileName: "View.m", firstLine: "#import <Foundation/Foundation.h>")?.id
                == "objectivec")
        #expect(SourceLanguage.detect(fileName: "View.m")?.id == "objectivec")
        #expect(SourceLanguage.detect(fileName: "solve.m", firstLine: "% Solves the system.")?.id == "matlab")
        #expect(SourceLanguage.detect(fileName: "solve.m", firstLine: "function x = solve(a, b)")?.id == "matlab")
        #expect(SourceLanguage.detect(fileName: "Shape.m", firstLine: "classdef Shape")?.id == "matlab")
        #expect(SourceLanguage.detect(fileName: "solve.m", firstLine: "function\tx = solve(a)")?.id == "matlab")
        #expect(SourceLanguage.detect(fileName: "solve.m", firstLine: "\t% indented")?.id == "matlab")
        #expect(SourceLanguage.detect(fileName: "View.m", firstLine: "functionPointer_t f;")?.id == "objectivec")
        #expect(SourceLanguage.detect(fileName: "solve.m", text: { "% Solves.\nx = 1;\n" })?.id == "matlab")
    }

    @Test("言語の名前は読みやすい表記で返す")
    func displayNames() {
        #expect(SourceLanguage.detect(fileName: "main.ts")?.displayName == "TypeScript")
        #expect(SourceLanguage.detect(fileName: "main.swift")?.displayName == "Swift")
        #expect(SourceLanguage.detect(fileName: "main.cpp")?.displayName == "C++")
        #expect(SourceLanguage.detect(fileName: "View.m")?.displayName == "Objective-C")
        #expect(SourceLanguage.detect(fileName: "Makefile")?.displayName == "Makefile")
    }

    @Test("見分けた言語はどれも色付けできる")
    func everyLanguageHighlights() {
        for id in SourceLanguage.supportedIDs {
            #expect(SyntaxHighlighter.highlight("x = \"a\"\n", language: id) != nil, "\(id)")
        }
        #expect(SourceLanguage.supportedIDs.count == 32)
    }

    @Test("ソースコードは拡張子に合わせて色を付ける")
    func convertsSource() {
        let swift = PlainTextConverter.convert("let count = 2 // total\n", fileName: "Count.swift").body
        #expect(swift.hasPrefix("<pre class=\"surimono-plain\">"))
        #expect(swift.contains("<span class=\"hl-keyword\">let</span>"))
        #expect(swift.contains("<span class=\"hl-comment\">// total</span>"))
        let python = PlainTextConverter.convert("def area(w, h):\n    return w * h\n", fileName: "area.py").body
        #expect(python.contains("<span class=\"hl-keyword\">def</span>"))
    }

    @Test("拡張子のないスクリプトは shebang に合わせて色を付ける")
    func convertsShebang() {
        let body = PlainTextConverter.convert("#!/usr/bin/env python3\nimport sys\n", fileName: "tool").body
        #expect(body.contains("<span class=\"hl-keyword\">import</span>"))
    }

    @Test("名前のないテキストと文章は色を付けずそのまま出す")
    func keepsPlainText() {
        let text = "#!/bin/sh\nif true; then echo \"<a>\"; fi\n"
        let plain = "<pre class=\"surimono-plain\">#!/bin/sh\nif true; then echo &quot;&lt;a&gt;&quot;; fi\n</pre>"
        #expect(PlainTextConverter.convert(text).body == plain)
        #expect(PlainTextConverter.convert(text, fileName: "notes.txt").body == plain)
        #expect(PlainTextConverter.convert(text, fileName: "server.log").body == plain)
    }

    @Test("JSON の色付けの結果を固定する")
    func fixedJSON() {
        let input = "{\n  \"title\": \"A < B\",\n  \"copies\": 2,\n  \"duplex\": true,\n  \"printer\": null\n}\n"
        let expected = """
            <pre class="surimono-plain">{
              <span class="hl-attr">&quot;title&quot;</span>: <span class="hl-string">&quot;A &lt; B&quot;</span>,
              <span class="hl-attr">&quot;copies&quot;</span>: <span class="hl-number">2</span>,
              <span class="hl-attr">&quot;duplex&quot;</span>: <span class="hl-literal">true</span>,
              <span class="hl-attr">&quot;printer&quot;</span>: <span class="hl-literal">null</span>
            }
            </pre>
            """
        #expect(PlainTextConverter.convert(input, fileName: "sample.json").body == expected)
        #expect(PlainTextConverter.convert(input, fileExtension: "json").body == expected)
    }

    @Test("XML の色付けの結果を固定する")
    func fixedXML() {
        let input = "<?xml version=\"1.0\"?>\n<!-- 見本 -->\n<job copies=\"2\">\n  <paper>A4 &amp; B5</paper>\n</job>\n"
        let expected = """
            <pre class="surimono-plain"><span class="hl-meta">&lt;?xml version=&quot;1.0&quot;?&gt;</span>
            <span class="hl-comment">&lt;!-- 見本 --&gt;</span>
            &lt;<span class="hl-tag">job</span> <span class="hl-attr">copies</span>=<span class="hl-string">&quot;2&quot;</span>&gt;
              &lt;<span class="hl-tag">paper</span>&gt;A4 <span class="hl-literal">&amp;amp;</span> B5&lt;/<span class="hl-tag">paper</span>&gt;
            &lt;/<span class="hl-tag">job</span>&gt;
            </pre>
            """
        #expect(PlainTextConverter.convert(input, fileName: "sample.xml").body == expected)
        #expect(PlainTextConverter.convert(input, fileExtension: "xml").body == expected)
    }

    @Test("JSONL・YAML・TOML は拡張子だけを渡しても色が付く")
    func structuredTextByExtension() {
        for (suffix, input) in [("jsonl", "{\"count\":2}"), ("yaml", "count: 2"), ("toml", "count = 2")] {
            #expect(PlainTextConverter.convert(input, fileExtension: suffix).body.contains("class=\"hl-"))
        }
    }

    @Test(
        "固定名から派生した名前より、明示した拡張子を先に見る",
        arguments: [
            ("Dockerfile.txt", nil), (".env.md", nil), ("Dockerfile.json", "json"), (".env.local", "ini"),
            ("Dockerfile.dev", "dockerfile"), ("Dockerfile.yaml.bak", "yaml"), (".env.html", nil),
            ("Containerfile.log", nil), ("Dockerfile.bak", "dockerfile"), ("config.yaml.in.bak", "yaml"),
            ("notes.txt.bak", nil),
        ] as [(String, String?)])
    func explicitExtensionBeforeDerivedName(fileName: String, id: String?) {
        #expect(SourceLanguage.detect(fileName: fileName, firstLine: "#!/bin/sh")?.id == id)
    }

    @Test(
        "env のオプションの値や環境変数をインタープリターと取り違えない",
        arguments: [
            ("#!/usr/bin/env -S -u ruby python3", "python"), ("#!/usr/bin/env -u ruby python3", "python"),
            ("#!/usr/bin/env -uruby python3", "python"), ("#!/usr/bin/env -C /tmp/lua node", "javascript"),
            ("#!/usr/bin/env -P /opt/ruby/bin python3", "python"), ("#!/usr/bin/env -i -S python3 -u", "python"),
            ("#!/usr/bin/env -iS python3 -u", "python"), ("#!/usr/bin/env -S \"python3 -u\"", "python"),
            ("#!/usr/bin/env -S 'ruby -w'", "ruby"), ("#!/usr/bin/env -Spython3", "python"),
            ("#!/usr/bin/env --unset ruby python3", "python"), ("#!/usr/bin/env --unset=ruby python3", "python"),
            ("#!/usr/bin/env --split-string=python3 -u", "python"), ("#!/usr/bin/env -- node", "javascript"),
            ("#!/usr/bin/env -S \"NAME=a b\" python3", "python"),
            ("#!/usr/bin/env -u ruby", nil), ("#!/usr/bin/env -S \"python3 -u", nil), ("#!/usr/bin/env -u", nil),
        ] as [(String, String?)])
    func envOptions(firstLine: String, id: String?) {
        #expect(SourceLanguage.detect(fileName: "tool", firstLine: firstLine)?.id == id)
    }

    @Test("長さの上限で切れたかもしれないコマンド名では言語を決めない")
    func cutShebang() {
        let padding = String(repeating: "x", count: 240)
        // "…/python" would end exactly at the limit if the line went on as "python3-config".
        let cut = "#!/" + padding + "/python" + String(repeating: "z", count: 40)
        #expect(SourceLanguage.detect(fileName: "tool", firstLine: cut) == nil)
        let python = "#!/" + String(repeating: "x", count: 246) + "/python"
        #expect(python.count == 256)
        #expect(SourceLanguage.detect(fileName: "tool", firstLine: python + "3-config") == nil)
        #expect(SourceLanguage.detect(fileName: "tool", firstLine: python)?.id == "python")
        let arguments = "#!/usr/bin/env python3 " + String(repeating: "-v ", count: 100)
        #expect(SourceLanguage.detect(fileName: "tool", firstLine: arguments)?.id == "python")
    }

    @Test("本文から見分けるときは最初の行だけを読み、名前で決まるなら本文を読まない")
    func detectsFromText() {
        #expect(SourceLanguage.detect(fileName: "tool", text: { "#!/bin/sh\n#!/usr/bin/env python3\n" })?.id == "shell")
        #expect(SourceLanguage.detect(fileName: "tool", text: { "\n#!/bin/sh\n" }) == nil)
        #expect(SourceLanguage.detect(fileName: "tool", text: { "#!/usr/bin/env ruby\r\nputs 1\r\n" })?.id == "ruby")
        var reads = 0
        let language = SourceLanguage.detect(
            fileName: "main.swift",
            text: {
                reads += 1
                return "#!/bin/sh"
            })
        #expect(language?.id == "swift")
        #expect(reads == 0)
    }

    @Test("大文字の .C と .H は C++、小文字は C として読む")
    func capitalCExtensions() {
        #expect(SourceLanguage.detect(fileName: "main.C")?.id == "cpp")
        #expect(SourceLanguage.detect(fileName: "main.H")?.id == "cpp")
        #expect(SourceLanguage.detect(fileName: "main.C.orig")?.id == "cpp")
        #expect(SourceLanguage.detect(fileName: "main.c")?.id == "c")
        #expect(SourceLanguage.detect(fileName: "main.h")?.id == "c")
    }

    @Test(".cfg は INI と分かっている名前だけに色を付ける")
    func configurationNames() {
        #expect(SourceLanguage.detect(fileName: "setup.cfg")?.id == "ini")
        #expect(SourceLanguage.detect(fileName: "tox.ini")?.id == "ini")
        #expect(SourceLanguage.detect(fileName: ".flake8")?.id == "ini")
        #expect(SourceLanguage.detect(fileName: "haproxy.cfg") == nil)
        #expect(SourceLanguage.detect(fileName: "nginx.conf") == nil)
    }

    @Test("色付けの上限を超えたソースは切らずに色なしで全部出す")
    func oversizedSource() {
        let text = String(repeating: "let a = 1\n", count: 20_001)
        let body = PlainTextConverter.convert(text, fileName: "big.swift").body
        #expect(body == "<pre class=\"surimono-plain\">\(text)</pre>")
    }

    @Test("閉じていない文字列や極端に長い 1 行でも色付けが終わる", .timeLimit(.minutes(1)))
    func hostileSource() {
        let unterminated = "let a = \"never closed\nlet b = /* open\n"
        #expect(PlainTextConverter.convert(unterminated, fileName: "a.swift").body.contains("never closed"))
        let minified = String(repeating: "var a=function(b){return b+1};", count: 6000)
        #expect(PlainTextConverter.convert(minified, fileName: "app.min.js").body.contains("hl-keyword"))
    }
}

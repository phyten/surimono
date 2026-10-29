import Foundation
import Testing

@testable import SurimonoCore

struct SyntaxHighlighterTests {
    static let languages =
        "swift javascript typescript python ruby go rust java kotlin c cpp csharp objectivec php shell json yaml toml ini html xml css sql dockerfile makefile diff lua"
        .split(separator: " ").map(String.init)

    @Test(
        "別名と属性付きの言語名を正規化する",
        arguments: [
            ("JS", "javascript"), ("c++", "cpp"), ("swift title=a.swift", "swift"),
            ("js{1,3}", "javascript"), ("PY,extra", "python"), ("shellsession", "shell"),
            ("objc", "objectivec"), ("C#", "csharp"), ("yml", "yaml"), ("plist", "xml"),
        ])
    func aliases(info: String, expected: String) {
        #expect(SyntaxHighlighter.canonicalLanguage(for: info) == expected)
    }

    @Test("未知の言語と上限を超えたコードはハイライトしない")
    func fallback() {
        #expect(SyntaxHighlighter.highlight("x", language: "unknown") == nil)
        #expect(SyntaxHighlighter.canonicalLanguage(for: "") == nil)
        #expect(SyntaxHighlighter.highlight(String(repeating: "a", count: 200_001), language: "swift") == nil)
        #expect(SyntaxHighlighter.highlight(String(repeating: "😀", count: 100_001), language: "swift") == nil)
    }

    @Test(
        "各言語の代表的なトークンを識別する",
        arguments: [
            ("swift", "let x = \"a\\\"b\" // c", "keyword", "let"),
            ("javascript", "const n = `a\nb`;", "string", "`a\nb`"),
            ("typescript", "interface User {}", "type", "User"),
            ("python", "@cache\ndef f(): return r'''a\nb'''", "string", "r'''a\nb'''"),
            ("ruby", "puts 'hi' # note", "builtin", "puts"),
            ("go", "var s = `a\nb`", "string", "`a\nb`"),
            ("rust", "let s = r#\"a\nb\"#;", "string", "r#\"a\nb\"#"),
            ("java", "public class Book {}", "keyword", "public"),
            ("kotlin", "val n: Int = 1", "type", "Int"),
            ("c", "#include <stdio.h>", "meta", "#include <stdio.h>"),
            ("cpp", "std::vector<int> v;", "type", "int"),
            ("csharp", "var s = @\"a\"\"b\";", "string", "@\"a\"\"b\""),
            ("objectivec", "@interface Book", "meta", "@interface"),
            ("php", "echo $name;", "variable", "$name"),
            ("shell", "echo ${HOME}", "variable", "${HOME}"),
            ("json", "{\"key\": \"value\"}", "attr", "\"key\""),
            ("yaml", "- key: &ref true # c", "attr", "key"),
            ("toml", "[[books]]\nname = 'x'", "section", "[[books]]"),
            ("ini", "[main]\nkey=true", "attr", "key"),
            ("html", "<a href=\"x\">&amp;</a>", "attr", "href"),
            ("xml", "<?xml version=\"1.0\"?>", "meta", "<?xml version=\"1.0\"?>"),
            ("css", "a { width: 12px; color: #fff; }", "number", "12px"),
            ("sql", "sElEcT * FROM books", "keyword", "sElEcT"),
            ("dockerfile", "from alpine\nRUN echo $HOME", "keyword", "from"),
            ("makefile", "build:\n\techo $(VAR)", "section", "build"),
            ("diff", "+++ b/file\n+added\n-removed\n@@ x", "addition", "+added"),
            ("lua", "local x = nil -- c", "literal", "nil"),
        ])
    func representative(language: String, code: String, kind: String, token: String) {
        let html = SyntaxHighlighter.highlight(code, language: language)
        #expect(html?.contains("<span class=\"hl-\(kind)\">\(HTML.escape(token))</span>") == true)
    }

    @Test("全言語で記号とランダム入力を欠落なく安全に往復できる", arguments: languages)
    func roundTrip(language: String) throws {
        var state: UInt64 = 42
        let alphabet = Array("abc日本語é😀012_\n\r\t <> &\"'`#$@/\\*[]{}():;=+-.!~")
        var random = ""
        for _ in 0..<2048 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            random.append(alphabet[Int(state % UInt64(alphabet.count))])
        }
        for code in [
            random, "<>&\"'", "/* unclosed\n<> &", "\"unclosed\nnext", "<!-- x\n",
            String(repeating: "#\"'/* ", count: 100),
        ] {
            let html = try #require(SyntaxHighlighter.highlight(code, language: language))
            let escaped = html.replacingOccurrences(
                of: #"<span class="hl-[a-z]+">|</span>"#, with: "", options: .regularExpression)
            #expect(escaped == HTML.escape(code))
            let restored = escaped.replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            #expect(restored == code)
            #expect(html.components(separatedBy: "<span ").count == html.components(separatedBy: "</span>").count)
            #expect(html == SyntaxHighlighter.highlight(code, language: language))
        }
    }

    @Test("全言語で上限付近の入力を時間内に処理する", .timeLimit(.minutes(1)), arguments: languages)
    func large(language: String) {
        let code = String(repeating: "x    /\"#<&\n", count: 18_000)
        #expect(SyntaxHighlighter.highlight(code, language: language) != nil)
    }
}

extension SyntaxHighlighterTests {
    @Test(
        "コメントと特殊な文字列を一つのトークンにする",
        arguments: [
            ("swift", "/* a\n/* b */ c */", "comment"),
            ("rust", "/* a\n/* b */ c */", "comment"),
            ("java", "/* a\nb */", "comment"),
            ("lua", "--[[a\nb]]", "comment"),
            ("swift", "\"\"\"a\nb\"\"\"", "string"),
            ("swift", "#\"a\nb\"#", "string"),
            ("swift", "##\"a\\##\"b\"##", "string"),
            ("python", "rb\"a\\\"b\"", "string"),
            ("python", "f\"\"\"a\nb\"\"\"", "string"),
            ("rust", "r\"a\\\"", "string"),
            ("csharp", "@\"a\nb\"", "string"),
            ("html", "<!-- a\nb -->", "comment"),
            ("html", "<!DOCTYPE html>", "meta"),
        ])
    func multiline(language: String, token: String, kind: String) {
        #expect(
            SyntaxHighlighter.highlight(token, language: language)
                == "<span class=\"hl-\(kind)\">\(HTML.escape(token))</span>")
    }

    @Test(
        "未終了の文字列は行末で閉じ次の行を解析する",
        arguments: [
            ("swift", "\"bad", "let"), ("swift", "\"\"\"bad", "let"), ("swift", "#\"bad", "let"),
            ("python", "'''bad", "def"), ("javascript", "`bad", "const"),
            ("rust", "r###\"bad", "let"), ("csharp", "@\"bad", "var"),
        ])
    func unterminatedString(language: String, opening: String, keyword: String) {
        let result = SyntaxHighlighter.highlight(opening + "\n" + keyword + " x", language: language)
        #expect(result?.hasPrefix("<span class=\"hl-string\">\(HTML.escape(opening))</span>\n") == true)
        #expect(result?.contains("<span class=\"hl-keyword\">\(keyword)</span>") == true)
    }

    @Test("未終了のコメントは入力末尾で閉じる", arguments: ["swift", "rust", "java", "css"])
    func unterminatedComment(language: String) {
        #expect(
            SyntaxHighlighter.highlight("/* a\nb <&", language: language)
                == "<span class=\"hl-comment\">/* a\nb &lt;&amp;</span>")
    }

    @Test(
        "数値の基数と指数と区切りと接尾辞を保持する",
        arguments: ["42", "0xff", "0b1010", "0o755", "1_000", "3.14", ".5", "1.2e-3", "42u", "23L", "1.0f", "7u64"])
    func numbers(token: String) {
        #expect(SyntaxHighlighter.highlight(token, language: "cpp") == "<span class=\"hl-number\">\(token)</span>")
    }

    @Test("CSSのプロパティと色と単位と指定を識別する")
    func css() throws {
        let html = try #require(
            SyntaxHighlighter.highlight(
                "@media print { a { color: #fff; width: 12.5px !important; } }", language: "css"))
        for (kind, token) in [
            ("keyword", "@media"), ("attr", "color"), ("number", "#fff"), ("number", "12.5px"),
            ("keyword", "!important"),
        ] {
            #expect(html.contains("<span class=\"hl-\(kind)\">\(token)</span>"))
        }
    }

    @Test("JSONはキーと値を区別する")
    func json() {
        #expect(
            SyntaxHighlighter.highlight("{\"k\": \"v\"}", language: "json")
                == "{<span class=\"hl-attr\">&quot;k&quot;</span>: <span class=\"hl-string\">&quot;v&quot;</span>}")
    }

    @Test("YAMLの行頭キーとアンカーとコメントを識別する")
    func yaml() throws {
        let html = try #require(
            SyntaxHighlighter.highlight(
                "---\n- key: &ref true # c\ncopy: *ref\nurl: https://example.test\n...", language: "yaml"))
        for (kind, token) in [
            ("meta", "---"), ("attr", "key"), ("variable", "&ref"), ("literal", "true"), ("comment", "# c"),
            ("variable", "*ref"), ("meta", "..."),
        ] {
            #expect(html.contains("<span class=\"hl-\(kind)\">\(HTML.escape(token))</span>"))
        }
        #expect(!html.contains("hl-attr\">https"))
    }

    @Test("シェルの語中のシャープはコメントにしない")
    func shell() throws {
        let html = try #require(SyntaxHighlighter.highlight("echo a#b $VAR ${HOME} $1 # c", language: "shell"))
        #expect(html.contains("a#b"))
        for token in ["$VAR", "${HOME}", "$1"] { #expect(html.contains("<span class=\"hl-variable\">\(token)</span>")) }
        #expect(html.hasSuffix("<span class=\"hl-comment\"># c</span>"))
    }

    @Test(
        "属性とデコレータとshebangをメタ情報にする",
        arguments: [
            ("swift", "@MainActor"), ("java", "@Override"), ("kotlin", "@JvmStatic"),
            ("python", "@cache"), ("typescript", "@Component"), ("rust", "#[derive(Debug)]"),
            ("rust", "#![allow(unused)]"), ("shell", "#!/bin/sh"),
        ])
    func metadata(language: String, token: String) {
        #expect(
            SyntaxHighlighter.highlight(token, language: language)
                == "<span class=\"hl-meta\">\(HTML.escape(token))</span>")
    }

    @Test("HTMLは要素と属性と値と文字参照を区別しスクリプト本文を保つ")
    func markup() throws {
        let html = try #require(SyntaxHighlighter.highlight("<a href=\"x\">&amp;</a>", language: "html"))
        #expect(
            html
                == "&lt;<span class=\"hl-tag\">a</span> <span class=\"hl-attr\">href</span>=<span class=\"hl-string\">&quot;x&quot;</span>&gt;<span class=\"hl-literal\">&amp;amp;</span>&lt;/<span class=\"hl-tag\">a</span>&gt;"
        )
        let script = try #require(
            SyntaxHighlighter.highlight("<script>if (a < b) x = '<fake>';</script><p>x</p>", language: "html"))
        #expect(script.contains("if (a &lt; b) x = &#39;&lt;fake&gt;&#39;;"))
        #expect(script.contains("hl-tag\">p</span>"))
    }

    @Test(
        "diffの各行を分類して改行を保持する",
        arguments: [
            ("diff a b", "meta"), ("index a..b", "meta"), ("+++ b", "meta"), ("--- a", "meta"),
            ("+new", "addition"), ("-old", "deletion"), ("@@ -1 +1 @@", "section"),
        ])
    func diff(line: String, kind: String) {
        #expect(
            SyntaxHighlighter.highlight(line + "\n", language: "diff") == "<span class=\"hl-\(kind)\">\(line)</span>\n")
    }

    @Test("病的な区切り文字や空白でも走査が進む", .timeLimit(.minutes(1)))
    func adversarial() {
        for language in ["swift", "rust", "python", "makefile", "html"] {
            for code in [
                String(repeating: "#", count: 200_000), String(repeating: ":", count: 200_000),
                "x" + String(repeating: " ", count: 199_999),
            ] {
                #expect(SyntaxHighlighter.highlight(code, language: language) != nil)
            }
        }
        let rawOpeners = (1...500).map { "r" + String(repeating: "#", count: $0) + "\"\n" }.joined()
        #expect(SyntaxHighlighter.highlight(rawOpeners, language: "rust") != nil)
    }
}

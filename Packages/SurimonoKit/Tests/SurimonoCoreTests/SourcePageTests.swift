import Foundation
import Testing

@testable import SurimonoCore

@Suite(.timeLimit(.minutes(1)))
struct SourcePageTests {
    @Test("ソースの各行に文字を増やさず、最後の行に合わせた桁と字下げを組む")
    func numberedLines() {
        let input = "\tlet a = 1\n" + String(repeating: "\n", count: 8) + "// 最後\n"
        let fragment = PlainTextConverter.convert(input, fileName: "a.swift")
        let html = CodeBlockMarkup.apply(CodeStyle(), to: fragment.body, language: fragment.sourceLanguage)
        #expect(CodeBlockMarkup.containsCode(fragment.body))
        #expect(html.contains("--source-digits:2"))
        #expect(html.contains("--source-indent:6ch"))
        #expect(html.components(separatedBy: "class=\"source-line\"").count - 1 == 10)
        #expect(html.replacing(/<[^>]+>/, with: "") == input)
    }

    @Test("既定の番号・5行ごと・番号なしを区別し、色や変更の印が行をまたいでも本文が残る")
    func overrides() {
        let fragment = PlainTextConverter.convert("/* open\n\n\tinside\n*/\nlet a = 1\n", fileName: "a.swift")
        let marked = FragmentChanges.identifyingBlocks(in: fragment.body, for: [.init(blockID: "lines-2-2")])
        let style = CodeStyle(block: CodeBlockOptions(lineNumbers: .everyFive))
        let pages = CodeBlockMarkup.apply(style, to: marked, language: fragment.sourceLanguage)
        #expect(pages.components(separatedBy: "class=\"source-no\"").count - 1 == 1)
        #expect(pages.contains("<use href=\"#sd5\""))
        #expect(pages.contains("<path id=\"sd5\""))
        #expect(pages.contains("data-surimono-block=\"lines-2-2\""))
        #expect(
            !CodeBlockMarkup.apply(CodeStyle(block: CodeBlockOptions()), to: marked, language: fragment.sourceLanguage)
                .contains("source-no"))
        #expect(pages.replacing(/<[^>]+>/, with: "") == "/* open\n\n\tinside\n*/\nlet a = 1\n")
    }

    @Test("コメントの中で終わる末尾改行を余分な空行にせず、先頭の空行は残す")
    func emptyLines() {
        let fragment = PlainTextConverter.convert("\n/* open\n", fileName: "a.swift")
        let marked = FragmentChanges.identifyingBlocks(in: fragment.body, for: [.init(blockID: "lines-0-0")])
        let page = CodeBlockMarkup.apply(CodeStyle(), to: marked, language: fragment.sourceLanguage)
        #expect(page.contains("data-surimono-block=\"lines-0-0\""))
        #expect(page.components(separatedBy: "class=\"source-line\"").count - 1 == 2)
        #expect(page.replacing(/<[^>]+>/, with: "") == "\n/* open\n")
    }

    @Test("謄写版のソースには等幅 Osaka を使い、欧文書体を替えるとタイプライターが優先する")
    func mimeograph() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "mimeograph" })
        let family = "pre.surimono-source > code { font-family:"
        let source = HTMLDocumentBuilder.styleSheet(theme: theme, language: "ko", sourcePage: true)
        #expect(source.contains(family + " \"Osaka-Mono\", Menlo, monospace;"))
        #expect(!HTMLDocumentBuilder.styleSheet(theme: theme).contains(family))
        let latex = HTMLDocumentBuilder.styleSheet(theme: theme, typeface: .latex, sourcePage: true)
        #expect(latex.contains(family + " var(--surimono-western)"))
        #expect(latex.contains("--surimono-western: \"Surimono Computer Modern Typewriter\",;"))
    }

    @Test("行の組版で HTML の上限に達したら残りを展開する前に知らせる")
    func boundsExpansion() throws {
        struct Limit: Error {}
        let fragment = PlainTextConverter.convert(String(repeating: "a\n", count: 8_000), fileName: "a.swift")
        let total = CodeBlockMarkup.apply(CodeStyle(), to: fragment.body, language: fragment.sourceLanguage).utf8.count
        var checks: [Int] = []
        #expect(throws: Limit.self) {
            try CodeBlockMarkup.apply(CodeStyle(), to: fragment.body, language: fragment.sourceLanguage) { bytes in
                checks.append(bytes)
                throw Limit()
            }
        }
        #expect(checks.count == 1)
        let first = try #require(checks.first)
        #expect(first < total / 2)
    }

    @Test("短い二十万行をすべて組み、色付けの上限でも末尾を残す")
    func manyShortLines() {
        let input = String(repeating: "a\n", count: 199_999) + "last"
        let fragment = PlainTextConverter.convert(input, fileName: "a.ts")
        let html = CodeBlockMarkup.apply(CodeStyle(), to: fragment.body, language: fragment.sourceLanguage)
        #expect(!html.contains("hl-"))
        #expect(html.contains("--source-digits:6"))
        #expect(html.hasSuffix("last</span></span></code></pre>"))
    }
}

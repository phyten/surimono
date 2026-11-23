import Foundation
import RobustnessSupport
import Testing

@testable import SurimonoFormats

/// The inputs that crashed or stalled a reader in `make robustness`, minimised. Each is read on a 512 KiB thread, as
/// the app reads documents: the reader must finish, keep the rest of the document, and say that something was cut.
// Under AddressSanitizer the ten-thousand-level LaTeX list alone took 100 seconds.
@Suite(.timeLimit(.minutes(StackSpace.sanitizerFactor > 1 ? 10 : 1)))
struct ReaderLimitTests {
    private func onSmallStack<Value: Sendable>(
        limit: Duration = .seconds(10), _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        // The limits are about hangs, which took seconds to minutes. These tests run beside the others in
        // `make test-kit`, so each limit is three times what the input needs alone; a sanitizer slows the readers
        // several times over.
        let limit = limit * 3 * (StackSpace.sanitizerFactor > 1 ? 10 : 1)
        guard case .finished(let value, _) = try await SmallStack.run(limit: limit, body) else {
            Issue.record("did not finish within \(limit)")
            throw CancellationError()
        }
        return value
    }

    @Test("一万重の引用の Markdown でも落ちず、深すぎる塊だけを原文で残して後ろの段落を読む")
    func deepMarkdownQuotes() async throws {
        let fragment = try await onSmallStack {
            MarkdownConverter.convert("Before.\n\n" + String(repeating: "> ", count: 10_000) + "deep\n\nAfter.\n")
        }
        #expect(fragment.body.contains("<p>Before.</p>"))
        #expect(fragment.body.contains("<p>After.</p>"))
        #expect(fragment.body.contains("<pre class=\"markdown-unread\">"))
        #expect(fragment.body.contains("&gt; &gt; &gt;"))
        #expect(fragment.readingIssues == [StackSpace.limitIssue])
    }

    @Test("引用が百段の Markdown は、末尾の句読点によらず同じように入れ子の上限を知らせる", arguments: ["x", "x."])
    func nestingLimitIgnoresPunctuation(_ last: String) async throws {
        let text = String(repeating: ">", count: 100) + last + "\n"
        let fragment = try await onSmallStack { MarkdownConverter.convert(text) }
        #expect(fragment.readingIssues == [StackSpace.limitIssue])
        #expect(MarkdownNesting.isShallow(String(repeating: ">", count: 97) + last))
        #expect(!MarkdownNesting.isShallow(String(repeating: ">", count: 99) + last))
    }

    @Test("千重に字下げした Markdown のリストでも落ちない")
    func deepMarkdownLists() async throws {
        let text = (0..<1_000).map { String(repeating: " ", count: $0 * 2) + "- x\n" }.joined() + "\nAfter.\n"
        let fragment = try await onSmallStack { MarkdownConverter.convert(text) }
        #expect(fragment.body.contains("<p>After.</p>"))
        #expect(fragment.readingIssues == [StackSpace.limitIssue])
    }

    @Test("浅い Markdown は入れ子の上限に触れず、そのまま組む")
    func ordinaryMarkdownIsUntouched() async throws {
        let text =
            (0..<8).map { String(repeating: " ", count: $0 * 2) + "- level \($0)\n" }.joined()
            + "\n> > > quoted *emphasis*\n"
        let fragment = try await onSmallStack { MarkdownConverter.convert(text) }
        #expect(!fragment.body.contains("markdown-unread"))
        #expect(fragment.readingIssues.isEmpty)
        #expect(fragment.body.components(separatedBy: "<ul>").count - 1 == 8)
    }

    @Test("深く入れ子になった Markdown を目次として調べても落ちない")
    func deepMarkdownIncludes() async throws {
        let text = String(repeating: "> ", count: 10_000) + "[a](a.md)\n"
        let includes = try await onSmallStack { MarkdownIncludes(markdown: text) != nil }
        #expect(!includes)
    }

    @Test("一万重の itemize の LaTeX でも落ちず、後ろの本文を読み、展開の上限を知らせる")
    func deepLaTeXLists() async throws {
        let tex =
            "\\documentclass{article}\\begin{document}"
            + String(repeating: "\\begin{itemize}\\item ", count: 10_000) + "deep"
            + String(repeating: "\\end{itemize}", count: 10_000) + "\n\nAfter the lists.\\end{document}"
        let fragment = try await onSmallStack(limit: .seconds(30)) {
            LaTeXConverter.convert(tex, fontIndex: InstalledFontIndex(faces: [:]))
        }
        #expect(fragment.body.contains("After the lists."))
        #expect(fragment.readingIssues.contains("LaTeX expansion limit reached"))
    }

    @Test("千重の \\textbf と自分を開く環境の LaTeX でも落ちない")
    func deepLaTeXGroups() async throws {
        let tex =
            "\\newenvironment{e}{\\begin{e}}{\\end{e}}\\begin{document}"
            + String(repeating: "\\textbf{", count: 1_000) + "x" + String(repeating: "}", count: 1_000)
            + "\\begin{e}y\\end{e} After.\\end{document}"
        let fragment = try await onSmallStack(limit: .seconds(30)) {
            LaTeXConverter.convert(tex, fontIndex: InstalledFontIndex(faces: [:]))
        }
        #expect(fragment.body.contains("After."))
        #expect(fragment.readingIssues.contains("LaTeX expansion limit reached"))
    }

    @Test("千重の指示の reStructuredText でも落ちず、読めなかった記法として数える")
    func deepRSTDirectives() async throws {
        let text = (0..<1_000).map { String(repeating: "   ", count: $0) + ".. note::\n\n" }.joined()
        let fragment = try await onSmallStack(limit: .seconds(30)) { RSTConverter.convert("Before.\n\n" + text) }
        #expect(fragment.body.contains("Before."))
        #expect(!fragment.readingIssues.isEmpty)
    }

    @Test("NUL のある行にコードがある Markdown でも落ちず、NUL は置換文字になる")
    func nulBeforeCodeSpan() async throws {
        let fragment = try await onSmallStack { MarkdownConverter.convert("a\u{0}\u{0}\u{0} `b` c\n") }
        #expect(fragment.body.contains("<code>b</code>"))
        #expect(fragment.body.contains("\u{FFFD}\u{FFFD}\u{FFFD}"))
    }

    @Test("複数行のリンクの題の後で、行をまたぐコードの範囲が行の終わりを越えても落ちない")
    func codeSpanPastLineEnd() {
        let fragment = MarkdownConverter.convert("[l](p\n\"t\")\n`c\nd``c`\n")
        // CommonMark reads the code span to the single backtick, two lines down.
        #expect(fragment.body.contains("<code>c d``c</code>"))
        #expect(fragment.body.contains(#"<a href="p" title="t">l</a>"#))
    }

    @Test("二万個の _ が続く Markdown も時間内に読み、メールアドレスの自動リンクは変わらない")
    func underscoreRun() async throws {
        let text = "a@b " + String(repeating: "_", count: 20_000) + "\n\nmail me@example.com or x_y.z@a.co.\n"
        let fragment = try await onSmallStack(limit: .seconds(5)) { MarkdownConverter.convert(text) }
        #expect(fragment.body.contains("<a href=\"mailto:me@example.com\">me@example.com</a>"))
        #expect(fragment.body.contains("<a href=\"mailto:x_y.z@a.co\">x_y.z@a.co</a>"))
    }

    @Test("閉じない \\( と {++ と == が 1 行に続く Markdown も時間内に読む", arguments: [#"\("#, "{++", "==a "])
    func unclosedOpeners(_ opener: String) async throws {
        let text = String(repeating: opener, count: 12_000) + "\n\nAfter \\(x\\) and {++y++} and ==z==.\n"
        let fragment = try await onSmallStack(limit: .seconds(5)) { MarkdownConverter.convert(text) }
        #expect(fragment.body.contains("<ins class=\"critic\">y</ins>"))
        #expect(fragment.body.contains("<mark>z</mark>"))
    }

    @Test("波括弧のある行が八千続く段落の Markdown も時間内に読む")
    func bracedParagraph() async throws {
        let text = String(repeating: "{{< include self$.md >}}\nlf.md\n", count: 8_192)
        let fragment = try await onSmallStack(limit: .seconds(10)) { MarkdownConverter.convert(text) }
        #expect(fragment.body.contains("include self"))
    }

    @Test(
        "波括弧のある行が続く段落の終わりにコードや別行の数式があっても、時間内に読む",
        arguments: ["`code` end", "$$x$$"])
    func bracedParagraphEndingInCode(_ last: String) async throws {
        // Searched again from every line, 16,384 lines took about 25 seconds; once per paragraph, under one.
        let text = String(repeating: "a {b} c\n", count: 16_384) + last + "\n"
        let fragment = try await onSmallStack(limit: .seconds(2)) { MarkdownConverter.convert(text) }
        #expect(fragment.body.contains("a {b} c"))
    }

    @Test("波括弧のある行が続く段落の終わりに複数行のリンクの題があっても、時間内に読む")
    func bracedParagraphEndingInLinkTitle() async throws {
        // Searched again from every line, the link destination's line break made this quadratic.
        let text = String(repeating: "a {x} b\n", count: 16_384) + "[note](page.html\n\"Title\") end\n"
        let fragment = try await onSmallStack(limit: .seconds(2)) { MarkdownConverter.convert(text) }
        #expect(fragment.body.contains("a {x} b"))
        #expect(fragment.body.contains(#"title="Title""#))
    }

    @Test("複数行のリンクの題のある段落でも、その後ろの行から始まる複数行の校正を読む")
    func revisionAfterLinkTitle() {
        let fragment = MarkdownConverter.convert("a {x}\n[l](p.html\n\"t\") b\nc {x}\nd {++added\nmore++} e\n")
        #expect(fragment.body.contains("<ins class=\"critic\">added"))
    }

    @Test("段落をまたぐ CriticMarkup は、途中の行から始まっても読む")
    func criticAcrossLinesAfterBraces() {
        let fragment = MarkdownConverter.convert("a {b} c\nd {++added\nmore++} e\n")
        #expect(fragment.body.contains("<ins class=\"critic\">"))
        #expect(fragment.body.contains("more"))
    }

    @Test("四万個の * が続く Djot でも落ちず、深すぎる強調を文字で残す")
    func asteriskRunDjot() async throws {
        let fragment = try await onSmallStack(limit: .seconds(20)) {
            try DjotConverter.convert(String(repeating: "*", count: 40_000) + "\n\nAfter.\n")
        }
        #expect(fragment.body.contains("After."))
    }

    @Test("一万重のテンプレートの MediaWiki でも落ちず、後ろの段落を読む")
    func deepWikiTemplates() async throws {
        let text = String(repeating: "{{", count: 10_000) + "x" + String(repeating: "}}", count: 10_000) + "\n\nAfter."
        let fragment = try await onSmallStack { MediaWikiConverter.convert(text, imageExists: { _ in false }) }
        #expect(fragment.body.contains("After."))
    }

    @Test("使わない metadata が一万重の Notebook も読み、深すぎる部分を省いたと知らせる")
    func deepNotebookMetadata() async throws {
        let text =
            #"{"nbformat":4,"metadata":"# + String(repeating: #"{"a":"#, count: 10_000) + "1"
            + String(repeating: "}", count: 10_000)
            + #","cells":[{"cell_type":"markdown","metadata":{},"source":["Kept"]}]}"#
        let fragment = try await onSmallStack { try NotebookConverter.convert(text) }
        #expect(fragment.body.contains("Kept"))
        #expect(fragment.readingIssues == [StackSpace.omissionIssue])
    }

    @Test("一万重の入れ子の JSON だけの Notebook は、落ちずに Notebook でないと知らせる")
    func deepNotebookJSON() async throws {
        let text = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        let result = try await onSmallStack { () -> NotebookError? in
            do {
                _ = try NotebookConverter.convert(text)
                return nil
            } catch let error as NotebookError {
                return error
            }
        }
        #expect(result == .invalidStructure)
    }

    @Test("閉じない < が続く HTML でも、題名と見出しを時間内に読む")
    func unterminatedTags() async throws {
        let html =
            String(repeating: "<a ", count: 20_000) + "<title>x</title>" + String(repeating: "<title ", count: 20_000)
        let found = try await onSmallStack(limit: .seconds(5)) {
            (DocumentOutline.title(ofHTML: html), DocumentOutline.headings(inHTML: html).count)
        }
        #expect(found.0 == "x")
        #expect(found.1 == 0)
    }

    @Test("題名は閉じたタグのある最初の title から読む")
    func titleStillReadsTheFirstClosedTitle() {
        #expect(
            DocumentOutline.title(ofHTML: "<titles>no</titles><TITLE lang=en>A &amp; B</TITLE><title>C</title>")
                == "A & B")
        #expect(DocumentOutline.title(ofHTML: "<title>unclosed") == nil)
    }

    @Test("閉じない [ と < が二万続く Quarto の行も時間内に読む", arguments: ["[", "<"])
    func quartoRuns(_ opener: String) async throws {
        let text = "# Title\n\n" + String(repeating: opener, count: 20_000) + "\n"
        let fragment = try await onSmallStack(limit: .seconds(5)) { ComputationalMarkdown.convert(text) }
        #expect(fragment.body.contains("Title"))
    }

    @Test("二十万個の [ が 1 行に続く Quarto も時間内に読む")
    func longQuartoLine() async throws {
        let text = "# Title\n\n" + String(repeating: "[", count: 200_000) + "\n"
        let fragment = try await onSmallStack(limit: .seconds(10)) { ComputationalMarkdown.convert(text) }
        #expect(fragment.body.contains("Title"))
    }

    @Test("文の後ろに一万七千個の ` が続く R Markdown と Markdown も時間内に読む")
    func backtickRunAfterText() async throws {
        // Found by `make robustness` (seed 20261124): the code-span expression's backtracking over each shorter
        // opening took 6 seconds on this line.
        let text = String(repeating: "=a ", count: 3_870) + String(repeating: "`", count: 17_059) + "\n"
        let fragment = try await onSmallStack(limit: .seconds(2)) {
            (ComputationalMarkdown.convert(text).body, MarkdownConverter.convert(text).body)
        }
        #expect(fragment.0.contains("=a =a"))
        #expect(fragment.1.contains("=a =a"))
    }

    @Test("八千個の ` が 1 行に続く R Markdown も時間内に読む")
    func backtickRun() async throws {
        let text = "# Title\n\n" + String(repeating: "`", count: 8_192) + " r 1+1\n"
        let fragment = try await onSmallStack(limit: .seconds(5)) { ComputationalMarkdown.convert(text) }
        #expect(fragment.body.contains("Title"))
    }

    @Test(
        "AsciiDoc の表の千を超える結合・繰り返し・列の数は千として読む",
        arguments: [
            ("|===\n9999999+|a\n|===", #"colspan="1000""#),
            ("|===\n|x\n.88888+|b\n|===", #"rowspan="1000""#),
            ("|===\n99999999999999999999999+|a\n|===", #"colspan="1000""#),
            ("[separator=;]\n|===\n;x 5000+;y\n|===", #"colspan="1000""#),
            ("|===\na|x\n!===\n!a 5000+!y\n!===\n|===", #"colspan="1000""#),
            ("|===\n3+|a\n2.2+^.^|b\n|===", #"colspan="3""#),
        ])
    func asciiDocCellSpans(_ source: String, _ expected: String) async throws {
        let fragment = try await onSmallStack(limit: .seconds(10)) { try AsciiDocConverter.convert(source) }
        #expect(fragment.body.contains(expected))
    }

    @Test("AsciiDoc の千を超える列の数と列の繰り返しも千として読む", arguments: ["", "*"])
    func asciiDocColumnCounts(_ repeatMark: String) async throws {
        @Sendable func table(_ count: String) -> String {
            "[cols=\"\(count)\(repeatMark)\"]\n|===\n" + String(repeating: "|a ", count: 1_000) + "\n|==="
        }
        let capped = try await onSmallStack(limit: .seconds(10)) { try AsciiDocConverter.convert(table("9999999")) }
        let written = try AsciiDocConverter.convert(table("1000"))
        #expect(capped.body == written.body)
        #expect(written.body.components(separatedBy: "<td").count - 1 == 1_000)
    }

    @Test("AsciiDoc の列指定がいくつあっても、同梱パーサーが展開する列は合計千まで", arguments: [("600*", 2), ("999*", 10_000)])
    func asciiDocTotalColumns(_ spec: String, _ specCount: Int) throws {
        let host = ScriptConverterHost(
            "asciidoctor-4.2.1", bridge: "asciidoc-bridge", category: "Test", commonJS: false,
            testing: .init(
                beforeBridge: """
                    let columnsBuilt = 0;
                    const original = Parser.parseColspecs;
                    Parser.parseColspecs = function (records) {
                        // Stop a regressed bridge before it can expand the entire long fixture.
                        if (records.length > 100) throw new Error('unbounded parser call');
                        const columns = original.call(this, records);
                        columnsBuilt += columns.length;
                        return columns;
                    };
                    """,
                script: """
                    const readParts = documentParts;
                    documentParts = async source => ({ ...await readParts(source), revision: String(columnsBuilt) });
                    """))
        let specs = Array(repeating: spec, count: specCount).joined(separator: ",")
        let source = "[cols=\"\(specs)\"]\n|===\n" + String(repeating: "|x ", count: 1_000) + "\n|==="
        let fragment = try host.fragment(source, notice: "") { document in
            #expect(document.revision == "1000")
            return try AsciiDocMarkup.fragment(document)
        }
        #expect(fragment.body.matches(of: /<col\b/).count == 1_000)
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("AsciiDoc の千以下の列の指定は、上限を付けない同梱のパーサーと同じ表になる")
    func asciiDocColumnSpecsMatchTheParser() throws {
        let capped = ScriptConverterHost(
            "asciidoctor-4.2.1", bridge: "asciidoc-bridge", category: "Test", commonJS: false)
        let bundled = ScriptConverterHost(
            "asciidoctor-4.2.1", bridge: "asciidoc-bridge", category: "Test", commonJS: false,
            testing: .init(script: "globalThis.surimonoUncappedTables = true;"))
        var state: UInt64 = 20_261_124
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33) % bound
        }
        func spaced(_ text: String) -> String {
            text.map { String($0) + (next(4) == 0 ? " " : "") }.joined()
        }
        func number(_ value: Int) -> String { String(repeating: "0", count: next(3)) + String(value) }
        func cols() -> String {
            if next(3) == 0 { return spaced(number(next(5) == 0 ? 1_000 - next(2) : next(12))) }
            let specs = (0..<(1 + next(3))).map { _ -> String in
                let repeatCount = next(2) == 0 ? number(next(5) == 0 ? 1_000 - next(3) : 1 + next(9)) + "*" : ""
                let align = ["", "<", "^", ">", ".<", ".^", ".>", "<.>", "^.^", ">.<"][next(10)]
                let width = ["", "1", "2", "10", "25%", "~", "0012", "1001"][next(8)]
                let style = ["", "a", "e", "h", "l", "m", "s", "d", "v"][next(9)]
                return repeatCount + align + width + style
            }
            return spaced(specs.joined(separator: next(2) == 0 ? "," : ";"))
        }
        var differences: [String] = []
        for _ in 0..<100 {
            let source = "[cols=\"\(cols())\"]\n|===\n|a |b |c\n|d\n|==="
            let read = { (host: ScriptConverterHost) in
                try host.fragment(source, notice: "") { HTMLFragment(body: $0.html) }.body
            }
            if try read(capped) != read(bundled) { differences.append(source) }
        }
        #expect(differences.isEmpty, "\(differences.prefix(3))")
        func body(_ cols: String, _ host: ScriptConverterHost, cells: Int = 1) throws -> String {
            let source = "[cols=\"\(cols)\"]\n|===\n" + String(repeating: "|a ", count: cells) + "\n|==="
            return try host.fragment(source, notice: "") { HTMLFragment(body: $0.html) }.body
        }
        for separator in [",", ";"] {
            let exactly = ["", "00994*>.>2e", "003*^~", "12", "bad!", ""].joined(separator: separator)
            let reference = try body(exactly, bundled, cells: 1_000)
            let referenceColumns = reference.matches(of: /<col\b/).count
            #expect(referenceColumns == 1_000)
            #expect(try body(exactly, capped, cells: 1_000) == reference)
        }
        // A space before the repeat mark does not bypass the limit.
        #expect(try body("1001 *", capped) == body("1000*", bundled))
        #expect(try body("01001", capped) == body("01001", bundled))
    }

    @Test(
        "AsciiDoc のセルの本文・CSV の表・コードにある結合の指定らしい文字は、そのまま刷る",
        arguments: [
            ("|===\n|12000+|次\n|===", "12000+"),
            ("[format=csv]\n|===\n12000+,x\n|===", "12000+"),
            ("[separator=;]\n|===\n;12000+;x\n|===", "12000+"),
            ("Write the span:\n\n----\n12000+|wide cell\n----\n", "12000+|wide cell"),
            ("|===\n|`12000+|` x\n|===", "12000+"),
        ])
    func asciiDocTextIsUntouched(_ source: String, _ expected: String) throws {
        let fragment = try AsciiDocConverter.convert(source)
        #expect(fragment.body.contains(expected))
        #expect(!fragment.body.contains("1000+"))
    }

    @Test("十万行の Quarto も時間内に読む")
    func manyQuartoLines() async throws {
        let text = String(repeating: "x\n", count: 100_000)
        let fragment = try await onSmallStack(limit: .seconds(10)) { ComputationalMarkdown.convert(text) }
        #expect(fragment.body.contains("x"))
    }

    @Test("千重の表を入れ子にした Word 文書でも落ちず、時間内に読むかエラーにする")
    func deepWordTables() async throws {
        let data = Data(HostileInputs.cases(for: .docx).first { $0.name == "deep-tables" }?.bytes() ?? [])
        // Foundation's XML tree used to overflow the stack while it was freed; mammoth itself gives up on it.
        let finished = try await onSmallStack(limit: .seconds(30)) { () -> Bool in
            _ = try? DocxConverter.convert(data)
            return true
        }
        #expect(finished)
    }

    @Test("深すぎる XML の部品は Foundation で組み立てず、省いたと知らせる")
    func deepXMLIsNotParsed() throws {
        let deep = Data((String(repeating: "<a>", count: 300) + String(repeating: "</a>", count: 300)).utf8)
        let shallow = Data(
            (String(repeating: "<a x=\"1\"><b/>", count: 200) + String(repeating: "</a>", count: 200)).utf8)
        let (parsed, reached) = StackSpace.collectingOmission { DocxConverter.xmlDocument(deep) }
        #expect(parsed == nil)
        #expect(reached)
        let (kept, quiet) = StackSpace.collectingOmission { DocxConverter.xmlDocument(shallow) }
        // A malformed part, whose depth was never fully counted, is not built and not called too deep.
        let (malformed, notDeep) = StackSpace.collectingOmission {
            DocxConverter.xmlDocument(Data("<a><b></a>".utf8))
        }
        #expect(malformed == nil)
        #expect(!notDeep)
        // Exactly 256 levels, closed, and then a stray closing tag: malformed, not too deep.
        let reachedLimit = String(repeating: "<a>", count: 256) + String(repeating: "</a>", count: 256) + "</b>"
        let (stray, strayDeep) = StackSpace.collectingOmission { DocxConverter.xmlDocument(Data(reachedLimit.utf8)) }
        #expect(stray == nil)
        #expect(!strayDeep)
        #expect(kept != nil)
        #expect(!quiet)
    }

    static let xmlShapes: [(String, String)] = {
        let attributes: String = String(repeating: #"<a x="b>c" y='/>'>"#, count: 200)
        let closings: String = String(repeating: "</a>", count: 200)
        let comments: String = String(repeating: "<!-- <a><a> -->", count: 400)
        let sections: String = String(repeating: "<![CDATA[<a><a>]]>", count: 400)
        let openings: String = String(repeating: "<a>", count: 200)
        return [
            ("utf-8", attributes + closings), ("utf-8", "<r>" + comments + "</r>"),
            ("utf-8", "<r>" + sections + "</r>"), ("utf-16", openings + closings),
        ]
    }()

    @Test("XML の深さは、属性の >・コメント・CDATA・UTF-16 に惑わされずに数える", arguments: xmlShapes)
    func xmlDepthShapes(_ encoding: String, _ body: String) {
        func data(_ text: String) -> Data {
            let xml = "<?xml version=\"1.0\" encoding=\"\(encoding)\"?>" + text
            return encoding == "utf-16" ? xml.data(using: .utf16) ?? Data() : Data(xml.utf8)
        }
        #expect(DocxConverter.xmlDocument(data(body)) != nil)
        if encoding == "utf-16" {
            let deep = String(repeating: "<a>", count: 300) + String(repeating: "</a>", count: 300)
            #expect(DocxConverter.xmlDocument(data(deep)) == nil)
        }
    }

    @Test("深すぎる styles.xml の Word 文書も本文を読み、その部品を省いたと知らせる")
    func deepWordStyles() throws {
        let styles = String(repeating: "<a>", count: 300) + String(repeating: "</a>", count: 300)
        let data = Data(
            HostileInputs.docx(
                body: "<w:p><w:r><w:t>PaperCrane</w:t></w:r></w:p>",
                extra: [.init("word/styles.xml", Array(styles.utf8))]))
        let fragment = try DocxConverter.convert(data)
        #expect(fragment.body.contains("PaperCrane"))
        #expect(fragment.readingIssues == [StackSpace.omissionIssue])
    }

    // MARK: Valid documents print as before: protection against slow input comes from scanning, not from caps.

    @Test("Quarto の長い行でも、行の後ろの式・属性つきの範囲・脚注を読む")
    func longQuartoLineKeepsSyntax() async throws {
        let text = String(repeating: "word ", count: 5_000) + "`r 1+1` [red]{.red} ^[note text]\n"
        let fragment = try await onSmallStack { ComputationalMarkdown.convert(text) }
        #expect(fragment.body.contains("<code class=\"inline-expression\">1+1</code>"))
        #expect(fragment.body.contains("<span class=\"red\">red</span>"))
        #expect(fragment.body.contains("note text"))
        #expect(!fragment.body.contains("^[note text]"))
    }

    @Test("` が多い Quarto の行でも、コードの後ろの記法を読む")
    func manyBackticksKeepSyntax() async throws {
        let text = String(repeating: "`a` ", count: 300) + "[red]{.red}\n"
        let fragment = try await onSmallStack { ComputationalMarkdown.convert(text) }
        #expect(fragment.body.contains("<code>a</code>"))
        #expect(fragment.body.contains("<span class=\"red\">red</span>"))
    }

    @Test("Quarto の長いタグ・リンク先の中の @ は参照にしない")
    func longQuartoTagsAndDestinations() async throws {
        let title = String(repeating: "t", count: 1_500)
        let path = String(repeating: "p", count: 2_500)
        let text =
            "# A {#sec-a}\n\n<span title=\"\(title) @sec-a\">x</span>\n\n[x](https://example.com/\(path)@sec-a)\n"
        let fragment = try await onSmallStack { ComputationalMarkdown.convert(text) }
        #expect(fragment.body.contains("\(title) @sec-a"))
        #expect(fragment.body.contains("\(path)@sec-a"))
    }

    @Test("Quarto の長い脚注と属性つきの範囲も読む")
    func longQuartoFootnoteAndSpan() async throws {
        let note = String(repeating: "n", count: 1_500)
        let span = String(repeating: "s", count: 600)
        let text = "Text^[\(note)] and [\(span)]{.red}\n"
        let fragment = try await onSmallStack { ComputationalMarkdown.convert(text) }
        #expect(!fragment.body.contains("^[\(note)]"))
        #expect(fragment.body.contains(note))
        #expect(fragment.body.contains("<span class=\"red\">\(span)</span>"))
    }

    @Test("8,001 文字の削除とコメントも、反映後には刷らない")
    func longCriticMarkup() async throws {
        let deleted = String(repeating: "d", count: 8_001)
        let comment = String(repeating: "c", count: 8_001)
        let text = "a {--\(deleted)--} b {>>\(comment)<<} e\n"
        let shown = try await onSmallStack { MarkdownConverter.convert(text) }
        #expect(shown.body.contains("<del class=\"critic\">\(deleted)</del>"))
        let accepted = try await onSmallStack { MarkdownConverter.convert(text, proof: .accepted) }
        #expect(!accepted.body.contains(deleted))
        #expect(!accepted.body.contains(comment))
        #expect(accepted.body.contains("e"))
    }

    @Test("501 文字のハイライトと 2,001 文字の \\( \\) と \\[ \\] も読む")
    func longMarkAndFormulas() async throws {
        let marked = String(repeating: "m", count: 501)
        let formula = String(repeating: "a", count: 2_001)
        let text = "==\(marked)==\n\nInline \\(\(formula)\\) end.\n\nText \\[\(formula)\\] end.\n"
        let fragment = try await onSmallStack(limit: .seconds(30)) { MarkdownConverter.convert(text) }
        #expect(fragment.body.contains("<mark>\(marked)</mark>"))
        #expect(!fragment.body.contains("\\(a"))
        #expect(!fragment.body.contains("\\[a"))
    }

    @Test("段落の途中にコードがあっても、後ろの行から始まる複数行の校正を読む")
    func revisionAfterCodeSpan() {
        for text in ["a `code` b {x}\nc {++added\nmore++} d\n", "a `code\nspan` b\nc {++added\nmore++} d\n"] {
            let fragment = MarkdownConverter.convert(text)
            #expect(fragment.body.contains("<ins class=\"critic\">added"), "\(text)")
        }
    }

    @Test("脚注の中で深く入れ子になった Markdown でも落ちず、外の文書に知らせる")
    func deepMarkdownFootnote() async throws {
        let text = "Text[^1] after.\n\n[^1]: " + String(repeating: "> ", count: 10_000) + "deep\n"
        let fragment = try await onSmallStack { MarkdownConverter.convert(text) }
        #expect(fragment.body.contains("Text"))
        #expect(fragment.readingIssues == [StackSpace.limitIssue])
    }

    @Test("Quarto と Notebook の深すぎる Markdown も、入れ子の上限を知らせる")
    func nestingIssueReachesComputationalDocuments() async throws {
        let deep = String(repeating: "> ", count: 10_000) + "deep"
        let quarto = try await onSmallStack { ComputationalMarkdown.convert("# T\n\n\(deep)\n\nAfter.\n") }
        #expect(quarto.body.contains("After."))
        #expect(quarto.readingIssues == [StackSpace.limitIssue])
        let source = String(data: try JSONSerialization.data(withJSONObject: [deep]), encoding: .utf8) ?? "[]"
        let notebook =
            #"{"nbformat":4,"metadata":{},"cells":[{"cell_type":"markdown","metadata":{},"source":"#
            + source + #"},{"cell_type":"markdown","metadata":{},"source":"# + source + "}]}"
        let fragment = try await onSmallStack { try NotebookConverter.convert(notebook) }
        // Two deep cells, one notice for the document.
        #expect(fragment.readingIssues == [StackSpace.limitIssue])
    }

    @Test("四十重の脚注の Org も落ちず、深すぎる脚注を文字で残したと知らせる")
    func deepOrgFootnotes() async throws {
        let notes = String(repeating: "[fn:: a ", count: 40) + "core" + String(repeating: "]", count: 40)
        let fragment = try await onSmallStack { OrgConverter.convert("Line " + notes + " end.\n") }
        #expect(fragment.body.contains("end."))
        #expect(fragment.readingIssues == [StackSpace.limitIssue])
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SmallStackTests {
    @Test("取り消しハンドラーが待っていても、その解放前に期限切れが届く")
    func deadlineWithBlockedCancellation() async throws {
        let gate = DispatchSemaphore(value: 0)
        let releasedByCaller = Locked(false)
        let handlerEntered = AsyncStream<Void>.makeStream()
        let handlerDone = AsyncStream<Void>.makeStream()
        let workerDone = AsyncStream<Void>.makeStream()
        let work = AsyncStream<Void>.makeStream()

        let waiting = Locked(false)
        let outcome = try await SmallStack.withDeadline(limit: .milliseconds(500)) {
            defer { workerDone.continuation.finish() }
            await withTaskCancellationHandler {
                // The handler is registered by now. A deadline that fired before this would cancel a task with no
                // handler to block on, and the test would pass whatever the order of the deadline's two steps.
                waiting.value = true
                for await _ in work.stream {}
            } onCancel: {
                // Bound the wait so a regression fails without leaving a thread behind.
                handlerEntered.continuation.finish()
                releasedByCaller.value = gate.wait(timeout: .now() + 3) == .success
                work.continuation.finish()
                handlerDone.continuation.finish()
            }
        }
        try #require(waiting.value, "期限より前に取り消しハンドラーを登録できなかった")
        for await _ in handlerEntered.stream {}
        gate.signal()
        for await _ in handlerDone.stream {}
        for await _ in workerDone.stream {}
        guard case .timedOut = outcome else {
            Issue.record("期限切れが届かなかった")
            return
        }
        #expect(releasedByCaller.value)
    }
}

/// The JavaScript readers: a conversion its caller gave up on must not report a result or hand its context on.
struct ScriptConversionTests {
    @Test("取り消された変換はスクリプトを始めずに取り消しを返し、次の変換は読める")
    func cancelledConversion() async throws {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try DjotConverter.convert("_cancelled_")
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        #expect(await task.value)
        #expect(try DjotConverter.convert("_kept_").body.contains("<em>kept</em>"))
    }

    /// Holds the first `holding` conversion threads once their contexts have loaded, until the test lets them go
    /// on, and counts the threads that have finished. A caller gives up only when it is its turn and its thread is
    /// held, so the order does not depend on the machine's speed; every wait of the test's has a limit.
    private final class Gate: @unchecked Sendable {
        // `lock` guards `held` and `turn`; the semaphores need none.
        private let lock = NSLock()
        private let holding: Int
        private var held = 0
        private var turn = Int.max
        private let release = DispatchSemaphore(value: 0)
        private let finished = DispatchSemaphore(value: 0)

        init(holding: Int) { self.holding = holding }

        var testing: ScriptConverterHost.Testing {
            ScriptConverterHost.Testing(
                hook: { self.hook($0) }, givesUp: { self.lock.withLock { self.held >= self.turn } })
        }

        /// The caller of the `count`th conversion gives up once its thread is held.
        func giveUp(after count: Int) { lock.withLock { turn = count } }

        func keepWaiting() { lock.withLock { turn = .max } }

        private func hook(_ point: ScriptConverterHost.Testing.Point) {
            switch point {
            case .loaded:
                let holds = lock.withLock { () -> Bool in
                    guard held < holding else { return false }
                    held += 1
                    return true
                }
                // Not forever: a test that failed before releasing it must not leave the thread waiting for good.
                if holds { _ = release.wait(timeout: .now() + 60) }
            case .finished: finished.signal()
            }
        }

        /// Lets `count` held threads go on and waits until they have finished; false when they did not in time.
        func releaseAndWait(_ count: Int) -> Bool {
            for _ in 0..<count { release.signal() }
            for _ in 0..<count where finished.wait(timeout: .now() + 30) == .timedOut { return false }
            return true
        }
    }

    @Test("期限を過ぎた変換は文書のスクリプトを始めず、原文を示す")
    func lateConversionStartsNoScript() throws {
        let gate = Gate(holding: 1)
        let host = ScriptConverterHost("djot-0.3.2", bridge: "djot-bridge", category: "Test", testing: gate.testing)
        // The thread is held after loading until its caller has given up.
        gate.giveUp(after: 1)
        let late = try host.fragment("_late_", notice: "too large") { _ in HTMLFragment(body: "converted") }
        #expect(!late.body.contains("converted"))
        #expect(late.body.contains("late"))
        #expect(gate.releaseAndWait(1), "the given-up conversion's thread did not finish within 30 s")
        #expect(host.startedScripts == 0)
        gate.keepWaiting()
        let timely = try host.fragment("_timely_", notice: "too large") { _ in HTMLFragment(body: "converted") }
        #expect(timely.body == "converted")
        #expect(host.startedScripts == 1)
    }

    @Test("枠がすべて放棄した変換で埋まっていれば、四件目は待たずに原文を示す")
    func fourthDocumentDoesNotWait() async throws {
        let gate = Gate(holding: 3)
        let host = ScriptConverterHost("djot-0.3.2", bridge: "djot-bridge", category: "Test", testing: gate.testing)
        // Three conversions held after loading, each given up on by its caller.
        for count in 1...3 {
            gate.giveUp(after: count)
            let given = try host.fragment("_held_", notice: "") { _ in HTMLFragment(body: "converted") }
            #expect(!given.body.contains("converted"))
        }
        gate.keepWaiting()
        let fourth = try host.fragment("_fourth_", notice: "") { _ in HTMLFragment(body: "converted") }
        #expect(fourth.body.contains("fourth"))
        #expect(!fourth.body.contains("converted"))
        #expect(host.waitsForSlot == 0)
        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try host.fragment("_fifth_", notice: "") { _ in HTMLFragment(body: "converted") }
                return false
            } catch is CancellationError {
                return true
            }
        }
        #expect(try await cancelled.value)
        #expect(gate.releaseAndWait(3), "the given-up conversions' threads did not finish within 30 s")
        #expect(host.startedScripts == 0)
    }

    @Test("変換スクリプトが返さない作者・版・言語は、undefined という文字ではなく空になる")
    func missingMetadataIsEmpty() throws {
        // The Djot bridge returns only the HTML.
        let host = ScriptConverterHost("djot-0.3.2", bridge: "djot-bridge", category: "Test")
        let described = try host.fragment("_a_", notice: "") { document in
            HTMLFragment(body: "\(document.author)|\(document.revision)|\(document.language ?? "none")")
        }
        #expect(described.body == "||none")
    }

    @Test("スクリプトのスレッドを作れなければ読み取りのエラーになり、枠を返すので次の文書は読める")
    func scriptThreadRefused() throws {
        let host = ScriptConverterHost("djot-0.3.2", bridge: "djot-bridge", category: "Test", testing: .init())
        for _ in 0..<4 {
            #expect(throws: ScriptConverterHost.ScriptError.unavailable) {
                try StackSpace.refusingThreads {
                    try host.fragment("_refused_", notice: "") { _ in HTMLFragment(body: "converted") }
                }
            }
        }
        #expect(host.startedScripts == 0)
        let read = try host.fragment("_read_", notice: "") { _ in HTMLFragment(body: "converted") }
        #expect(read.body == "converted")
    }

    @Test("同時に読む文書が多くても、どの変換も自分の文書を返す")
    func concurrentConversions() async throws {
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<8 {
                group.addTask { (index, try DjotConverter.convert("_doc\(index)_").body) }
            }
            return try await group.reduce(into: [Int: String]()) { $0[$1.0] = $1.1 }
        }
        for index in 0..<8 { #expect(results[index]?.contains("<em>doc\(index)</em>") == true) }
    }
}

/// The readers run on a conversion thread of their own while the caller waits (`StackSpace.onLargeStack`). The
/// caller's file callbacks cross to that thread with them.
struct ConversionThreadTests {
    private static let tex = #"""
        \documentclass{article}\addbibresource{book.bib}\begin{document}\cite{b}\printbibliography\end{document}
        """#

    private static func convert() -> (body: String, calls: Int) {
        let calls = Locked(0)
        let body = LaTeXConverter.convert(
            tex, directory: FileManager.default.temporaryDirectory,
            readFile: { _ in
                calls.value += 1
                return Data("@book{b,title={Sendable Notes}}".utf8)
            }
        ).body
        return (body, calls.value)
    }

    @MainActor
    @Test("メインアクターから変換しても、ファイルを読むコールバックが呼ばれて結果が使われる")
    func callbackFromMainActor() {
        let (body, calls) = Self.convert()
        #expect(calls > 0)
        #expect(body.contains("Sendable Notes"))
    }

    @Test("切り離したタスクから変換しても、ファイルを読むコールバックが呼ばれて結果が使われる")
    func callbackFromDetachedTask() async {
        let (body, calls) = await Task.detached { Self.convert() }.value
        #expect(calls > 0)
        #expect(body.contains("Sendable Notes"))
    }

    @Test("変換用のスレッドからも、呼び出し元のタスクが取り消されたかが分かる")
    func cancellationCrosses() async {
        let seen = await Task.detached { () -> (Bool, Bool) in
            let before = StackSpace.onLargeStack { StackSpace.isCancelled }
            withUnsafeCurrentTask { $0?.cancel() }
            let after = StackSpace.onLargeStack { StackSpace.isCancelled }
            return (before, after)
        }.value
        #expect(seen == (false, true))
    }
}

/// The system may refuse the 16 MiB conversion thread. A reader must then not recurse on the small stack it was
/// called on without a guard.
struct RefusedThreadTests {
    private func onSmallStack<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async throws -> Value {
        guard case .finished(let value, _) = try await SmallStack.run(limit: .seconds(60), body) else {
            Issue.record("did not finish")
            throw CancellationError()
        }
        return value
    }

    @Test("変換用のスレッドを作れなければ、512 KiB のスレッドの Markdown は引用八十段でも原文で知らせる")
    func markdownWithoutThread() async throws {
        let text = String(repeating: "> ", count: 80) + "deep\n\nAfter.\n"
        let fragment = try await onSmallStack { StackSpace.refusingThreads { MarkdownConverter.convert(text) } }
        #expect(fragment.body.contains("<pre class=\"markdown-unread\">"))
        #expect(fragment.body.contains("After."))
        #expect(fragment.readingIssues == [StackSpace.limitIssue])
    }

    @Test("変換用のスレッドを作れなくても、LaTeX は小さなスタックの上で深さを確かめながら読む")
    func latexWithoutThread() async throws {
        let tex =
            "\\documentclass{article}\\begin{document}"
            + String(repeating: "\\begin{itemize}\\item ", count: 2_000) + "deep"
            + String(repeating: "\\end{itemize}", count: 2_000) + "\n\nAfter the lists.\\end{document}"
        let fragment = try await onSmallStack {
            StackSpace.refusingThreads { LaTeXConverter.convert(tex, fontIndex: InstalledFontIndex(faces: [:])) }
        }
        #expect(fragment.body.contains("After the lists."))
        #expect(!fragment.readingIssues.isEmpty)
    }

    @Test("変換用のスレッドを作れても作れなくても、スタックに余裕のあるスレッドでは同じ Markdown を組む")
    func markdownWithRoom() async throws {
        let text = "# Title\n\n> quoted *text*\n"
        let made = MarkdownConverter.convert(text)
        // Ample room: a thread with a stack as large as a conversion thread's.
        let measured = try await SmallStack.run(limit: .seconds(60), stackSize: StackSpace.conversionStackSize) {
            StackSpace.refusingThreads { MarkdownConverter.convert(text) }
        }
        guard case .finished(let refused, _) = measured else {
            Issue.record("did not finish")
            return
        }
        #expect(refused.body == made.body)
    }
}

struct StackSpaceTests {
    @Test("スタックの残りは、そのスレッドのスタックの中で測る")
    func remainingIsOnTheStack() async throws {
        let measured = try await SmallStack.run(limit: .seconds(10)) {
            (StackSpace.remaining, Int(pthread_get_stacksize_np(pthread_self())))
        }
        guard case .finished(let (remaining, size), _) = measured else {
            Issue.record("did not finish")
            return
        }
        // Under AddressSanitizer a local's address can be on its fake stack; the measure must not count that as room.
        #expect(remaining > 0)
        #expect(remaining < size)
        #expect(remaining > size / 2)
    }
}

struct RefusedThreadNestingTests {
    @Test("スレッドを作れないふりを入れ子にしても、内側を抜けたあと外側のふりが続く")
    func nestedRefusalKeepsTheOuterOne() {
        let states = StackSpace.refusingThreads { () -> (Bool, Bool) in
            let inner = StackSpace.refusingThreads { StackSpace.refusesThreads }
            return (inner, StackSpace.refusesThreads)
        }
        #expect(states == (true, true))
        #expect(!StackSpace.refusesThreads)
    }
}

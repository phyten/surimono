import Foundation
import SurimonoCore
import Testing

struct OrgPrintContractTests {
    @Test("脚注は最初の参照順で番号を付け再参照IDを区別する")
    func footnotes() throws {
        let body = OrgConverter.convert("本文[fn:b]、[fn:a]、[fn:b]。\n\n[fn:a] 二番\n続き\n[fn:b] *一番*\n\n[fn:unused] 不要").body
        #expect(
            body
                == "<p>本文<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>、<sup class=\"footnote-ref\"><a href=\"#fn-2\" id=\"fnref-2\">2</a></sup>、<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1-2\">1</a></sup>。</p>\n<section class=\"footnotes\">\n<ol>\n<li id=\"fn-1\"><p><strong>一番</strong></p>\n</li>\n<li id=\"fn-2\"><p>二番\n続き</p>\n</li>\n</ol>\n</section>\n"
        )
        let plan = try #require(PageFootnotes.plan(for: body))
        #expect(plan.eligibleNotes == [1, 2])
        #expect(plan.references.map(\.note) == [1, 2, 1])
    }

    @Test("サンプルOrgの本文に未処理の印刷用マーカーを残さない")
    func sample() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Samples/sample.org"), encoding: .utf8)
        let body = OrgConverter.convert(source).body
        for marker in ["[fn:", "#+", "SCHEDULED:", "&lt;2026-"] { #expect(!body.contains(marker)) }
        #expect(PageFootnotes.plan(for: body)?.eligibleNotes == [1, 2])
    }
}

struct OrgCodeBlockOptionTests {
    @Test("OrgのEXAMPLEと固定幅の行にも、コードの枠のオプションが届く")
    func exampleBlocksTakeCodeOptions() {
        let fragment = OrgConverter.convert("#+begin_example\nabc\n#+end_example\n\n: def\n")
        let style = CodeStyle(block: CodeBlockOptions(lineNumbers: .all))
        let marked = CodeBlockMarkup.apply(style, to: fragment.body)
        #expect(marked.components(separatedBy: "code-block").count - 1 == 2)
    }
}

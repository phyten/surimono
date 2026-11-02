import SurimonoCore
import Testing

struct MermaidTests {
    @Test("MarkdownのMermaidは原文をエスケープした専用ブロックになる")
    func markdown() {
        let body = MarkdownConverter.convert("```mermaid\nflowchart LR\nA[\"<開始> & 終了\"]\n```\n").body
        #expect(
            body
                == "<div class=\"mermaid-block\"><pre class=\"mermaid-source\">flowchart LR\nA[&quot;&lt;開始&gt; &amp; 終了&quot;]\n</pre></div>\n"
        )
    }

    @Test("OrgのMermaidもヘッダー引数を除いて同じ専用ブロックになる")
    func org() {
        let body = OrgConverter.convert("#+begin_src mermaid :exports results\nA[\"<開始> & 終了\"]\n#+end_src").body
        #expect(
            body
                == "<div class=\"mermaid-block\"><pre class=\"mermaid-source\">A[&quot;&lt;開始&gt; &amp; 終了&quot;]</pre></div>\n"
        )
    }

    @Test("Mermaidの編集はコードブロック全体の変更の印に対応する")
    func sourceMap() throws {
        let old = "# 図\n\n```mermaid\nflowchart LR\nA --> B\n```"
        let new = old.replacingOccurrences(of: "A --> B", with: "A --> C")
        let mapped = MarkdownConverter.convertWithSourceMap(new)
        let mark = try #require(MarkdownChanges.marks(from: old, to: new).first)
        #expect(mapped.blocks.first { $0.id == mark.blockID }?.lines == [3, 4, 5, 6])
        #expect(mapped.fragment.body.contains("data-surimono-block=\"\(mark.blockID)\""))
        #expect(mapped.fragment.body.contains("class=\"mermaid-block\""))
    }

    @Test("通常のコードと文中のMermaidという文字は図に変換しない")
    func otherCode() {
        #expect(
            !MarkdownConverter.convert("`mermaid`\n\n```swift\nlet mermaid = 1\n```").body.contains("mermaid-block"))
        #expect(!OrgConverter.convert("#+begin_src text\nmermaid\n#+end_src").body.contains("mermaid-block"))
    }
}

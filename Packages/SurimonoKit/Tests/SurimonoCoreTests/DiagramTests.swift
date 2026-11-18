import Foundation
import Testing

@testable import SurimonoCore

struct DiagramTests {
    @Test("図の言語別名をMarkdownとOrgで同じブロックへ変換する", arguments: ["dot", "graphviz", "plantuml", "puml"])
    func blocks(language: String) {
        let kind = ["dot", "graphviz"].contains(language) ? "graphviz" : "plantuml"
        let source = "a -> b: <日本語 & English>"
        for body in [
            MarkdownConverter.convert("```\(language)\n\(source)\n```").body,
            OrgConverter.convert("#+begin_src \(language)\n\(source)\n#+end_src").body,
        ] {
            #expect(body.contains("class=\"\(kind)-block\""))
            #expect(body.contains("&lt;日本語 &amp; English&gt;"))
            #expect(!body.contains("<日本語"))
        }
    }

    @Test("PlantUMLの異なる開始と終了の組をそれぞれ一図にする")
    func split() {
        let source = "前書き\n@startuml\nA -> B\n@enduml\n@startmindmap\n* 紙\n@endmindmap"
        let body = DiagramConverter.convert(source, format: .plantuml).body
        #expect(body.components(separatedBy: "class=\"plantuml-block\"").count == 3)
        #expect(body.contains("@startmindmap"))
        #expect(!body.contains("前書き"))
        #expect(DiagramConverter.convert("A -> B", format: .plantuml).body.contains("@startuml\nA -&gt; B\n@enduml"))
        #expect(DiagramConverter.convert("@startjson\n{}", format: .plantuml).body.contains("@startjson"))
    }

    @Test("図の拡張子を大文字でも認識する", arguments: ["dot", "gv", "puml", "plantuml", "pu", "iuml", "wsd"])
    func extensions(suffix: String) {
        let format: DocumentFormat = ["dot", "gv"].contains(suffix) ? .graphviz : .plantuml
        #expect(DocumentFormat(fileExtension: suffix.uppercased()) == format)
        #expect(format.usesPrintTheme)
        #expect(ClipboardTextKind(format)?.documentFormat == format)
    }

    @Test("コメントに続く明確な図だけをクリップボードから判定する")
    func detection() {
        for text in ["digraph G { a -> b }", " /* { */ strict digraph { a [label=\"}\"] }", "// hi\ngraph { a -- b }"] {
            #expect(ClipboardFormatDetector.detect(text).action == .open(.graphviz))
        }
        for text in ["' comment\n@startuml\nA -> B\n@enduml", "/' comment '/\n@startjson\n{}\n@endjson"] {
            #expect(ClipboardFormatDetector.detect(text).action == .open(.plantuml))
        }
        for text in [
            "digraph G {", "graph theory { prose", "graph {} trailing prose", "```dot\ndigraph {}\n```",
            "# Memo\n@startuml",
        ] {
            let action = ClipboardFormatDetector.detect(text).action
            #expect(action != .open(.graphviz))
            #expect(action != .open(.plantuml))
        }
    }
}

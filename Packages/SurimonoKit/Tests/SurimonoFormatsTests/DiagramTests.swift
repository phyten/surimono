import Foundation
import Testing

@testable import SurimonoFormats

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
}

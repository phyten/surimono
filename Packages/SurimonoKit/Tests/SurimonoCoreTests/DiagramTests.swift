import Foundation
import Testing

@testable import SurimonoCore

struct DiagramTests {
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

import AppKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
@Suite(.serialized)
struct DiagramRenderingTests {
    @Test("テーマ形式の図を準備へ渡しHTMLではエンジンを要求しない")
    func preparationRouting() async throws {
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        for (format, source) in [
            (DocumentFormat.graphviz, "digraph { a -> b }"),
            (.plantuml, "@startuml\nA -> B\n@enduml"),
            (.markdown, "```dot\ndigraph {a->b}\n```"),
            (.org, "#+begin_src puml\nA -> B\n#+end_src"),
            (.plainText, "graphviz-block"), (.markdown, "Ordinary prose."),
            (.html, "<div class=\"graphviz-block\">digraph {}</div>"),
        ] {
            let renderer = DocumentRenderer(paginate: { request in
                #expect(
                    request.rendersDiagrams == (format != .html && format != .plainText && source != "Ordinary prose."))
                if format != .html { #expect(!request.allowsJavaScript) }
                return try RenderingFixtures.pdf()
            })
            _ = try await renderer.render(DocumentSource(data: Data(source.utf8), format: format), settings: settings)
        }
    }

    @Test("図とエラーを残して組版し図のない文書ではエンジンを読まない", .timeLimit(.minutes(1)))
    func diagrams() async throws {
        _ = NSApplication.shared
        let source = """
            ```dot
            digraph { a [label="受付 / Start"]; a -> b }
            ```
            ```plantuml
            @startuml
            Alice -> Bob : 印刷依頼
            @enduml
            ```
            ```dot
            digraph { broken ->
            ```
            ```plantuml
            @startuml
            this is ???
            @enduml
            ```
            """
        let html = HTMLDocumentBuilder.build(
            fragment: MarkdownConverter.convert(source), format: .markdown,
            theme: PrintTheme(id: "test", name: "Test", css: "body { font-family: serif; }"))
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: """
                return JSON.stringify({diagrams: document.querySelectorAll('.graphviz-block > svg,.plantuml-block > svg').length,
                  vectors: document.querySelectorAll('.graphviz-block path,.plantuml-block line,.plantuml-block path').length,
                  errors: document.querySelectorAll('.diagram-error > .diagram-source').length,
                  message: document.querySelector('.diagram-message')?.textContent});
                """, rendersDiagrams: true)
        let json = try #require(result.preparationResult)
        let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(values["diagrams"] as? Int == 2)
        #expect((values["vectors"] as? Int ?? 0) > 0)
        #expect(values["errors"] as? Int == 2)
        #expect((values["message"] as? String)?.contains("Graphviz:") == true)
        #expect(result.document.pageCount > 0)
        let columns = try RenderingFixtures.inkColumns(#require(result.document.page(at: 0)))
        #expect(columns.upperBound > columns.lowerBound)
        let plain = try await WebPaginator().paginateWithResult(
            .html("<p>本文</p>", baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: "return typeof globalThis.surimonoViz + ',' + typeof globalThis.surimonoPlantUML;",
            rendersDiagrams: true)
        #expect(plain.preparationResult == "undefined,undefined")
    }

    @Test("PlantUMLのexport宣言だけをロード時に捕捉し予期しない版は拒む")
    func moduleAdapter() {
        #expect(
            DiagramScript.plantUMLLoading("export{C as render,D as renderToString};\n")?.contains("return {render:")
                == true)
        #expect(DiagramScript.plantUMLLoading("export{C as render,D as renderToString};") != nil)
        #expect(DiagramScript.plantUMLLoading("export default unknown;") == nil)
    }

    @Test("同梱したエンジンは読み込める形をしている")
    func bundledModule() throws {
        #expect(DiagramScript.vizLoading(try #require(DiagramScript.viz)) != nil)
        #expect(DiagramScript.vizLoading("no lookup here") == nil)
        #expect(DiagramScript.plantUMLLoading(try #require(DiagramScript.plantuml)) != nil)
    }
}

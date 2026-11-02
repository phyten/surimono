import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct MermaidRenderingTests {
    private var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: "body { font-family: serif; }"),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    @Test("MarkdownとOrgの図だけがMermaidの準備を要求する")
    func eligibleFormats() async throws {
        let inputs: [(DocumentFormat, String, Bool)] = [
            (.markdown, "```mermaid\nflowchart LR\nA --> B\n```", true),
            (.org, "#+begin_src mermaid\nflowchart LR\nA --> B\n#+end_src", true),
            (.markdown, "# 図のない文書", false),
            (.html, "<div class=\"mermaid-block\"><pre class=\"mermaid-source\">flowchart LR</pre></div>", false),
        ]
        for (format, text, expected) in inputs {
            let renderer = DocumentRenderer(paginate: { request in
                #expect(request.rendersMermaid == expected)
                if expected { #expect(!request.allowsJavaScript) }
                return try RenderingFixtures.pdf()
            })
            _ = try await renderer.render(DocumentSource(data: Data(text.utf8), format: format), settings: settings)
        }
    }

    @Test("図のないDOMではMermaid本体を読み込まない", .timeLimit(.minutes(1)))
    func noLibraryWithoutDiagrams() async throws {
        _ = NSApplication.shared
        let paginator = WebPaginator()
        let result = try await paginator.paginateWithResult(
            .html("<p>本文</p>", baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: "return typeof mermaid;", rendersMermaid: true)
        #expect(paginator.mermaidLoadCount == 0)
        #expect(result.preparationResult == "undefined")
    }

    @Test("数式のラベルを含む図と長すぎる図は削らずに原文を残す", .timeLimit(.minutes(1)))
    func unsupportedDiagramsKeepSource() async throws {
        _ = NSApplication.shared
        let math = "sequenceDiagram\n    A->>B: Solve: $$x^2$$"
        let long = "flowchart LR\n    A[" + String(repeating: "あ", count: MermaidScript.maxTextSize) + "]"
        let blocks = [math, long, "flowchart LR\n    A --> B"].map {
            "<div class=\"mermaid-block\"><pre class=\"mermaid-source\">\($0)</pre></div>"
        }
        let result = try await WebPaginator().paginateWithResult(
            .html(blocks.joined(), baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: """
                return JSON.stringify({
                  errors: Array.from(document.querySelectorAll('.mermaid-error > .mermaid-source'))
                    .map(source => source.textContent.slice(0, 20)),
                  diagrams: document.querySelectorAll('.mermaid-block > svg').length});
                """, rendersMermaid: true)
        let json = try #require(result.preparationResult)
        let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(values["diagrams"] as? Int == 1)
        let errors = try #require(values["errors"] as? [String])
        #expect(errors.count == 2)
        #expect(errors.first?.hasPrefix("sequenceDiagram") == true)
        #expect(errors.last?.hasPrefix("flowchart LR") == true)
    }

    @Test("図をSVGにしてから確認し壊れた図の原文と変更の印を残す", .timeLimit(.minutes(1)))
    func diagramsAndFailure() async throws {
        _ = NSApplication.shared
        let text = """
            ```mermaid
            flowchart LR
              A[開始] --> B[完了]
            ```

            ```mermaid
            flowchart LR
              A[broken
            ```

            ```mermaid
            sequenceDiagram
              participant A as 受付
              participant B as 工房
              A->>B: 印刷依頼
            ```

            <script>document.body.innerHTML = 'PAGE SCRIPT RAN';</script>
            """
        let paginator = WebPaginator()
        var markedPasses = 0
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let inspection = """
                const result = await (async () => { \(request.preparationScript ?? "") })();
                const diagrams = document.querySelectorAll('.mermaid-block > svg');
                const errors = document.querySelectorAll('.mermaid-error > .mermaid-source');
                return JSON.stringify({result, diagrams: diagrams.length, errors: errors.length,
                  labels: Array.from(diagrams).map(svg => svg.textContent).join(' '),
                  foreignObjects: document.querySelectorAll('.mermaid-block foreignObject').length,
                  marked: !!document.querySelector('.mermaid-block[data-surimono-block] > svg'),
                  raw: errors[0]?.textContent,
                  fits: Array.from(diagrams).every(svg =>
                    svg.getBoundingClientRect().width <= document.body.getBoundingClientRect().width + 2)});
                """
            let result = try await paginator.paginateWithResult(
                request.source, pageSize: request.pageSize, margins: request.margins,
                allowsJavaScript: request.allowsJavaScript, preparationScript: inspection,
                readsPageRules: request.readsPageRules, drawsBackground: request.drawsBackground,
                rendersMermaid: request.rendersMermaid)
            let json = try #require(result.preparationResult)
            let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(values["diagrams"] as? Int == 2)
            #expect(values["errors"] as? Int == 1)
            #expect(values["foreignObjects"] as? Int == 0)
            if values["marked"] as? Bool == true { markedPasses += 1 }
            #expect(values["fits"] as? Bool == true)
            #expect((values["labels"] as? String)?.contains("開始") == true)
            #expect((values["labels"] as? String)?.contains("印刷依頼") == true)
            #expect((values["raw"] as? String)?.contains("A[broken") == true)
            return WebPaginator.Result(document: result.document, preparationResult: values["result"] as? String)
        })
        var settings = settings
        settings.markdownChanges = MarkdownChanges.marks(
            from: text.replacingOccurrences(of: "開始", with: "始め"), to: text)
        let result = try await renderer.render(
            DocumentSource(data: Data(text.utf8), format: .markdown), settings: settings)
        #expect(paginator.mermaidLoadCount == 2)
        #expect(markedPasses == 1)
        #expect(!result.changeMarks.isEmpty)
        #expect(result.logicalDocument.pageCount > 0)
        #expect(result.issues.map(\.kind) == [.mermaid])
        #expect(result.issues.first?.pageNumber != nil)
        #expect(result.issues.first?.detail.contains("A[broken") == true)
        #expect(result.logicalDocument.string?.contains("PAGE SCRIPT RAN") != true)
    }
}

import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct ThemeScriptRenderingTests {
    /// Collects what the renderer asks the paginator for.
    @MainActor
    private final class Requests {
        var all: [PaginationRequest] = []
    }

    private func settings(script: String?, css: String = "body {}") -> RenderSettings {
        let theme = PrintTheme(id: "t", name: "T", css: css, isBuiltIn: true, category: "pop", script: script)
        return RenderSettings(layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    @Test("テーマの飾りのスクリプトは 4 つの形式とも準備のスクリプトとして渡り、文書の JavaScript は止めたまま")
    func scriptReachesThePaginator() async throws {
        _ = NSApplication.shared
        let requests = Requests()
        for format in [DocumentFormat.markdown, .org, .plainText, .csv] {
            let renderer = DocumentRenderer(paginate: { request in
                requests.all.append(request)
                return try RenderingFixtures.pdf()
            })
            _ = try await renderer.render(
                DocumentSource(data: Data("x".utf8), format: format), settings: settings(script: "return 1"))
        }
        #expect(requests.all.count == 4)
        #expect(requests.all.allSatisfy { !$0.allowsJavaScript && $0.preparationScript?.contains("return 1") == true })
    }

    @Test("飾りのスクリプトだけを変えても、組版し直す")
    func changingOnlyTheScriptRepaginates() async throws {
        _ = NSApplication.shared
        let requests = Requests()
        let renderer = DocumentRenderer(paginate: { request in
            requests.all.append(request)
            return try RenderingFixtures.pdf()
        })
        let source = DocumentSource(data: Data("# x".utf8), format: .markdown)
        _ = try await renderer.render(source, settings: settings(script: "return 1"))
        _ = try await renderer.render(source, settings: settings(script: "return 2"))
        #expect(requests.all.count == 2)
        #expect(requests.all.first?.preparationScript?.contains("return 1") == true)
        #expect(requests.all.last?.preparationScript?.contains("return 2") == true)
    }

    @Test("飾りは見出しと箇条書きに付き、タスクの項目には付かず、同じ文書なら毎回同じ", .timeLimit(.minutes(1)))
    func decorationsInWebKit() async throws {
        _ = NSApplication.shared
        let script = try #require(PrintThemeLibrary.load().first { $0.id == "confetti" }?.script)
        let shows = """
            h1[data-deco]::before { content: attr(data-deco) " "; }
            li[data-deco]::before { content: "<" attr(data-deco) ">"; }
            """
        let markdown = "# 見出し\n\n- 項目\n- [ ] タスク\n"
        func text(css: String) async throws -> String {
            let result = try await DocumentRenderer().render(
                DocumentSource(data: Data(markdown.utf8), format: .markdown),
                settings: settings(script: script, css: css))
            return result.logicalDocument.string ?? ""
        }
        let decorated = try await text(css: ":root { --deco-emoji: Q Z; }\n" + shows)
        #expect(decorated.hasPrefix("Q ") || decorated.hasPrefix("Z "))
        #expect(decorated.contains("<Q>項目") || decorated.contains("<Z>項目"))
        let task = decorated.components(separatedBy: .newlines).first { $0.contains("タスク") }
        #expect(task?.contains("<") == false)
        #expect(try await text(css: ":root { --deco-emoji: Q Z; }\n" + shows) == decorated)
        // A theme without --deco-emoji gets no decorations even with the script.
        #expect(try await text(css: shows).contains("<") == false)
    }
}

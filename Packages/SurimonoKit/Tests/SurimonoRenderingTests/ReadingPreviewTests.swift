import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct ReadingPreviewTests {
    @Test(
        "先頭と全文を同じ用紙で順に組み、完成済みの文書は先頭から組み直さない",
        .timeLimit(.minutes(1)), arguments: [5_000, 5_001])
    func readingPasses(records: Int) async throws {
        let text =
            "head,value\r\n" + String(repeating: "\"a,b\",123\r\n", count: records - 2) + "LAST_RECORD,456,later column"
        let source = DocumentSource(data: Data(text.utf8), format: .csv)
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        var events: [String] = []
        var sizes: [CGSize] = []
        let renderer = DocumentRenderer(
            isSandboxed: { false },
            paginate: { request in
                guard case .html(let html, _) = request.source else {
                    Issue.record("CSVのHTMLが渡されなかった")
                    return try RenderingFixtures.pdf()
                }
                #expect(html.contains("<thead><tr><th>head</th><th>value</th></tr></thead>"))
                #expect(html.contains("<td>a,b</td>"))
                #expect(html.contains("<colgroup><col span=\"3\"></colgroup>") == (records > 5_000))
                #expect(html.contains("table-layout:fixed") == (records > 5_000))
                sizes.append(request.pageSize)
                let complete = html.contains("<td>LAST_RECORD</td>")
                events.append(complete ? "complete" : "prefix")
                return try RenderingFixtures.pdf(count: complete ? 3 : 1, size: request.pageSize)
            })
        let ready = try await renderer.prepare(source, settings: settings) { preview in
            #expect(preview.document.pageCount == 1)
            events.append("shown")
        }
        let cached = try await renderer.prepare(source, settings: settings) { _ in
            Issue.record("完成済みの文書を先頭の紙で置き換えた")
        }
        #expect(events == (records == 5_000 ? ["complete"] : ["prefix", "shown", "complete"]))
        #expect(ready.viewDocument.pageCount == 3 && ready.viewDocument === cached.viewDocument)
        renderer.clearCache()
        events.removeAll()
        _ = try await renderer.prepare(source, settings: settings)
        #expect(events == ["complete"])
        #expect(sizes.allSatisfy { $0 == sizes.first })
    }

    @Test("Shift_JISのログの先頭と末尾を同じ復号結果から組む", .timeLimit(.minutes(1)))
    func logPasses() async throws {
        let line = "日本語のログ" + String(repeating: "x", count: 90) + "\r\n"
        let bytes = try #require((String(repeating: line, count: 10_001) + "末尾").data(using: .shiftJIS))
        let source = DocumentSource(data: bytes, format: .plainText).named("sample.log")
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        var events: [String] = []
        let renderer = DocumentRenderer(
            isSandboxed: { false },
            paginate: { request in
                guard case .html(let html, _) = request.source else {
                    Issue.record("ログのHTMLが渡されなかった")
                    return try RenderingFixtures.pdf()
                }
                #expect(html.contains("<pre class=\"surimono-plain\">日本語のログ"))
                events.append(html.contains("末尾</pre>") ? "complete" : "prefix")
                return try RenderingFixtures.pdf(size: request.pageSize)
            })
        _ = try await renderer.prepare(source, settings: settings) { _ in events.append("shown") }
        #expect(events == ["prefix", "shown", "complete"])
    }
}

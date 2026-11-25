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
        let row = "1,\"a,b\",104,2026-11-25,a long note that needs most of the remaining width\r\n"
        let text =
            "id,name,amount,date,note\r\n" + String(repeating: row, count: records - 2)
            + "LAST_RECORD,tail,456,2026-11-26,end,later column"
        let source = DocumentSource(data: Data(text.utf8), format: .csv)
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"), textScale: 1.25)
        var events: [String] = []
        var sizes: [CGSize] = []
        var groups: [Substring] = []
        let renderer = DocumentRenderer(
            isSandboxed: { false },
            paginate: { request in
                guard case .html(let html, _) = request.source else {
                    Issue.record("CSVのHTMLが渡されなかった")
                    return try RenderingFixtures.pdf()
                }
                #expect(
                    html.contains(
                        "<thead><tr><th>id</th><th>name</th><th>amount</th><th>date</th><th>note</th></tr></thead>"))
                #expect(html.contains("<td>a,b</td>"))
                if let start = html.range(of: "<colgroup>"), let end = html.range(of: "</colgroup>") {
                    groups.append(html[start.upperBound..<end.lowerBound])
                }
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
        if records > 5_000 {
            #expect(groups.count == 2 && groups.first == groups.last)
            let first = try #require(groups.first)
            let widths = first.matches(of: /<col(?: span="([0-9]+)")? style="width:([0-9.]+)%">/).flatMap { match in
                Array(repeating: Double(match.2)!, count: match.1.flatMap { Int($0) } ?? 1)
            }
            try #require(widths.count == 6)
            let textWidth = settings.textWidthPoints(in: settings.layout) / settings.textScale
            #expect(widths[2] / 100 * textWidth >= 57.5 - 0.0001 && widths[5] / 100 * textWidth >= 57.5 - 0.0001)
        } else {
            #expect(groups.isEmpty)
        }
        #expect(ready.viewDocument.pageCount == 3 && ready.viewDocument === cached.viewDocument)
        renderer.clearCache()
        events.removeAll()
        _ = try await renderer.prepare(source, settings: settings)
        #expect(events == ["complete"])
        if records > 5_000 { #expect(groups.count == 3 && groups.last == groups.first) }
        #expect(sizes.allSatisfy { $0 == sizes.first })
    }

    @Test("後半に長い行がある大きなソースコードは全文だけを組む", .timeLimit(.minutes(1)))
    func sourceUsesWholeBlock() async throws {
        let code =
            String(repeating: "// " + String(repeating: "a", count: 100) + "\n", count: 10_000)
            + "// LONG_TAIL" + String(repeating: "b", count: 1_000)
        let source = DocumentSource(data: Data(code.utf8), format: .plainText).named("example.swift")
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        var passes = 0
        let renderer = DocumentRenderer(
            isSandboxed: { false },
            paginate: { request in
                passes += 1
                if case .html(let html, _) = request.source {
                    #expect(html.contains("<pre class=\"surimono-source"))
                    #expect(html.contains("LONG_TAIL"))
                } else {
                    Issue.record("ソースコードのHTMLが渡されなかった")
                }
                return try RenderingFixtures.pdf(size: request.pageSize)
            })
        _ = try await renderer.prepare(source, settings: settings) { _ in
            Issue.record("言語を検出したソースコードの先頭だけを表示した")
        }
        #expect(passes == 1)
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

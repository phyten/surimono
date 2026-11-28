import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct SourceWrapTests {
    @Test("JSON Lines の折り返しで、短い識別子の文字列をハイフンで切らない", .timeLimit(.minutes(1)))
    func shortIDStaysOnOneLine() async throws {
        let lines = (160..<166).map {
            "{\"event_id\": \"EV-00\($0)\", \"time\": \"2026-11-28T10:42:00+09:00\", \"record_id\": \"KH-00\($0)\", "
                + "\"event\": \"reviewed\", \"actor\": \"operator-3\"}"
        }
        let source = DocumentSource(data: Data(lines.joined(separator: "\n").utf8), format: .plainText)
            .named("events.jsonl")
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let result = try await DocumentRenderer().prepare(
            source, settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let text = try #require(result.logicalDocument.page(at: 0)?.string)
        for number in 160..<166 { #expect(text.contains("\"KH-00\(number)\""), "\(text)") }
    }
}

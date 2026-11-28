import AppKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
@Suite(.serialized)
struct PlantUMLTextMetricsTests {
    @Test("日本語のページでもPlantUMLの文字は枠の右端を越えない", .timeLimit(.minutes(1)))
    func labelsStayInsideBoxes() async throws {
        _ = NSApplication.shared
        let source = """
            図の文字の幅を確かめるための日本語の本文です。

            ```plantuml
            @startuml
            class Record {
              recordedBy : String
              記録者 : 文字列
            }
            class Entry {
              記録者 recordedBy : 文字列
            }
            @enduml
            ```
            """
        let html = HTMLDocumentBuilder.build(
            fragment: MarkdownConverter.convert(source), format: .markdown,
            theme: PrintTheme(id: "test", name: "Test", css: "body { font-family: serif; }"))
        // For each label, the gap from its drawn right edge to the right edge of the smallest box around its start.
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: """
                const rects = Array.from(document.querySelectorAll('.plantuml-block rect'), rect => rect.getBBox());
                const gaps = {};
                for (const text of document.querySelectorAll('.plantuml-block text')) {
                  const box = text.getBBox();
                  const around = rects.filter(rect => rect.x <= box.x && box.x <= rect.x + rect.width &&
                    rect.y <= box.y + box.height / 2 && box.y + box.height / 2 <= rect.y + rect.height)
                    .sort((a, b) => a.width * a.height - b.width * b.height)[0];
                  if (around) gaps[text.textContent] = around.x + around.width - (box.x + box.width);
                }
                return JSON.stringify({lang: document.documentElement.lang, gaps});
                """, rendersDiagrams: true)
        let json = try #require(result.preparationResult)
        let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(values["lang"] as? String == "ja")
        let gaps = try #require(values["gaps"] as? [String: Double])
        for label in ["recordedBy : String", "記録者 recordedBy : 文字列"] {
            let gap = try #require(gaps[label], "\(label) has no box: \(json)")
            #expect(gap >= 0, "\(label) passes the right edge by \(-gap)")
        }
    }
}

import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct PageLayoutLimitTests {
    private var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    @Test("大きすぎるテキストとCSVはページ分割を始めず元のバイト数を返す", arguments: [DocumentFormat.plainText, .csv])
    func rejectsBeforePagination(format: DocumentFormat) async {
        let data =
            format == .plainText
            ? Data(repeating: 65, count: 30_000_001)
            : Data(String(repeating: "x,y\r\n", count: 60_001).utf8)
        let renderer = DocumentRenderer(paginate: { _ in
            Issue.record("上限を超えた文書でページ分割が呼ばれた")
            return try RenderingFixtures.pdf()
        })
        await #expect(throws: DocumentRenderer.RenderingError.tooLarge(bytes: data.count)) {
            try await renderer.prepare(DocumentSource(data: data, format: format), settings: settings)
        }
    }

    @Test("文書の大きさで待ち時間を延ばし5分で止める")
    func timeout() {
        #expect(PageLayoutLimits.timeout(bytes: 0, baseSeconds: 15) == .seconds(15))
        #expect(PageLayoutLimits.timeout(bytes: 10_000_000, baseSeconds: 60) == .seconds(100))
        #expect(PageLayoutLimits.timeout(bytes: 90_000_000, baseSeconds: 60) == .seconds(300))
    }

    @Test("生成したHTMLは60 MBちょうどまでページ分割に渡せる")
    func generatedHTMLSize() throws {
        try PageLayoutLimits.checkHTML(bytes: 60_000_000, sourceBytes: 42)
        #expect(throws: DocumentRenderer.RenderingError.tooLarge(bytes: 42)) {
            try PageLayoutLimits.checkHTML(bytes: 60_000_001, sourceBytes: 42)
        }
    }

    @Test("本文のbaseは無視しコメントやスクリプトのbodyでヘッダーを打ち切らない")
    func baseInHead() {
        let url = URL(fileURLWithPath: "/docs/", isDirectory: true)
        let body = "<BODY><base href='wrong/'>"
        #expect(WebPaginator.injectingBase(url, into: body).hasPrefix("<base href=\"file:///docs/\">"))
        let head = "<!--<body>--><script>const b='<body>';</SCRIPT ><base href='right/'>"
        #expect(WebPaginator.injectingBase(url, into: head + body).contains("<base href=\"file:///docs/right/\">"))
    }

    @Test("図の待ち時間は1個300ミリ秒ずつ延ばし60秒を上限にする")
    func diagramBudget() {
        #expect(MermaidScript.budgetMilliseconds(count: 0) == 10_000)
        #expect(MermaidScript.budgetMilliseconds(count: 100) == 40_000)
        #expect(MermaidScript.budgetMilliseconds(count: 200) == 60_000)
    }
}

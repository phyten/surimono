import Foundation
import SurimonoCore
import Testing

struct TextScaleTests {
    @Test("文字の大きさは80%から200%までの8段階")
    func steps() {
        #expect(TextScale.steps == [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2])
    }

    @Test(
        "次と前の段階を選び、端では止まる",
        arguments: [
            (0.8, 0.9, 0.8), (0.9, 1, 0.8), (1, 1.1, 0.9), (1.1, 1.25, 1),
            (1.25, 1.5, 1.1), (1.5, 1.75, 1.25), (1.75, 2, 1.5), (2, 2, 1.75),
        ])
    func adjacent(value: Double, larger: Double, smaller: Double) {
        #expect(TextScale.larger(than: value) == larger)
        #expect(TextScale.smaller(than: value) == smaller)
    }

    @Test("100%ではテーマに倍率のCSSを足さない")
    func defaultHTML() {
        let theme = PrintTheme(id: "user:test", name: "Test", css: "body { font-size: 12pt; }")
        let fragment = HTMLFragment(body: "<p>本文</p>")
        let original = HTMLDocumentBuilder.build(fragment: fragment, format: .markdown, theme: theme)
        let explicit = HTMLDocumentBuilder.build(fragment: fragment, format: .markdown, theme: theme, textScale: 1)
        #expect(original == explicit)
        #expect(!original.contains("zoom:"))
    }

    @Test("文字倍率をユーザーCSSの後に重ねる")
    func scaledHTML() {
        let theme = PrintTheme(id: "user:test", name: "Test", css: "body { font-size: 12pt; }")
        let html = HTMLDocumentBuilder.build(
            fragment: HTMLFragment(body: "<p>本文</p>"), format: .markdown, theme: theme, textScale: 1.5)
        #expect(html.contains("body { font-size: 12pt; }\nhtml { zoom: 1.5; }"))
        #expect(!html.contains("@page"))
    }

    @Test("文字倍率を保存して読み戻し、古い記録や型の違う項目はnilとして読む")
    func persistence() throws {
        let settings = DocumentSettings(textScale: 1.25)
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.textScale == 1.25)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: Data("{}".utf8)).textScale == nil)
        let old = try JSONDecoder().decode(
            DocumentSettings.self, from: Data(#"{"textScale":"large","themeID":"standard"}"#.utf8))
        #expect(old.textScale == nil)
        #expect(old.themeID == "standard")
    }
}

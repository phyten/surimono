import CoreGraphics
import Foundation
import Testing

@testable import SurimonoCore

struct PaperBackgroundTests {
    private let a4 = CGSize(width: 595.28, height: 841.89)
    private let theme = PrintTheme(id: "t", name: "T", css: "html { background: #fcfaf5; }")

    /// The number in front of `px` that follows `property` in the paper page's root rule.
    private func pixels(_ property: String, in css: String) throws -> Double {
        let rule = try #require(css.components(separatedBy: "\nhtml {").last)
        let value = try #require(rule.components(separatedBy: "\(property): ").dropFirst().first)
        return try #require(Double(value.prefix { $0 != "p" }))
    }

    @Test("紙を外して組む文書だけが、紙を外す指定を持つ")
    func removalStyleOnlyWhenAsked() {
        let fragment = HTMLFragment(body: "<p>x</p>")
        let removing = HTMLDocumentBuilder.build(
            fragment: fragment, format: .markdown, theme: theme, removesPaper: true)
        let keeping = HTMLDocumentBuilder.build(fragment: fragment, format: .markdown, theme: theme)
        #expect(removing.contains("<style id=\"surimono-paper\">html { background: none !important; }</style>"))
        #expect(!keeping.contains("surimono-paper"))
    }

    @Test("紙の版は根要素の中身を本文の範囲に置き、画像もそこから描き始める")
    func paperPagePlacesTheRootOverTheTextArea() throws {
        // 15 mm is 42.52 pt; printing draws 1.25 CSS pixels to a point.
        let css = PaperBackground.styleSheet(theme: theme, pageSize: a4, marginInMillimeters: 15, pixelsPerPoint: 1.25)
        #expect(abs(try pixels("padding", in: css) - 53.15) < 0.01)
        #expect(abs(try pixels("height", in: css) - (841.89 - 85.04) * 1.25) < 0.02)
        #expect(css.contains("margin: 0 !important"))
        #expect(css.contains("background-origin: content-box !important"))
        #expect(css.hasPrefix("html { background: #fcfaf5; }"))
    }

    @Test("文字の大きさを変えても、紙の版の根要素は同じ場所に置く")
    func paperPageIgnoresTheTextScale() throws {
        // The root's zoom scales its own padding and height, so they are given divided by it.
        let css = PaperBackground.styleSheet(
            theme: theme, textScale: 2, pageSize: a4, marginInMillimeters: 15, pixelsPerPoint: 1)
        #expect(abs(try pixels("padding", in: css) - 21.26) < 0.01)
        #expect(css.contains("html { zoom: 2.0; }"))
    }

    @Test("紙の版の文書は本文を持たない")
    func paperDocumentHasNoText() {
        let html = PaperBackground.document(
            theme: theme, format: .org, pageSize: a4, marginInMillimeters: 15, pixelsPerPoint: 1.25)
        #expect(html.contains("<body class=\"surimono format-org\"></body>"))
    }

    @Test("紙のある組み込みテーマは、body の背景を透明か紙と同じ指定にし、模様を描かない")
    func builtInPaperStaysOnTheRoot() throws {
        for theme in try PrintThemeLibrary.load() {
            let css = theme.css.replacingOccurrences(
                of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            var root: String?
            var body: String?
            for rule in css.components(separatedBy: "}") {
                let parts = rule.components(separatedBy: "{")
                guard parts.count == 2, parts[1].contains("background") else { continue }
                let selectors = parts[0].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if selectors.contains("html") { root = rule }
                if selectors.contains("body") {
                    body = rule
                    #expect(!parts[1].contains("gradient(") && !parts[1].contains("url("), "\(theme.id): \(rule)")
                }
            }
            // common.css gives both a plain white; a theme with paper replaces the root's.
            guard let root, root != body else { continue }
            let clear = body?.range(of: #"background:\s*transparent"#, options: .regularExpression) != nil
            #expect(clear, "\(theme.id) leaves its body over the paper")
        }
    }
}

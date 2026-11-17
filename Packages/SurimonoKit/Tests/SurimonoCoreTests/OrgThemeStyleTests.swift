import Foundation
import Testing

@testable import SurimonoCore

/// The rules common.css gives Org documents and plain text, read from the style sheet, so that a theme's type and
/// dress keep reaching them and the themes' accents for them stay readable.
struct OrgThemeStyleTests {
    private struct Rule {
        let selectors: [String]
        let body: String

        func value(of property: String) -> String? {
            body.matches(of: /(?:^|[\s;{])([\w-]+)\s*:\s*([^;]+)/).last { String($0.1) == property }
                .map { String($0.2).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private func rules(_ css: String) -> [Rule] {
        css.replacing(/\/\*[\s\S]*?\*\//, with: "").matches(of: /([^{}]+)\{([^{}]*)\}/).map { match in
            Rule(selectors: selectors(String(match.1)), body: String(match.2))
        }
    }

    /// A selector list split at its top-level commas, so `:is(a, b) > p` stays one selector.
    private func selectors(_ list: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in list {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func common() throws -> String {
        try String(contentsOf: CoreResources.url("common", extension: "css"), encoding: .utf8)
    }

    /// Each built-in theme's own style sheet, without the common one it is laid over.
    private func themeSheets() throws -> [(id: String, css: String)] {
        try PrintThemeLibrary.load().filter(\.isBuiltIn).map { theme in
            (theme.id, try String(contentsOf: CoreResources.url(theme.id, extension: "css"), encoding: .utf8))
        }
    }

    @Test("Org の印と予定の規則は書体を決めず、テーマの書体を受け継ぐ")
    func orgMarksInheritTheType() throws {
        let orgRules = try rules(common()).filter { $0.selectors.contains { $0.contains(".org-") } }
        #expect(!orgRules.isEmpty)
        for rule in orgRules {
            for match in rule.body.matches(of: /font(?:-family)?\s*:\s*([^;]+)/) {
                #expect(String(match.1).trimmingCharacters(in: .whitespaces) == "inherit", "\(rule.selectors)")
            }
        }
    }

    @Test("見出しの印は見出しの字間・大文字・縁取り・影を持ち込まない")
    func headingMarksLeaveTheHeadingsDress() throws {
        let marks = [".org-todo", ".org-done", ".org-priority", ".org-cookie", ".org-tags"]
        let rule = try #require(try rules(common()).first { Set(marks).isSubset(of: $0.selectors) })
        #expect(rule.value(of: "text-transform") == "none")
        #expect(rule.value(of: "-webkit-text-stroke") == "0")
        #expect(rule.value(of: "text-shadow") == "none")
        #expect(rule.value(of: "letter-spacing") != nil)
    }

    @Test("タグは見出しの行末（左から右の文書では右端）へ寄り、大きさは見出しに比例しない")
    func tagsGoToTheLineEnd() throws {
        let all = try rules(common())
        let tags = try #require(all.first { $0.selectors == [".org-tags"] })
        #expect(tags.value(of: "float") == "inline-end")
        // A margin at the line's end keeps the last tag's frame inside the text width.
        let margin = try #require(tags.value(of: "margin-inline")).split(separator: " ")
        #expect(margin.count == 2 && margin[1] != "0")
        let tag = try #require(all.first { $0.selectors == [".org-tag"] })
        #expect(tag.value(of: "font-size") == "var(--org-tag-size)")
        let root = try #require(all.first { $0.selectors == [":root"] && $0.body.contains("--org-tag-size") })
        #expect(root.value(of: "--org-tag-size")?.contains("rem") == true)
    }

    @Test("タグを持つ見出しは浮いたタグを自分の箱に収め、見出しの表示を決めるテーマには譲る")
    func headingsHoldTheirTags() throws {
        let rule = try #require(
            try rules(common()).first { $0.selectors == [":where(:is(h1, h2, h3, h4, h5, h6):has(> .org-tags))"] })
        #expect(rule.value(of: "display") == "flow-root")
    }

    @Test("予定の行と角括弧の日付を薄めるのは本文の地の文だけで、引用や囲みの中では薄めない")
    func onlyBodyTextIsMadeQuieter() throws {
        let quieter = try rules(common()).filter { $0.body.contains("--org-quiet)") }
        #expect(!quieter.isEmpty)
        for rule in quieter {
            #expect(rule.selectors.allSatisfy { $0.hasPrefix("body > ") }, "\(rule.selectors)")
        }
    }

    @Test("完了の打ち消し線は緩いリストの項目では最初の段落だけに引く")
    func doneLinesStayOnTheirOwnParagraph() throws {
        for (id, css) in try themeSheets() {
            for rule in rules(css) where rule.body.contains("line-through") {
                for selector in rule.selectors where selector.contains(":checked") {
                    // A line on the item would run through the open items under it too.
                    #expect(!selector.contains(":has(") || !selector.contains("p:first-child >"), "\(id) \(selector)")
                }
            }
        }
    }

    @Test("表題ブロックの段落はテーマの両端揃えとドロップキャップを受けない")
    func titleBlocksKeepTheirLines() throws {
        let all = try rules(common())
        let paragraphs = try #require(
            all.first { $0.selectors == [":is(.org-title-block, .latex-title-block) > p"] })
        #expect(paragraphs.value(of: "text-align") == "inherit")
        let letters = try #require(
            all.first { $0.selectors.contains(":is(.org-title-block, .latex-title-block) > p::first-letter") })
        #expect(letters.selectors.contains("p.org-planning::first-letter"))
        #expect(letters.value(of: "float") == "none")
        #expect(letters.value(of: "font") == "inherit")
    }

    @Test("テキストはテーマのコードの地・枠・余白・小さい字を受けない")
    func plainTextIsNotACodeBox() throws {
        // As specific as one class: above a theme's bare `pre`, so it wins though common.css comes first.
        let rule = try #require(try rules(common()).first { $0.selectors == [":where(pre).surimono-plain"] })
        #expect(rule.value(of: "background") == "none")
        #expect(rule.value(of: "border") == "0")
        #expect(rule.value(of: "padding") == "0")
        #expect(rule.value(of: "font") == "inherit")
    }

    @Test("テーマはテキストの見え方を上書きせず、pre の規則はクラス一つより詳細にしない")
    func themesLeavePlainTextAlone() throws {
        for (id, css) in try themeSheets() {
            for rule in rules(css) {
                for selector in rule.selectors {
                    #expect(!selector.contains("surimono-plain"), "\(id) \(selector)")
                    // A selector whose subject is pre and that names a class, id, attribute or pseudo-class would
                    // outrank the plain-text rule.
                    let subject = selector.split(whereSeparator: { " >+~".contains($0) }).last.map(String.init) ?? ""
                    if subject.hasPrefix("pre") {
                        #expect(selector.firstMatch(of: /[.#\[:]/) == nil, "\(id) \(selector)")
                    }
                }
            }
        }
    }

    @Test("利用者の CSS はクラスだけの指定でテキストの書体を変えられる")
    func usersCanRestylePlainText() throws {
        // The plain-text rule must not outrank `.surimono-plain` alone, which a user's style sheet uses after it.
        let selectors = try rules(common()).filter { $0.body.contains("font: inherit") }.flatMap(\.selectors)
            .filter { $0.contains("surimono-plain") }
        #expect(!selectors.isEmpty)
        for selector in selectors {
            #expect(selector.replacing(/:where\([^)]*\)/, with: "") == ".surimono-plain", "\(selector)")
        }
    }

    @Test("テーマが決めた TODO と DONE の色は紙の上で 4.5:1 以上ある")
    func keywordInksAreReadable() throws {
        var checked = 0
        for theme in try PrintThemeLibrary.load().filter(\.isBuiltIn) {
            let all = rules(theme.css)
            // The paper a theme paints on the root, when it names one as a six-digit colour.
            let paper = all.filter { $0.selectors.contains("html") }.compactMap { $0.value(of: "background") }
                .compactMap { $0.firstMatch(of: /#[0-9a-fA-F]{6}\b/).flatMap { Ink(hex: String($0.0)) } }.last
            for name in ["--org-todo-ink", "--org-done-ink"] {
                guard let value = all.compactMap({ $0.value(of: name) }).last, let ink = Ink(hex: value) else {
                    continue
                }
                checked += 1
                #expect(ink.contrast(with: paper ?? Ink.white) >= 4.5, "\(theme.id) \(name)")
            }
        }
        #expect(checked > 0)
    }

    private struct Ink {
        static let white = Ink(r: 255, g: 255, b: 255)
        let r: Double
        let g: Double
        let b: Double

        init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        init?(hex: String) {
            guard hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
            self.init(r: Double(value >> 16 & 255), g: Double(value >> 8 & 255), b: Double(value & 255))
        }

        private var luminance: Double {
            func linear(_ channel: Double) -> Double {
                let value = channel / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        func contrast(with other: Ink) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
    }
}

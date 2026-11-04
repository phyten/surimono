import Foundation
import Testing

@testable import SurimonoCore

/// The declarations a callout ends up with in a theme, read from its CSS, so contrast can be computed for every theme
/// without a browser.
private struct CalloutColors {
    private var variables: [String: String] = [:]
    private let rules: [(selectors: [String], body: String)]

    init(css: String) {
        let plain = css.replacing(/\/\*[\s\S]*?\*\//, with: "")
        rules = plain.matches(of: /([^{}]+)\{([^{}]*)\}/).map { match in
            (match.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, String(match.2))
        }
        for rule in rules where rule.selectors.contains(":root") { apply(rule.body) }
    }

    private mutating func apply(_ body: String) {
        for match in body.matches(of: /(--[\w-]+)\s*:\s*([^;]+)/) {
            variables[String(match.1)] = match.2.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The variables as `.callout` and the given class leave them, later rules winning as in the cascade.
    func scoped(toClass name: String) -> CalloutColors {
        var copy = self
        for rule in rules where rule.selectors.contains(".callout") || rule.selectors.contains(".callout-\(name)") {
            copy.apply(rule.body)
        }
        return copy
    }

    func color(_ name: String) -> RGB? { resolve(variables[name] ?? "") }

    var bodyText: RGB? {
        var found: RGB?
        for rule in rules where rule.selectors.contains("body") {
            for match in rule.body.matches(of: /(?:^|[\s;])color\s*:\s*([^;]+)/) {
                found = resolve(String(match.1)) ?? found
            }
        }
        return found
    }

    /// The colour of a page painted on the root, when the theme paints one.
    var pageBackground: RGB? {
        var found: RGB?
        for rule in rules where rule.selectors.contains("html") {
            for match in rule.body.matches(of: /background(?:-color)?\s*:\s*(#[0-9a-fA-F]{3,6}|white)\b/) {
                found = resolve(String(match.1))
            }
        }
        return found
    }

    private func resolve(_ value: String) -> RGB? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = value.wholeMatch(of: /var\((--[\w-]+)\)/) { return resolve(variables[String(match.1)] ?? "") }
        if value == "transparent" { return color("--callout-paper") }
        if value == "white" { return RGB(r: 255, g: 255, b: 255) }
        if let match = value.wholeMatch(of: /color-mix\(in srgb, (.+) (var\([\w-]+\)|[\d.]+%), (.+)\)/) {
            guard let first = resolve(String(match.1)), let second = resolve(String(match.3)) else { return nil }
            let amountText = String(match.2)
            let amount: String
            if let name = amountText.wholeMatch(of: /var\((--[\w-]+)\)/) {
                amount = variables[String(name.1)] ?? ""
            } else {
                amount = amountText
            }
            guard let percent = Double(amount.dropLast()) else { return nil }
            return first.mixed(with: second, amount: percent / 100)
        }
        return RGB(hex: value)
    }
}

private struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(r: Double(value >> 16 & 255), g: Double(value >> 8 & 255), b: Double(value & 255))
    }

    func mixed(with other: RGB, amount: Double) -> RGB {
        RGB(
            r: r * amount + other.r * (1 - amount), g: g * amount + other.g * (1 - amount),
            b: b * amount + other.b * (1 - amount))
    }

    private var luminance: Double {
        func linear(_ channel: Double) -> Double {
            let value = channel / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func contrast(with other: RGB) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

struct CalloutThemeTests {
    private static let groups = [
        ("note", "info"), ("tip", "success"), ("warning", "warning"), ("danger", "danger"), ("neutral", "plain"),
    ]

    private func themes() throws -> [PrintTheme] {
        try PrintThemeLibrary.load().filter(\.isBuiltIn)
    }

    @Test("全テーマの全種類で札の文字は札の地の上で 4.5:1 以上ある")
    func tagContrast() throws {
        for theme in try themes() {
            let colors = CalloutColors(css: theme.css)
            for (name, group) in Self.groups {
                let scoped = colors.scoped(toClass: name)
                let ink = try #require(scoped.color("--callout-tag-ink"), "\(theme.id) \(name)")
                let fill = try #require(scoped.color("--callout-tag-fill"), "\(theme.id) \(name)")
                #expect(ink.contrast(with: fill) >= 4.5, "\(theme.id) \(group)")
            }
        }
    }

    @Test("全テーマの全種類で囲みの本文は囲みの地の上で 4.5:1 以上ある")
    func bodyContrast() throws {
        for theme in try themes() {
            let colors = CalloutColors(css: theme.css)
            let text = try #require(colors.bodyText, "\(theme.id)")
            for (name, group) in Self.groups {
                let tint = try #require(colors.scoped(toClass: name).color("--callout-tint"), "\(theme.id) \(name)")
                #expect(text.contrast(with: tint) >= 4.5, "\(theme.id) \(group)")
            }
        }
    }

    @Test("全テーマの引用の表題は紙の上で 4.5:1 以上ある")
    func quoteTitleContrast() throws {
        for theme in try themes() {
            let colors = CalloutColors(css: theme.css)
            let title = try #require(colors.color("--callout-plain"), "\(theme.id)")
            let paper = try #require(colors.color("--callout-paper"), "\(theme.id)")
            #expect(title.contrast(with: paper) >= 4.5, "\(theme.id)")
        }
    }

    @Test("全テーマの本文は紙の上で 4.5:1 以上ある")
    func textContrast() throws {
        for theme in try themes() {
            let colors = CalloutColors(css: theme.css)
            let text = try #require(colors.bodyText, "\(theme.id)")
            let paper = try #require(colors.color("--callout-paper"), "\(theme.id)")
            #expect(text.contrast(with: paper) >= 4.5, "\(theme.id)")
        }
    }

    @Test("紙に色のあるテーマは囲みの地も同じ紙から作る")
    func paperMatchesTheTheme() throws {
        for theme in try themes() {
            let colors = CalloutColors(css: theme.css)
            #expect(colors.pageBackground == colors.color("--callout-paper"), "\(theme.id)")
        }
    }

    @Test("テーマが群の色を渡すだけで地と札が揃う")
    func tintsFollowTheGroupColor() throws {
        let common = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" }).css
        let colors = CalloutColors(css: common + "\n:root { --callout-info: #000000; --callout-paper: #ffffff; }")
        let scoped = colors.scoped(toClass: "note")
        #expect(scoped.color("--callout-tag-fill") == RGB(hex: "#000000"))
        let tint = try #require(scoped.color("--callout-tint"))
        #expect(abs(tint.r - 234.6) < 0.01)
    }

    @Test("四つの群は線の種類で分かれる")
    func groupsDifferByLine() throws {
        let css = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" }).css
        let lines = ["note": "solid", "tip": "dotted", "warning": "dashed", "danger": "double"]
        for (name, line) in lines where name != "note" {
            let rule = try #require(css.firstRange(of: ".callout-\(name) {")).upperBound
            let body = css[rule...].prefix { $0 != "}" }
            #expect(body.contains("--callout-line: \(line);"))
        }
        #expect(css.contains("--callout-line: solid;"))
    }

    @Test("全テーマで以前のクラスだけの囲みは注意の群の色になる")
    func compatibilityClassReadsAsWarning() throws {
        for theme in try themes() {
            let colors = CalloutColors(css: theme.css)
            let scoped = colors.scoped(toClass: "important")
            #expect(scoped.color("--callout-color") == colors.color("--callout-warning"), "\(theme.id)")
            #expect(scoped.color("--callout-tint") == colors.color("--callout-warning-tint"), "\(theme.id)")
        }
    }

    @Test("ソラライズドのコードの色は自分の地の上で 4.5:1 以上ある")
    func solarizedCode() throws {
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "solarized" })
        let colors = CalloutColors(css: theme.css)
        let ground = try #require(RGB(hex: "#eee8d5"))
        for token in [
            "keyword", "type", "builtin", "function", "literal", "number", "string", "comment", "meta", "tag", "attr",
            "variable", "addition", "deletion", "section",
        ] {
            let color = try #require(colors.color("--hl-\(token)"), "\(token)")
            #expect(color.contrast(with: ground) >= 4.5, "\(token)")
        }
    }
}

struct ThemeCatalogContentTests {
    @Test("組み込みのテーマは 12 のカテゴリーに 9 種ずつ、108 種ある")
    func counts() throws {
        let themes = try PrintThemeLibrary.load().filter(\.isBuiltIn)
        let categories = try PrintThemeLibrary.categories()
        #expect(themes.count == 108)
        #expect(categories.count == 12)
        for category in categories {
            #expect(themes.filter { $0.category == category.id }.count == 9, "\(category.id)")
        }
    }

    @Test("テーマの CSS は決まりの外のものを使わない")
    func forbiddenCSS() throws {
        for theme in try PrintThemeLibrary.load().filter(\.isBuiltIn) {
            let css = theme.css.replacing(/\/\*[\s\S]*?\*\//, with: "")
            for word in [
                "@page", "@import", "@font-face", "column-count", "column-width", "position: fixed", "animation",
            ] {
                #expect(!css.contains(word), "\(theme.id) \(word)")
            }
            #expect(css.matches(of: /url\(\s*(?!["']?data:)/).isEmpty, "\(theme.id)")
        }
    }
}

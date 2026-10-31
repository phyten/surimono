import Foundation

/// The bundled KaTeX fonts under names a print theme or a user's CSS can set text in. The math fonts are embedded
/// only for the formulas a document has; a style sheet that names one of these families gets its faces embedded too,
/// as data URLs, so the paper needs no installed font and no network.
///
/// The families are separate from the math fonts' names and cover Latin letters only: Japanese text, and marks such
/// as … and arrows that Japanese text uses, are left to the fonts that come next in the theme's list.
public enum ThemeFonts {
    private struct Family {
        let name: String
        let source: String
    }

    private static let families = [
        Family(name: "Surimono Computer Modern", source: "KaTeX_Main"),
        Family(name: "Surimono Computer Modern Typewriter", source: "KaTeX_Typewriter"),
    ]

    private static let variants = [("normal", "normal"), ("bold", "normal"), ("normal", "italic"), ("bold", "italic")]

    /// Latin letters, Latin-1 and the typographic quotes and dashes; a character the font lacks falls back anyway.
    private static let unicodeRange =
        "U+0020-007E, U+00A0-00FF, U+0131, U+0152-0153, U+2013-2014, U+2018-201D, U+2020-2021"

    /// Each family's rules, built once: the bundled files do not change while the app runs.
    private static let rules: [String: String] = Dictionary(
        uniqueKeysWithValues: families.map { family in
            let faces = variants.compactMap { weight, style -> String? in
                guard let data = MathRenderer.fontData(family: family.source, weight: weight, style: style) else {
                    return nil
                }
                return "@font-face { font-family: \"\(family.name)\"; font-weight: \(weight); font-style: \(style); "
                    + "unicode-range: \(unicodeRange); "
                    + "src: url(\"data:font/ttf;base64,\(data.base64EncodedString())\") format(\"truetype\"); }"
            }
            return (family.name, faces.joined(separator: "\n"))
        })

    /// `@font-face` rules for every face of the families `css` names in quotes, or nothing when it names none.
    public static func faces(forStyleSheet css: String) -> String {
        // Quoted, so the Typewriter family's name does not also count as the roman one's.
        families.filter { css.contains("\"\($0.name)\"") || css.contains("'\($0.name)'") }
            .compactMap { rules[$0.name] }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

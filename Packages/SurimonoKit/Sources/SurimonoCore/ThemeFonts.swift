import Foundation
import SurimonoFormats

/// Theme and user style sheets opt into CM Unicode by naming its CSS families.
/// Data URLs travel with a palette sample, printed document or offline HTML export.
public enum ThemeFonts {
    public static let textFamilies = [ComputerModernFamily.roman.rawValue, ComputerModernFamily.typewriter.rawValue]

    public static let textFaces = embedded(textFamilies)

    // A standalone HTML file redistributes the complete font files, so it carries their notice too.
    private static let notice =
        Bundle.module.url(forResource: "CMU-Fonts-OFL", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { "/*\n" + $0 + "*/" } ?? ""

    private static func embedded(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        return ([notice] + names.compactMap { rules[$0] }).joined(separator: "\n")
    }

    // The cmap decides coverage within these script blocks. Keep CJK, mathematical symbols and
    // full-width punctuation in the following family, including the ellipsis used in Japanese.
    private static let unicodeRange =
        "U+0020-007E, U+00A0-024F, U+0300-036F, U+0370-052F, U+1E00-1FFF, "
        + "U+2000-200B, U+2010-2014, U+2018-2022, U+202F, U+2030-2031, U+2039-203A, U+20AC, U+2116"

    private static let rules = Dictionary(
        uniqueKeysWithValues: ComputerModernFamily.allCases.map { family in
            let faces = family.faces.compactMap { file, weight, style -> String? in
                guard let data = ComputerModernFamily.data(for: file) else { return nil }
                // WebKit treats bare oblique and italic as the same slope. Advertise the real OTF angle.
                let slope: String
                if family == .sans && style == "oblique"
                    || family == .typewriter && style == "italic" && weight == "bold"
                {
                    // Sans has only obliques; the bold typewriter has only an italic.
                    slope = "oblique 9.46deg 14deg"
                } else {
                    slope = style == "oblique" ? "oblique 9.46deg" : style
                }
                return
                    "@font-face { font-family: \"\(family.rawValue)\"; font-weight: \(weight); font-style: \(slope); "
                    // PDFKit preserves ffi as U+FB03 in Quartz subsets. Disable common ligatures on text faces only.
                    + "font-feature-settings: \"liga\" 0; unicode-range: \(unicodeRange); "
                    + "src: url(\"data:font/otf;base64,\(data.base64EncodedString())\") format(\"opentype\"); }"
            }
            return (family.rawValue, faces.joined(separator: "\n"))
        })

    // Sum of the lowercase alphabet advances: cmcsc10.tfm = 15.26329em,
    // Iowan Old Style Roman with smcp = 16.66945em.
    package static let smallCapScale = 0.9156

    // Only lowercase and their combining marks need the substitute. Capitals, figures and
    // punctuation use the original CMU advances, even when a label contains several scripts.
    private static let searchableSmallCaps: String = {
        let blocks = [0x61...0x24F, 0x300...0x52F, 0x1E00...0x1FFF]
        let letters = blocks.flatMap { $0 }.filter { code in
            guard let category = Unicode.Scalar(code)?.properties.generalCategory else { return false }
            return category == .lowercaseLetter || category == .nonspacingMark
        }
        var ranges: [ClosedRange<Int>] = []
        for code in letters {
            if let previous = ranges.last, previous.upperBound + 1 == code {
                ranges[ranges.count - 1] = previous.lowerBound...code
            } else {
                ranges.append(code...code)
            }
        }
        let coverage = ranges.map { range in
            let start = "U+" + String(range.lowerBound, radix: 16)
            return range.lowerBound == range.upperBound ? start : start + "-" + String(range.upperBound, radix: 16)
        }.joined(separator: ",")
        return [("Roman", "normal"), ("Bold", "bold")].map { face, weight in
            let size = weight == "normal" ? "size-adjust: \(smallCapScale * 100)%;" : ""
            return
                #"@font-face { font-family: "Surimono Searchable Small Caps"; src: local("IowanOldStyle-\#(face)"); font-weight: \#(weight); \#(size) unicode-range: \#(coverage); }"#
        }.joined(separator: "\n")
    }()

    /// Quoting a family keeps a Typewriter-only sheet from pulling in the roman faces too.
    public static func faces(forStyleSheet css: String) -> String {
        let names = ComputerModernFamily.allCases.map(\.rawValue).filter {
            css.contains("\"\($0)\"") || css.contains("'\($0)'")
        }
        let faces = embedded(names)
        return css.contains(#""Surimono Searchable Small Caps""#) ? faces + "\n" + searchableSmallCaps : faces
    }
}

import CoreText
import Foundation

package enum LaTeXIdeographs {
    // U+2F00…U+2FD5 have one unified counterpart each. Never normalise document text:
    // a literal Kangxi radical in the source must stay a Kangxi radical.
    private static let radicalPairs: [UniChar] = (0x2F00...0x2FD5).flatMap { value -> [UniChar] in
        guard let scalar = UnicodeScalar(value),
            let unified = String(scalar).precomposedStringWithCompatibilityMapping.utf16.first
        else { return [] }
        return [UInt16(value), unified]
    }

    package static let unifiedRange = stride(from: 1, to: radicalPairs.count, by: 2)
        .map { String(format: "U+%04X", radicalPairs[$0]) }.joined(separator: ",")

    // A PDF font may reverse-map a shared glyph to either member. Only compare this one-to-one
    // pair: the caller needs the original UTF-16 offsets and spelling, including literal radicals.
    package static func isRadicalPair(_ first: UniChar, _ second: UniChar) -> Bool {
        let radical = min(first, second)
        guard (0x2F00...0x2FD5).contains(radical) else { return false }
        let index = 2 * Int(radical - 0x2F00)
        return index + 1 < radicalPairs.count && radicalPairs[index] == radical
            && radicalPairs[index + 1] == max(first, second)
    }

    // These faces have been checked by drawing glyph IDs to PDF and extracting all 214 scalars.
    // Some do share glyphs but choose the unified character for the PDF's reverse map.
    private static let verifiedFaces: Set<String> = [
        "HiraMinProN-W3", "HiraMinProN-W6", "HiraKakuProN-W3", "HiraKakuProN-W6",
        "HiraginoSans-W3", "HiraginoSansGB-W3", "HiraginoSansGB-W6",
        "SimSong-Regular", "SimSong-Bold", "STFangsong", "YuGo-Medium", "YuGo-Bold",
    ]

    static func needsFallback(_ font: CTFont) -> Bool {
        guard !verifiedFaces.contains(CTFontCopyPostScriptName(font) as String) else { return false }
        var glyphs = [CGGlyph](repeating: 0, count: radicalPairs.count)
        CTFontGetGlyphsForCharacters(font, radicalPairs, &glyphs, glyphs.count)
        return stride(from: 0, to: glyphs.count, by: 2).contains { glyphs[$0] != 0 && glyphs[$0] == glyphs[$0 + 1] }
    }
}

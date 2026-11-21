import Foundation

/// Only values set by the document or its class are carried with the text. Leaving
/// ordinary paragraphs unmarked also keeps the reader independent of the display plan.
struct LaTeXLineParameters: Encodable, Equatable {
    var pretolerance: Int?
    var tolerance: Int?
    var hyphenpenalty: Int?
    var exhyphenpenalty: Int?
    var linepenalty: Int?
    var adjdemerits: Int?
    var doublehyphendemerits: Int?
    var finalhyphendemerits: Int?
    var emergencystretch: String?
    var frenchspacing: Bool?
    var hyphenation: String?

    mutating func setSloppy(_ enabled: Bool) {
        tolerance = enabled ? 9999 : 200
        emergencystretch = enabled ? "3em" : "0px"
    }

    var attribute: String {
        guard self != Self() else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "" }
        return " data-latex-line-parameters=\"\(HTML.escape(String(decoding: data, as: UTF8.self)))\""
    }
}

/// Standard classes and their derived conference styles enter these environments
/// with local settings, even when the surrounding paragraph explicitly selects fussy.
struct LaTeXLineContexts: Encodable, Equatable, Sendable {
    struct Settings: Encodable, Equatable, Sendable {
        var tolerance = 9999
        var emergencystretch = "3em"
        var periodSpaceFactor: Int?
        var fontSizePt: Double?
        var firstIndentEm: Double?
        var paragraphIndentEm: Double?
    }

    // The kernel's parbox restore calls sloppy for all three kinds of box.
    var footnote: Settings
    let caption = Settings()
    let minipage = Settings()
    // Both standard thebibliography and natbib also reset the period's sfcode.
    let bibliography = Settings(periodSpaceFactor: 1000)

    init(footnoteSize: Double) {
        footnote = Settings(fontSizePt: footnoteSize, firstIndentEm: 1.8, paragraphIndentEm: 1)
    }

    var attribute: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "" }
        return " data-latex-context-parameters=\"\(HTML.escape(String(decoding: data, as: UTF8.self)))\""
    }
}

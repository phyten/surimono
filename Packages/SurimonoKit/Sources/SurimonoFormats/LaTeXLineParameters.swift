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

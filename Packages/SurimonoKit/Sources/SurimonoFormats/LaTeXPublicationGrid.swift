import Foundation

/// Fixed trim and type-area registers of a journal. Lengths are in TeX points.
struct PublicationGrid: Equatable, Sendable {
    let width: Double
    let height: Double
    let top: Double
    let headHeight: Double
    let headSep: Double
    let footSkip: Double
    let columnGap: Double
    let bodySize: Double
    let pitch: Double
    let characterWidth: Double?
    var raggedColumns = false
    var charactersPerColumn: Int? = nil
    struct JapaneseScales: Equatable, Sendable {
        var title, author, abstract, note, caption: Double
    }
    var japaneseScales: JapaneseScales? = nil

    // A journal may round its type area down to a whole TeX point after selecting the nominal Q size.
    var japaneseScale: Double? {
        guard let characterWidth else { return nil }
        let column = (width - columnGap) / 2
        let fitted = charactersPerColumn.map { column / Double($0) } ?? characterWidth
        return min(characterWidth, fitted) / bodySize
    }
    let indent: Double
    let topSkip: Double
    let noteSize: Double
    let notePitch: Double
    let noteSkip: Double
    enum FloatSize: String {
        case small, footnotesize
    }
    var noteStretch = 4.0
    var noteShrink = 2.0
    let floatStretch: Double
    let floatShrink: Double
    let floatSize: FloatSize
    let floatPitch: Double
    let ruleWidth: Double
    let displaySkip: Double
    let tagInset: Double
    let floatSkip: Double
    let textFloatSkip: Double

    var variables: [String: String] {
        var registers = [
            "body-size": bodySize, "body-pitch": pitch, "parindent": indent, "parskip": 0,
            "topskip": topSkip, "note-size": noteSize, "note-pitch": notePitch, "skip-footins": noteSkip,
            "mathindent": indent, "display-skip": displaySkip, "tag-inset": tagInset,
            "float-rule-width": ruleWidth,
            "floatsep": floatSkip, "intextsep": floatSkip, "textfloatsep": textFloatSkip, "columnsep": columnGap,
        ]
        registers["zw"] = characterWidth ?? bodySize
        var result = registers.mapValues { "calc(\(LaTeXPageSettings.number($0)) * var(--tex-pt))" }
        // Array struts also multiply by arraystretch and the table's local size declarations.
        result["float-row-baseline"] = LaTeXPageSettings.number(floatPitch)
        for (key, natural, plus, minus) in [
            ("footins", noteSkip, noteStretch, noteShrink), ("floatsep", floatSkip, floatStretch, floatShrink),
            ("textfloatsep", textFloatSkip, floatStretch, floatShrink),
        ] {
            result["glue-" + key] = [natural, plus, minus].map(LaTeXPageSettings.number).joined(separator: " ")
        }
        return result
    }
}

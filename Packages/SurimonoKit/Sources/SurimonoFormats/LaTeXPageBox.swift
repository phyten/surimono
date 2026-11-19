import Foundation

/// Physical PDF points (72/in), independent of the output stock and of the CSS print pixel ratio.
public struct LaTeXPageBox: Equatable, Sendable {
    public let paperWidth: Double
    public let paperHeight: Double
    public let left: Double
    public let right: Double
    public let top: Double
    public let bottom: Double
    public let headSep: Double
    public let footSkip: Double
    public let mirrorsSides: Bool
    package var usesFixedClassOrigin = false

    public var textWidth: Double { paperWidth - left - right }
    public var textHeight: Double { paperHeight - top - bottom }
}

/// A publication option can select a different stock, column grid and text block within the same class.
enum LaTeXPublicationLayout: Equatable, Sendable {
    case ieeeConference, ieeeJournal, sigconf, manuscript, aps, lncs, elsevierOne, elsevierThree, elsevierFive

    init?(name: String, options: [String]) {
        switch name {
        case "IEEEtran": self = options.contains("conference") ? .ieeeConference : .ieeeJournal
        case "acmart":
            let formats = [
                "manuscript", "acmsmall", "acmlarge", "acmtog", "sigconf", "siggraph", "sigplan", "sigchi", "sigchi-a",
                "acmengage", "acmcp",
            ]
            let format = options.map { $0.hasPrefix("format=") ? String($0.dropFirst(7)) : $0 }.last(
                where: formats.contains)
            switch format {
            case "sigconf": self = .sigconf
            case "manuscript", nil: self = .manuscript
            default: return nil
            }
        case "revtex4-2": self = .aps
        case "llncs": self = .lncs
        case "elsarticle":
            switch options.last(where: { ["1p", "3p", "5p", "preprint"].contains($0) }) {
            case "1p": self = .elsevierOne
            case "3p": self = .elsevierThree
            case "5p": self = .elsevierFive
            default: return nil  // Preprint inherits the article class registers.
            }
        default: return nil
        }
    }

    var usesA4: Bool { self == .elsevierOne || self == .elsevierThree || self == .elsevierFive }

    func columnGap(size: Int) -> Double? {
        switch self {
        case .ieeeConference, .ieeeJournal: 12
        case .sigconf, .elsevierThree: 24
        case .aps where size == 10, .elsevierFive: 18
        default: nil
        }
    }
    /// The PDF layout uses the natural length of each glue register.
    func floatStyleVariables(size: Int) -> [String: String] {
        let skips: [String: Double]
        switch self {
        case .ieeeConference, .ieeeJournal:
            let baseline = size == 11 ? 13.3846 : size == 12 ? 13.92 : 12
            skips = [
                "intextsep": 0.85 * baseline, "textfloatsep": 1.55 * baseline, "floatsep": 0.85 * baseline,
                "abovecaptionskip": 0.5 * baseline,
            ]
        case .sigconf, .manuscript:
            // acmart loads amsart and caption with position=top for table captions.
            skips = ["textfloatsep": 15, "intextsep": 12, "abovecaptionskip": 12]
        case .aps:
            skips = ["intextsep": size == 10 ? 12 : 14, "floatsep": size == 10 ? 12 : 14, "belowcaptionskip": 2]
        case .lncs:
            let eightMM = 8 * 72.27 / 25.4
            skips = ["textfloatsep": eightMM, "intextsep": eightMM, "table-caption-skip": 10]
        case .elsevierOne, .elsevierThree, .elsevierFive:
            return [:]
        }
        return skips.mapValues { "calc(\(LaTeXPageSettings.number($0)) * var(--tex-pt))" }
    }
}

/// TeX registers must be resolved in TeX points (72.27/in): the standard classes truncate their
/// offsets to whole TeX points and all these classes snap the text height to a whole number of lines.
struct LaTeXClassBox {
    var width: Double
    var height: Double
    var left: Double
    var top: Double
    var headHeight: Double
    var headSep: Double
    var footSkip: Double

    // Default odd-page margins (left/right/top/bottom, PDF pt, rounded), from TeX Live 2026's
    // size*.clo, bk*.clo and ltjsarticle.cls registers. The geometry logs 006–010 and the
    // 451.42 pt text width in the reference PDF for 062 use this same TeX-to-PDF conversion.
    // The jlreq rows are calculated from jlreq.cls's default horizontal line and character grid.
    // Class           Stock       10 pt                 11 pt                 12 pt
    // article/report  A4       125/127/126/120        118/119/127/122        103/104/129/123
    // article/report  Letter   134/135/125/119        126/128/130/123        111/113/126/120
    // book            A4       100/152/125/121         94/143/126/123         82/125/127/125
    // book            Letter   107/161/124/120        101/152/128/125         89/135/124/122
    // js/ltjsarticle  A4         72/72/112/95           76/76/109/90           77/77/118/97
    // js/ltjsarticle  Letter     76/76/103/86           74/74/110/92           74/74/112/91
    // jlreq           A4         78/78/110/112          78/78/107/109          76/76/109/112
    // jlreq           Letter     77/77/102/104          81/81/100/103          79/79/104/107
    static func defaults(
        info: LaTeXDocumentClassInfo, paperWidth: Double, paperHeight: Double, twoSided: Bool
    ) -> Self {
        let className = info.name
        let size = info.pointSize
        if className == "jlreq" {
            let zw = Double(size)
            let baseline = 1.7 * zw
            let width = floor(0.75 * paperWidth / zw) * zw
            let height = floor((0.75 * paperHeight - zw) / baseline) * baseline + zw
            // The horizontal jlreq JFM puts 88% of the full-width glyph above its baseline.
            let glyphHeight = 0.88 * zw
            return Self(
                width: width, height: height, left: (paperWidth - width) / 2,
                top: (paperHeight - height) / 2 - zw + glyphHeight, headHeight: zw,
                headSep: zw + glyphHeight, footSkip: 3 * zw)
        }
        if ["jsarticle", "ltjsarticle", "bxjsarticle"].contains(className) {
            let scale = size == 11 ? 1.095 : Double(size) / 10
            let zw = 9.24715 * scale
            let width = floor(0.76 * paperWidth / zw) * zw
            let baseline = 16 * scale
            let headHeight = 20 * scale
            let topSkip = 1.38 * zw
            let footSkip = max(0.03367 * paperHeight, baseline)
            let headSep = footSkip - topSkip
            let available = 0.83 * paperHeight - 10 * scale - headSep - footSkip - topSkip
            let height = floor(available / baseline) * baseline + topSkip + 0.1 * scale
            let top = (paperHeight - height - 10 * scale - headSep - footSkip) / 2 + headHeight + headSep
            return Self(
                width: width, height: height, left: (paperWidth - width) / 2, top: top,
                headHeight: headHeight, headSep: headSep, footSkip: footSkip)
        }
        let inch = 72.27
        let book = className == "book"
        let baseline = size == 10 ? 12.0 : size == 11 ? 13.6 : 14.5
        let classWidth = size == 10 ? 345.0 : size == 11 ? 360.0 : 390.0
        let doubleMeasure = info.columns == 2 && ["article", "report", "book"].contains(className)
        let width = max(1, floor(min(paperWidth - 2 * inch, doubleMeasure ? 2 * classWidth : classWidth)))
        let height = max(0, floor((paperHeight - 3.5 * inch) / baseline)) * baseline + Double(size)
        let headSep = book ? (size == 10 ? 0.25 : 0.275) * inch : 25
        let footSkip = book && size != 12 ? (size == 10 ? 0.35 : 0.38) * inch : 30
        let oddSideMargin = ((paperWidth - width) * (twoSided ? 0.4 : 0.5) - inch).rounded(.towardZero)
        let topMargin = ((paperHeight - 2 * inch - 12 - headSep - height - footSkip) / 2).rounded(.towardZero)
        let standard = Self(
            width: width, height: height, left: inch + oddSideMargin, top: inch + topMargin + 12 + headSep,
            headHeight: 12, headSep: headSep, footSkip: footSkip)
        guard let publication = info.publication else { return standard }
        switch publication {
        case .lncs:
            // llncs replaces the article body and running-head separation after loading the class.
            return Self(
                width: 122 * inch / 25.4, height: 193 * inch / 25.4, left: inch + 63,
                top: inch + topMargin + 12 + 16, headHeight: 12, headSep: 16, footSkip: 30)
        case .ieeeConference, .ieeeJournal:
            // IEEEtran quantizes the column to whole baselines, then places the running furniture
            // using the height and depth of sample Times glyphs. These are the resolved Letter
            // registers, in TeX points. On A4 only the side margins and the centred footer move.
            let registers: (height: Double, top: Double, headSep: Double, footSkip: Double)
            switch (publication, size) {
            case (.ieeeConference, 11): registers = (669.2299, 47.7998, 18.2096, 41.9669)
            case (.ieeeConference, 12): registers = (668.1599, 48.4673, 18.6096, 42.2764)
            case (.ieeeConference, _): registers = (672, 47.1312, 18.5676, 40.5821)
            case (_, 11): registers = (695.9991, 51.9638, 20.2916, 26.5003)
            case (_, 12): registers = (695.9999, 52.0960, 20.4240, 26.5420)
            default: registers = (696, 52.6800, 21.3420, 25.8077)
            }
            return Self(
                width: 516, height: registers.height, left: (paperWidth - 516) / 2, top: registers.top,
                headHeight: 12, headSep: registers.headSep, footSkip: registers.footSkip + (paperHeight - 11 * inch) / 2
            )
        case .sigconf, .manuscript:
            // acmart loads 9pt amsart. geometry rounds the text height to its line grid;
            // the manuscript option applies setspace's one-and-a-half spacing first.
            let conference = publication == .sigconf
            let baseline = conference ? 11.0 : 13.75
            let goal = conference ? paperHeight - 57 - 73 - 13 - 14 - 12 : 0.7 * paperHeight
            let body = 10 + ((goal - 10) / baseline).rounded() * baseline
            return Self(
                width: conference ? paperWidth - 108 : 0.7 * paperWidth, height: body,
                left: conference ? 54 : paperWidth * (twoSided ? 0.12 : 0.15),
                top: conference ? 84 : paperHeight * 0.12, headHeight: 13, headSep: 14, footSkip: 12)
        case .aps:
            // REVTeX chooses the APS grid by point size; preprint selects 12pt, reprint 10pt.
            if size == 10 {
                return Self(
                    width: 510, height: 672, left: twoSided ? inch - 20 : 0.75 * inch,
                    top: inch - 20, headHeight: 25, headSep: 16, footSkip: 30)
            }
            return Self(width: 468, height: 665.5, left: inch, top: inch, headHeight: 12, headSep: 25, footSkip: 30)
        case .elsevierOne, .elsevierThree, .elsevierFive:
            let measure: Double = publication == .elsevierOne ? 384 : publication == .elsevierThree ? 468 : 522
            let goal: Double = publication == .elsevierOne ? 562 : publication == .elsevierThree ? 622 : 682
            return Self(
                width: measure, height: goal, left: (paperWidth - measure) / 2, top: (paperHeight - goal) / 2,
                headHeight: 50, headSep: 12, footSkip: publication == .elsevierOne ? 12 : 18)
        }
    }
}

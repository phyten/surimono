import Foundation

/// Physical PDF points (72/in), independent of the output stock and of the CSS print pixel ratio.
public struct LaTeXPageBox: Equatable, Sendable {
    public let paperWidth: Double
    public let paperHeight: Double
    public let left: Double
    public package(set) var right: Double
    public let top: Double
    public let bottom: Double
    public let headSep: Double
    public let footSkip: Double
    public let mirrorsSides: Bool
    package var evenLeft: Double?
    package var usesFixedClassOrigin = false

    var turnedForLandscape: Self {
        Self(
            paperWidth: paperHeight, paperHeight: paperWidth, left: bottom, right: top,
            top: left, bottom: right, headSep: headSep, footSkip: footSkip,
            mirrorsSides: mirrorsSides, usesFixedClassOrigin: usesFixedClassOrigin)
    }

    public var textWidth: Double { paperWidth - left - right }
    public var textHeight: Double { paperHeight - top - bottom }
}

/// A publication option can select a different stock, column grid and text block within the same class.
enum LaTeXPublicationLayout: Equatable, Sendable {
    case ieeeConference, ieeeJournal, sigconf, manuscript, aps, lncs, elsevierOne, elsevierThree, elsevierFive

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
    var evenLeft: Double?

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
        let size = info.pointSize
        if let grid = info.profile.page.fixedGrid {
            return Self(
                width: grid.width, height: grid.height, left: (paperWidth - grid.width) / 2, top: grid.top,
                headHeight: grid.headHeight, headSep: grid.headSep, footSkip: grid.footSkip)
        }
        switch info.profile.page.layoutRule {
        case .typeArea:
            return typeAreaBox(info, width: paperWidth, height: paperHeight, twoSided: twoSided)
        case .ruledBook:
            return ruledBookBox(info, width: paperWidth, height: paperHeight, twoSided: twoSided)
        case .ams(let footSkip):
            // calclayout centres the 30pc by 50.5pc area including the 8pt head and its 14pt separation.
            let measure = 360.0
            let height = info.usesAMSA4Layout ? 654.0 : 606.0
            let left = max(36.135, (paperWidth - measure) / 2)
            return Self(
                width: measure, height: height - 22, left: left,
                top: max(36.135, (paperHeight - height) / 2) + 22, headHeight: 8, headSep: 14,
                footSkip: footSkip, evenLeft: info.profile.page.usesFixedClassOrigin ? left : nil)
        case .exam:
            let inch = 72.27
            return Self(
                width: paperWidth - 2 * inch, height: paperHeight - 2.2 * inch, left: inch, top: inch,
                headHeight: 15, headSep: 15, footSkip: 29)
        case .characterGrid:
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
        case .scaledGrid(let scale, let book, let centersFurniture):
            let zw = 9.24715 * scale
            let unit = info.columns == 2 ? 2 * zw : zw
            let full = book ? paperWidth - 36 * scale * 72.27 / 25.4 : 0.76 * paperWidth
            let fullWidth = floor(full / unit) * unit
            let width = book && info.columns == 1 ? min(fullWidth, 40 * zw) : fullWidth
            let baseline = LaTeXLabelMetrics(info).baselines[4]
            let headHeight = 20 * scale
            if centersFurniture {
                // BXjs lets geometry centre the head, text and foot together, then rounds the text to whole lines.
                let topSkip = 10 * scale
                let foot = book ? 0 : 0.03367 * paperHeight
                let sep = book ? 6 * scale * 72.27 / 25.4 : foot - topSkip
                let available = 0.83 * paperHeight - 2 * topSkip - sep - foot
                let height = floor((available + 0.005) / baseline) * baseline + topSkip
                let top = (paperHeight - height + topSkip + sep - foot) / 2
                return Self(
                    width: width, height: height, left: (paperWidth - fullWidth) / 2,
                    top: top, headHeight: headHeight, headSep: sep, footSkip: foot)
            }
            let topSkip = 1.38 * zw
            let footSkip = book ? 0 : max(0.03367 * paperHeight, baseline)
            let headSep = (book ? (6 * 72.27 / 25.4 + 10) * scale : footSkip) - topSkip
            let available = 0.83 * paperHeight - 10 * scale - headSep - footSkip - topSkip
            let height = floor(available / baseline) * baseline + topSkip + 0.1 * scale
            let top = (paperHeight - height - 10 * scale - headSep - footSkip) / 2 + headHeight + headSep
            return Self(
                width: width, height: height, left: (paperWidth - fullWidth) / 2, top: top,
                headHeight: headHeight, headSep: headSep, footSkip: footSkip)
        case .standard(let measure):
            return standardBox(
                info, measure: measure, paperWidth: paperWidth, paperHeight: paperHeight, twoSided: twoSided)
        }
    }

    private static func standardBox(
        _ info: LaTeXDocumentClassInfo, measure: LaTeXClassProfile.StandardMeasure,
        paperWidth: Double, paperHeight: Double, twoSided: Bool
    ) -> Self {
        let size = info.pointSize
        let inch = 72.27
        let book = measure == .bookOffsets || measure == .traditionalBook
        let traditional = measure == .traditionalBook || measure == .traditionalArticle
        let baseline = traditional ? [15, 15.5, 16.5][size - 10] : [12, 13.6, 14.5][size - 10]
        let classWidth: Double = traditional ? [327, 342, 372][size - 10] : [345, 360, 390][size - 10]
        let doubleMeasure = info.columns == 2 && (measure == .doubleColumn || book || traditional)
        let width = max(1, floor(min(paperWidth - 2 * inch, doubleMeasure ? 2 * classWidth : classWidth)))
        // The traditional size files truncate the line grid plus the height of 漢 to whole TeX points.
        let topSkip = traditional ? [8.46753, 9.27193, 10.16104][size - 10] : Double(size)
        let naturalHeight = max(0, floor((paperHeight - 3.5 * inch) / baseline)) * baseline + topSkip
        let height = traditional ? floor(naturalHeight) : naturalHeight
        if measure == .letterOffsets {
            return Self(
                width: width, height: height, left: (paperWidth - width) / 2, top: inch + 27 + 12 + 45,
                headHeight: 12, headSep: 45, footSkip: 25)
        }
        let headSep = book ? (size == 10 ? 0.25 : 0.275) * inch : 25
        let footSkip = book && size != 12 ? (size == 10 ? 0.35 : 0.38) * inch : 30
        let oddSideMargin = ((paperWidth - width) * (twoSided ? 0.4 : 0.5) - inch).rounded(.towardZero)
        let topMargin = ((paperHeight - 2 * inch - 12 - headSep - height - footSkip) / 2).rounded(.towardZero)
        // The jclasses truncate the two side registers independently before shipping a spread.
        let evenLeft = traditional && twoSided ? inch + ((paperWidth - width) * 0.6 - inch).rounded(.towardZero) : nil
        let standard = Self(
            width: width, height: height, left: inch + oddSideMargin, top: inch + topMargin + 12 + headSep,
            headHeight: 12, headSep: headSep, footSkip: footSkip, evenLeft: evenLeft)
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

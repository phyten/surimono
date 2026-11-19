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

    public var textWidth: Double { paperWidth - left - right }
    public var textHeight: Double { paperHeight - top - bottom }
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
        className: String, size: Int, paperWidth: Double, paperHeight: Double, twoSided: Bool
    ) -> Self {
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
        let width = max(1, floor(min(paperWidth - 2 * inch, classWidth)))
        let height = max(0, floor((paperHeight - 3.5 * inch) / baseline)) * baseline + Double(size)
        let headSep = book ? (size == 10 ? 0.25 : 0.275) * inch : 25
        let footSkip = book && size != 12 ? (size == 10 ? 0.35 : 0.38) * inch : 30
        let oddSideMargin = ((paperWidth - width) * (twoSided ? 0.4 : 0.5) - inch).rounded(.towardZero)
        let topMargin = ((paperHeight - 2 * inch - 12 - headSep - height - footSkip) / 2).rounded(.towardZero)
        return Self(
            width: width, height: height, left: inch + oddSideMargin, top: inch + topMargin + 12 + headSep,
            headHeight: 12, headSep: headSep, footSkip: footSkip)
    }
}

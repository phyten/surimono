import Foundation
import SurimonoCore
import SurimonoFormats

extension LaTeXPageBox {
    /// The measure and the page goal belong to the document. Changing the stock redistributes the
    /// surrounding white space in its original ratio; only an oversized body uses the whole axis.
    func margins(fitting size: CGSize) -> PageMargins {
        func fit(_ first: Double, _ last: Double, measure: Double, extent: Double) -> (Double, Double) {
            let first = max(0, first)
            let last = max(0, last)
            // Contradictory registers can describe a zero or negative body; preserve a usable line in that case.
            let body = measure > 0 ? min(measure, extent) : min(72, extent / 2)
            let spare = max(0, extent - body)
            let leading = spare * (first + last > 0 ? first / (first + last) : 0.5)
            return (leading * 25.4 / 72, (spare - leading) * 25.4 / 72)
        }
        let (left, right) = fit(left, right, measure: textWidth, extent: size.width)
        let (top, bottom) = fit(top, bottom, measure: textHeight, extent: size.height)
        return PageMargins(top: top, left: left, bottom: bottom, right: right)
    }
}

extension RenderSettings {
    static let documentWidthCSS = "\nbody.format-latex[data-latex-size] { max-width: none; margin-inline: 0; }"

    mutating func applyLaTeXPage(_ info: LaTeXDocumentClassInfo) {
        if options.latexMargins?.applies(to: theme) == true && layout.kind != .handout3 {
            options.margins = info.pageBox.margins(fitting: layout.logicalPageSize(options: options))
            options.mirrorsDocumentPages = info.pageBox.mirrorsSides
            options.mirrorsMargins = info.pageBox.mirrorsSides
        }
        if options.latexFurniture?.applies(to: theme) == true {
            options.furniture = .pageNumber
            latexFooter = .init(
                fontName: info.mainFontName,
                pointSize: (info.pointSize == 11 ? 10.95 : Double(info.pointSize))
                    * (72 / 72.27) * textScale,
                footSkip: info.pageBox.footSkip, headSep: info.pageBox.headSep)
        }
    }
}

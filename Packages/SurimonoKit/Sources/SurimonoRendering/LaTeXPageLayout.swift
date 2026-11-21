import Foundation
import SurimonoCore
import SurimonoFormats

extension LaTeXPageBox {
    /// Keep the document's text block when changing stock. Most classes distribute the remaining
    /// space in the original margin ratio; classes with fixed offsets keep their leading margin.
    func margins(fitting size: CGSize) -> PageMargins {
        func fit(_ first: Double, _ last: Double, measure: Double, extent: Double) -> (Double, Double) {
            let first = max(0, first)
            let last = max(0, last)
            // Contradictory registers can describe a zero or negative body; preserve a usable line in that case.
            let body = measure > 0 ? min(measure, extent) : min(72, extent / 2)
            let spare = max(0, extent - body)
            // The REVTeX and LNCS class registers fix an absolute origin even when the PDF
            // driver's stock differs from the class's paper registers (references 080 and 090).
            let leading =
                usesFixedClassOrigin ? min(first, spare) : spare * (first + last > 0 ? first / (first + last) : 0.5)
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
            var box = info.pageBox
            // Fit the manuscript's margins first so changing stock cannot move the left edge of a proof.
            if info.composition == .proof { box.right -= LaTeXComposition.notesMarginMM * 72 / 25.4 }
            options.margins = box.margins(fitting: layout.logicalPageSize(options: options))
            let spare = box.left + box.right
            if let evenLeft = box.evenLeft, spare > 0 {
                let fitted = WebPaginator.Margins(options.margins)
                let room = fitted.left + fitted.right
                let origin = box.usesFixedClassOrigin ? evenLeft : room * evenLeft / spare
                options.versoOffset = min(room, max(0, origin)) - fitted.right
            } else {
                options.versoOffset = 0
            }
            options.mirrorsDocumentPages = info.pageBox.mirrorsSides
            options.mirrorsMargins = info.pageBox.mirrorsSides
        }
        if info.composition == .proof {
            options.proofNotesMargin = LaTeXComposition.notesMarginMM
            // Mirroring swaps the normal margins only. Keep the notes on the right of a verso too.
            options.versoOffset -= LaTeXComposition.notesMarginMM * 72 / 25.4
        }
        if options.latexFurniture?.applies(to: theme) == true {
            options.furniture = .pageNumber
            latexFooter = .init(
                fontName: info.mainFontName,
                pointSize: (info.pointSize == 11 ? 10.95 : Double(info.pointSize))
                    * (72 / 72.27) * textScale,
                footSkip: info.pageBox.footSkip, headSep: info.pageBox.headSep)
            latexFooter?.classSize = info.pointSize
            latexFooter?.japaneseFontName = info.japaneseMainFontName
            latexFooter?.japaneseFontScale = info.japaneseFurnitureScale
            latexFooter?.headerStrutDepth = info.headerStrutDepth * textScale
            if info.resolvedStyle != nil && info.headerStrutDepth > 0 {
                latexFooter?.headerRuleDepth = info.headerStrutDepth * textScale
            }
            latexFooter?.headerFont = info.pageHeadFont
            latexFooter?.numberFont = info.pageNumberFont
        }
    }
}

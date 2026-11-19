import Foundation

/// TeX points before document stretching. jsclasses magnifies the 10pt design
/// uniformly; the standard classes switch between size10, size11 and size12.
struct LaTeXLabelMetrics {
    // CSS consumes these ten skips in the order of LaTeX's size declarations.
    let baselines: [Double]
    let japaneseScale: Double?

    init(_ info: LaTeXDocumentClassInfo) {
        let index = info.pointSize - 10
        let js = ["jsarticle", "jsreport", "jsbook", "ltjsarticle", "ltjsreport", "ltjsbook"].contains(info.name)
        if js {
            let magnification = [1, 1.095, 1.2][index]
            baselines = [6, 8, 11, 13, 16, 17, 21, 25, 28, 33].map { $0 * magnification }
            japaneseScale = 0.924715
        } else if info.usesTraditionalJapaneseNames {
            baselines =
                [
                    [6, 8, 9.5, 11, 15, 17, 21, 25, 28, 33],
                    [7, 9.5, 11, 12, 15.5, 17, 21, 25, 28, 33],
                    [7, 9.5, 12, 13.6, 16.5, 21, 25, 28, 33, 33],
                ][index]
            japaneseScale = 0.962216
        } else {
            baselines =
                [
                    [6, 8, 9.5, 11, 12, 14, 18, 22, 25, 30],
                    [7, 9.5, 11, 12, 13.6, 14, 18, 22, 25, 30],
                    [7, 9.5, 12, 13.6, 14.5, 18, 22, 25, 30, 30],
                ][index]
            japaneseScale = nil
        }
    }

    private var japaneseAlias: String {
        japaneseScale == 0.924715 ? "Surimono JS Mincho" : "Surimono J Mincho"
    }

    // As with a fontspec selection, this face belongs to the document. Only the
    // Japanese class theme opts in to the alias, after document-selected faces.
    var localFace: String? {
        guard let japaneseScale,
            let font = LaTeXFontSettings.Selection(
                "HiraMinProN-W3", options: "BoldFont=HiraMinProN-W6,Scale=\(japaneseScale)", cjk: true)
        else { return nil }
        return font.faceCSS(alias: japaneseAlias)
    }

    var variables: String {
        var values = ["node-baselines": baselines.map(LaTeXPageSettings.number).joined(separator: " ")]
        if let japaneseScale {
            values["jfm-scale"] = LaTeXPageSettings.number(japaneseScale)
            values["jfm-face"] = "\"\(japaneseAlias)\""
        }
        return LaTeXPageSettings.cssVariables(values)
    }
}

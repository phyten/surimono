import Foundation

/// TeX points before document stretching. jsclasses magnifies the 10pt design
/// uniformly; the standard classes switch between size10, size11 and size12.
struct LaTeXLabelMetrics {
    // CSS consumes these ten skips in the order of LaTeX's size declarations.
    let baselines: [Double]
    let japaneseScale: Double?

    init(_ info: LaTeXDocumentClassInfo) {
        let index = info.pointSize - 10
        if let magnification = info.jsMagnification {
            let smallDesign = magnification < (info.name.hasPrefix("bx") ? 1 : 0.92)
            let normal = smallDesign ? 15.0 : 16.0
            baselines = [6, 8, 11, 13, normal, info.columns == 2 ? normal : 17, 21, 25, 28, 33].map {
                $0 * magnification
            }
            japaneseScale = 0.924715
        } else if info.name == "jlreq" {
            baselines = [6, 8, 11.5, 13, 17, 17, 21, 25, 28, 33].map { $0 * Double(info.pointSize) / 10 }
            japaneseScale = nil
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

    func baseline(for name: String) -> Double? {
        let names = [
            "tiny", "scriptsize", "footnotesize", "small", "normalsize", "large", "Large", "LARGE", "huge", "Huge",
        ]
        return names.firstIndex(of: name).map { baselines[$0] }
    }

    private var japaneseAlias: String {
        japaneseScale == 0.924715 ? "Surimono JS Mincho" : "Surimono J Mincho"
    }

    // The default faces are known by PostScript name, so an uncustomized document
    // needs no font-service round trip to build its Japanese body family.
    func localFace(fonts: LaTeXFontSettings) -> String? {
        guard let japaneseScale,
            let font = LaTeXFontSettings.Selection(
                "HiraMinProN-W3",
                options: (japaneseScale == 0.924715 ? "" : "BoldFont=HiraMinProN-W6,") + "Scale=\(japaneseScale)",
                cjk: true,
                knownPostScriptNames: true, index: fonts.index)
        else { return nil }
        if japaneseScale == 0.924715 {
            // The js body family switches to Gothic for its bold Japanese series, even
            // when the weight is inherited from a table column or a box title.
            let gothic = fonts.japaneseSans?.bold ?? fonts.japaneseSans?.name ?? "HiraKakuProN-W6"
            return (fonts.japaneseMain ?? font).faceCSS(alias: japaneseAlias, japaneseBold: gothic, index: fonts.index)
        }
        return font.faceCSS(alias: japaneseAlias, index: fonts.index)
    }

    func headingFace(index: InstalledFontIndex) -> String? {
        guard japaneseScale == 0.924715,
            let font = LaTeXFontSettings.Selection(
                "HiraKakuProN-W3", options: "BoldFont=HiraKakuProN-W6,Scale=0.924715", cjk: true,
                knownPostScriptNames: true, index: index)
        else { return nil }
        return font.faceCSS(alias: "Surimono JS Gothic", index: index)
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

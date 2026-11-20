import Foundation

/// TeX points before document stretching. jsclasses magnifies the 10pt design
/// uniformly; the standard classes switch between size10, size11 and size12.
struct LaTeXLabelMetrics {
    // CSS consumes these ten skips in the order of LaTeX's size declarations.
    let baselines: [Double]
    let japaneseScale: Double?

    init(_ info: LaTeXDocumentClassInfo) {
        if let style = info.resolvedStyle {
            baselines = [7, 8, style.notePitch, 10, style.baseline, 14, 16, 20, 23, 28]
            japaneseScale = nil
            return
        }
        let index = info.pointSize - 10
        switch info.profile.typography.baselineTable {
        case .scaled(let magnification, let smallBelow):
            let smallDesign = magnification < smallBelow
            let normal = smallDesign ? 15.0 : 16.0
            baselines = [6, 8, 11, 13, normal, info.columns == 2 ? normal : 17, 21, 25, 28, 33].map {
                $0 * magnification
            }
            japaneseScale = 0.924715
        case .characterGrid:
            baselines = [6, 8, 11.5, 13, 17, 17, 21, 25, 28, 33].map { $0 * Double(info.pointSize) / 10 }
            japaneseScale = nil
        case .ams:
            // The AMS classes define their own size ladder, including Small for footnotes.
            baselines =
                [
                    [7, 8, 10, 11, 12, 13, 14, 17, 20, 24],
                    [8, 10, 11, 12, 13, 14, 17, 20, 24, 30],
                    [10, 11, 12, 13, 14, 17, 20, 24, 30, 30],
                ][index]
            japaneseScale = nil
        case .traditional:
            baselines =
                [
                    [6, 8, 9.5, 11, 15, 17, 21, 25, 28, 33],
                    [7, 9.5, 11, 12, 15.5, 17, 21, 25, 28, 33],
                    [7, 9.5, 12, 13.6, 16.5, 21, 25, 28, 33, 33],
                ][index]
            japaneseScale = 0.962216
        case .standard:
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

    func headingFace(for info: LaTeXDocumentClassInfo, index: InstalledFontIndex) -> String? {
        guard info.profile.typography.selectsGothicHeadings else { return nil }
        // Harano Aji Gothic's vertical stem in 目 measures 93/1000 em in corpus 106.
        let candidates = ["HiraginoSans-W5", "HiraginoSans-W4", "HiraKakuProN-W3"]
        guard let face = candidates.lazy.compactMap({ index.face(named: $0) }).first else { return nil }
        let bold = "BoldFont=" + face.postScriptName
        guard
            let font = LaTeXFontSettings.Selection(
                face.postScriptName, options: bold, cjk: true, defaultScale: japaneseScale,
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

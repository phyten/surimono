import Foundation

/// The document's intended measure is independent of the stock and printable area chosen in Surimono.
struct LaTeXPageSettings {
    private var stock: (width: Double, height: Double)?
    private var paperWidth: Double?
    private var paperHeight: Double?
    private var landscape = false
    private var twoSided: Bool?
    private var usesGeometry = false
    private var horizontal = Axis()
    private var vertical = Axis()
    private var includeHead = false
    private var includeFoot = false
    private var heightIsText = false
    private var geometryHeadHeight: Double?
    private var geometryHeadSep: Double?
    private var geometryFootSkip: Double?
    // A register assignment after geometry moves the text block without asking geometry to rebalance it.
    private var assigned: [String: Double] = [:]
    var extraRowHeight: String?
    private var variables: [String: String] = [:]
    var captions = LaTeXCaptionStyle()
    var boxDefaults = LaTeXBoxOptions()
    var fonts: LaTeXFontSettings

    init(fontIndex: InstalledFontIndex = .system) { fonts = LaTeXFontSettings(index: fontIndex) }
    var columnTypes: [Character: String] = [:]
    var listSettings: [String: [String: String]] = [:]

    private struct Axis {
        var start: Double?
        var end: Double?
        var body: Double?
        var scale: Double?
        var centered = false

        func resolve(stock: Double, startFraction: Double, addedToBody: Double = 0) -> (start: Double, body: Double) {
            let fraction = centered ? 0.5 : startFraction
            if let start, let end { return (start, stock - start - end) }
            if body == nil, scale == nil {
                // With a single margin and no explicit body, geometry uses the leading share of
                // the default 30% spare space for its partner, even when the missing side is last.
                let partner = stock * 0.3 * fraction
                if let start { return (start, stock - start - (centered ? start : partner)) }
                if let end {
                    let leading = centered ? end : partner
                    return (leading, stock - leading - end)
                }
            }
            let measure = body.map { $0 + addedToBody } ?? stock * (scale ?? 0.7)
            let spare = stock - measure
            return (start ?? end.map { spare - $0 } ?? spare * fraction, measure)
        }
    }

    func pageBox(for info: LaTeXDocumentClassInfo) -> LaTeXPageBox {
        let stock = self.stock ?? info.profile.page.defaultPaper.millimetres
        let texPointsPerMM = 72.27 / 25.4
        let paperW = (paperWidth ?? (landscape ? stock.1 : stock.0)) * texPointsPerMM
        let paperH = (paperHeight ?? (landscape ? stock.0 : stock.1)) * texPointsPerMM
        let twoSided = self.twoSided ?? info.profile.page.twoSidedBox
        var box = LaTeXClassBox.defaults(
            info: info, paperWidth: paperW, paperHeight: paperH, twoSided: twoSided)
        if usesGeometry {
            let h = horizontal.resolve(stock: paperW, startFraction: twoSided ? 0.4 : 0.5)
            box.left = h.start
            box.width = h.body
            box.headHeight = geometryHeadHeight ?? box.headHeight
            box.headSep = geometryHeadSep ?? box.headSep
            box.footSkip = geometryFootSkip ?? box.footSkip
            let above = includeHead ? box.headHeight + box.headSep : 0
            let below = includeFoot ? box.footSkip : 0
            let v = vertical.resolve(stock: paperH, startFraction: 0.4, addedToBody: heightIsText ? above + below : 0)
            box.top = v.start + above
            box.height = v.body - above - below
        }
        let headHeight = assigned["headheight"] ?? box.headHeight
        let headSep = assigned["headsep"] ?? box.headSep
        let topMargin = assigned["topmargin"] ?? (box.top - 72.27 - box.headHeight - box.headSep)
        let top = 72.27 + topMargin + headHeight + headSep
        let left = assigned["oddsidemargin"].map { 72.27 + $0 } ?? box.left
        let bp = 72 / 72.27
        return LaTeXPageBox(
            paperWidth: paperW * bp, paperHeight: paperH * bp, left: left * bp,
            right: (paperW - left - (assigned["textwidth"] ?? box.width)) * bp, top: top * bp,
            bottom: (paperH - top - (assigned["textheight"] ?? box.height)) * bp,
            headSep: headSep * bp, footSkip: (assigned["footskip"] ?? box.footSkip) * bp, mirrorsSides: twoSided,
            usesFixedClassOrigin: !usesGeometry && assigned.isEmpty
                && info.profile.page.usesFixedClassOrigin)
    }

    var tableSpacing: [String: String] {
        get { variables.filter { LaTeXTable.spacingRegisters.contains($0.key) } }
        set {
            for key in LaTeXTable.spacingRegisters { variables[key] = newValue[key] }
        }
    }

    func styleVariables(for box: LaTeXPageBox, info: LaTeXDocumentClassInfo) -> String {
        var classSkips = info.publication?.floatStyleVariables(size: info.pointSize) ?? [:]
        if info.profile.body.usesSizeFileGlue {
            // size10/11/12.clo give listii the outer parsep as topsep and listiii the inner parsep.
            let outer = Double(info.pointSize - 10) / 2 + 4
            let inner = info.pointSize == 12 ? 2.5 : 2
            for (key, points) in [
                ("outer-parsep", outer), ("inner-parsep", inner), ("note-pitch", LaTeXLabelMetrics(info).baselines[2]),
                // fontmath.ltx uses 6pt scripts for 8/9pt notes, and 7pt scripts for 10pt notes.
                ("note-number-size", info.pointSize == 12 ? 7 : 6),
            ] {
                classSkips[key] = "calc(\(Self.number(points)) * var(--tex-pt))"
            }
        }
        if info.journalStyle == .ams {
            // amsart.cls and amsbook.cls set the footnote rule to five picas.
            classSkips["footnote-rule-width"] = "calc(60 * var(--tex-pt))"
        }
        switch info.profile.body.captionSkip {
        case .fiveScaledPoints:
            // The jsclasses size files put five magnified points on each side of a caption.
            for key in ["abovecaptionskip", "belowcaptionskip"] { classSkips[key] = "calc(5 * var(--js-pt))" }
        case .halfBaseline:
            // memoir sets both skips to half a normal baseline in its size file.
            let halfBaseline = info.pointSize == 12 ? "7.25" : info.pointSize == 11 ? "6.8" : "6"
            let skip = "calc(\(halfBaseline) * var(--tex-pt))"
            classSkips["abovecaptionskip"] = skip
            classSkips["belowcaptionskip"] = skip
        case .inherited: break
        }
        var values = classSkips.merging(variables) { _, assignment in assignment }.merging(fonts.roleVariables) {
            _, font in font
        }
        // Each table captures its register at the alignment. A later assignment must not repaint an earlier rule.
        values.removeValue(forKey: "arrayrulewidth")
        if info.profile.typography.selectsParagraphPitch, let skip = values["parskip"], skip.hasSuffix("lh"),
            let multiplier = Double(skip.dropLast(2))
        {
            values["parskip"] =
                "calc(\(Self.number(multiplier * LaTeXLabelMetrics(info).baselines[4])) * var(--tex-pt))"
        }
        values.merge(info.bookStyle.variables(size: info.pointSize)) { _, font in font }
        values["text-height-tex-pt"] = Self.number(box.textHeight * 72.27 / 72)
        let measure = box.textWidth
        if measure > 0 {
            values["text-width"] = Self.number(measure * 25.4 / 72) + "mm"
            values["text-width-tex-pt"] = Self.number(measure * 72.27 / 72)
        }
        for (edge, value) in [("left", box.left), ("right", box.right), ("top", box.top), ("bottom", box.bottom)] {
            values["margin-" + edge] = Self.number(value) + "pt"
        }
        values["foot-skip"] = Self.number(box.footSkip) + "pt"
        return Self.cssVariables(values)
    }

    static func cssVariables(_ values: [String: String]) -> String {
        values.keys.sorted().compactMap { key in values[key].map { "--latex-\(key): \($0)" } }.joined(separator: "; ")
    }

    static func number(_ value: Double) -> String { String(format: "%.9g", value) }

    /// Options in braces can contain comma-separated dimension pairs. Preserve their order for overrides.
    static func options(_ raw: String) -> [(key: String, value: String)] {
        var depth = 0
        return raw.split(whereSeparator: {
            if $0 == "{" { depth += 1 }
            if $0 == "}" { depth = max(depth - 1, 0) }
            return $0 == "," && depth == 0
        }).map {
            let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = pair.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var value = pair.count > 1 ? pair[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if value.first == "{", value.last == "}" { value = String(value.dropFirst().dropLast()) }
            return (key, value)
        }
    }

    private static let paperSizes: [String: (Double, Double)] = [
        "a0paper": (841, 1189), "a1paper": (594, 841), "a2paper": (420, 594), "a3paper": (297, 420),
        "a4paper": (210, 297), "a5paper": (148, 210), "a6paper": (105, 148),
        "b0paper": (1000, 1414), "b1paper": (707, 1000), "b2paper": (500, 707), "b3paper": (353, 500),
        "b4paper": (250, 353), "b5paper": (176, 250), "b6paper": (125, 176),
        "letterpaper": (215.9, 279.4), "legalpaper": (215.9, 355.6), "executivepaper": (184.15, 266.7),
    ]

    mutating func readClassOptions(_ raw: String, info: LaTeXDocumentClassInfo) {
        switch info.profile.page.paperOptions {
        case .standard: readOptions(raw, geometry: false)
        case .keyed: readOptions(raw, geometry: false, keyedPaper: true)
        case .japanese: readOptions(raw, geometry: false, japaneseStock: true)
        }
        // The production classes set their own stock with geometry after processing class options.
        if let forced = info.profile.page.forcedPaper { stock = forced.millimetres }
    }

    mutating func readOptions(_ raw: String, geometry: Bool, japaneseStock: Bool = false, keyedPaper: Bool = false) {
        if geometry {
            usesGeometry = true
            geometryHeadHeight = assigned["headheight"] ?? geometryHeadHeight
            geometryHeadSep = assigned["headsep"] ?? geometryHeadSep
            geometryFootSkip = assigned["footskip"] ?? geometryFootSkip
            assigned.removeAll()
        }
        for (key, value) in Self.options(raw) {
            let stockKey =
                key == "paper" && (japaneseStock || keyedPaper)
                ? value.replacingOccurrences(of: "paper", with: "") + "paper" : key
            if let size = Self.paperSizes[stockKey] {
                let jis: [String: (Double, Double)] = [
                    "b4paper": (257, 364), "b5paper": (182, 257), "b6paper": (128, 182),
                ]
                stock = japaneseStock ? (jis[stockKey] ?? size) : size
                paperWidth = nil
                paperHeight = nil
                continue
            }
            switch key {
            case "twoside": twoSided = value != "false"
            case "oneside": twoSided = value == "false"
            case "landscape": landscape = value != "false"
            case "portrait": landscape = value == "false"
            case "parskip" where !geometry:
                if value != "false", value != "never" {
                    variables["parindent"] = "0pt"
                    variables["parskip"] = value.hasPrefix("full") ? "1lh" : "0.5lh"
                }
            case "parskip-" where !geometry, "parskip+" where !geometry:
                variables["parindent"] = "0pt"
                variables["parskip"] = "1lh"
            default:
                if geometry { geometryOption(key, value) }
            }
        }
    }

    private mutating func geometryOption(_ key: String, _ value: String) {
        let pair = value.split(separator: ",", maxSplits: 1).map { String($0) }
        let first = pair.first.flatMap(Self.texPoints)
        let second = pair.count == 2 ? Self.texPoints(pair[1]) : first
        switch key {
        case "margin":
            if let first {
                horizontal.start = first
                horizontal.end = first
            }
            if let second {
                vertical.start = second
                vertical.end = second
            }
        case "hmargin":
            if let first {
                horizontal.start = first
                horizontal.end = second
            }
        case "vmargin":
            if let first {
                vertical.start = first
                vertical.end = second
            }
        case "left", "inner", "lmargin", "innermargin": if let first { horizontal.start = first }
        case "right", "outer", "rmargin", "outermargin": if let first { horizontal.end = first }
        case "top", "tmargin": if let first { vertical.start = first }
        case "bottom", "bmargin": if let first { vertical.end = first }
        case "textwidth", "width", "totalwidth", "total", "body":
            if let first, first > 0 { horizontal.body = first }
            if ["total", "body"].contains(key), pair.count == 2, let second, second > 0 {
                vertical.body = second
                heightIsText = false
            }
        case "textheight", "height", "totalheight":
            if let first, first > 0 {
                vertical.body = first
                heightIsText = key == "textheight"
            }
        case "scale", "hscale", "vscale":
            func factor(_ value: String?) -> Double? {
                guard let value, let factor = Double(value), factor > 0, factor <= 1 else { return nil }
                return factor
            }
            if key != "vscale", let scale = factor(pair.first) { horizontal.scale = scale }
            if key != "hscale", let scale = factor(pair.last) { vertical.scale = scale }
        case "centering", "hcentering", "vcentering":
            if key != "vcentering" { horizontal.centered = value != "false" }
            if key != "hcentering" { vertical.centered = value != "false" }
        case "includehead", "includefoot", "includeheadfoot":
            if key != "includefoot" { includeHead = value != "false" }
            if key != "includehead" { includeFoot = value != "false" }
        case "headheight": if let first { geometryHeadHeight = first }
        case "headsep": if let first { geometryHeadSep = first }
        case "footskip": if let first { geometryFootSkip = first }
        case "paperwidth", "paperheight", "columnsep": readLength(key, value)
        case "paper", "papername":
            if let size = Self.paperSizes[value] { stock = size }
        default: break
        }
    }

    var columnGap: Double?
    var columnRule = 0.0

    private static func texPoints(_ source: String) -> Double? {
        millimetres(source).map { $0 * (72.27 / 25.4) }
    }

    static func millimetres(_ source: String) -> Double? {
        let raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = String(raw.suffix(2))
        guard raw.utf8.count < 64, raw.count > 2, unit != "ex", unit != "em",
            let ratio = LaTeXReader.dimensionUnits[unit],
            let value = Double(raw.dropLast(2).trimmingCharacters(in: .whitespaces)), value.isFinite
        else { return nil }
        let mm = value * ratio.numerator / ratio.denominator * 25.4 / 72.27
        return abs(mm) < 100_000 ? mm : nil
    }

    static let floatRegisters: Set<String> = [
        "intextsep", "textfloatsep", "floatsep", "abovecaptionskip", "belowcaptionskip",
    ]

    mutating func readLength(_ name: String, _ value: String, pointSize: Int = 10) {
        switch name {
        case _ where Self.floatRegisters.contains(name):
            let natural = value.components(separatedBy: "plus")[0].components(separatedBy: "minus")[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let length = LaTeXSymbols.printLength(natural) ?? Self.paragraphLength(natural) {
                variables[name] = length
            }
        case "LTpre", "LTpost":
            if let length = Self.paragraphLength(value) { variables[name.lowercased()] = length }
        case "LTleft", "LTright":
            if value == "\\fill" || value.contains("fil") {
                variables[name.lowercased()] = "auto"
            } else if let length = LaTeXSymbols.printLength(value) {
                variables[name.lowercased()] = length
            }
        case "tabcolsep", "arrayrulewidth": if let length = LaTeXSymbols.printLength(value) { variables[name] = length }
        case "extrarowheight": extraRowHeight = LaTeXSymbols.printLength(value)
        case "columnsep", "columnseprule":
            let fontScale = value.hasSuffix("em") ? 1.0 : value.hasSuffix("ex") ? 0.43 : nil
            let relative = fontScale.flatMap { scale in Double(value.dropLast(2)).map { $0 * Double(pointSize) * scale }
            }
            if let length = Self.texPoints(value) ?? relative, length.isFinite, (0..<100_000).contains(length) {
                if name == "columnsep" { columnGap = length } else { columnRule = length }
            }
        case "textwidth", "textheight":
            if let length = Self.texPoints(value), length > 0 { assigned[name] = length }
        case "oddsidemargin", "topmargin", "headheight", "headsep", "footskip":
            if let length = Self.texPoints(value) { assigned[name] = length }
        case "paperwidth":
            if let length = Self.millimetres(value), length > 0 { paperWidth = length }
        case "paperheight":
            if let length = Self.millimetres(value), length > 0 { paperHeight = length }
        case "parskip", "parindent", "itemsep", "topsep":
            if let length = Self.paragraphLength(value) { variables[name == "topsep" ? "list-topsep" : name] = length }
        default: break
        }
    }

    private static func paragraphLength(_ value: String) -> String? {
        let base = value.components(separatedBy: "plus")[0].components(separatedBy: "minus")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("\\baselineskip") {
            let number = base.dropLast("\\baselineskip".count)
            if let factor = number.isEmpty ? 1 : Double(number), factor.isFinite, abs(factor) <= 100 {
                return Self.number(factor) + "lh"
            }
        }
        return LaTeXSymbols.printLength(base)
    }

    var stretch: String { variables["stretch"] ?? "1" }

    mutating func setStretch(_ raw: String) {
        if let value = Double(raw), value.isFinite, value > 0, value <= 100 {
            variables["stretch"] = Self.number(value)
        }
    }

    mutating func lineSpacing(_ command: String, pointSize: Int) {
        // setspace.sty compensates for the three standard classes' different baseline-to-type-size ratios.
        switch command {
        case "onehalfspacing": setStretch(pointSize == 11 ? "1.213" : pointSize == 12 ? "1.241" : "1.25")
        case "doublespacing": setStretch(pointSize == 11 ? "1.618" : pointSize == 12 ? "1.655" : "1.667")
        case "singlespacing": setStretch("1")
        default: break
        }
    }

    mutating func readPackage(_ name: String, options: String, info: LaTeXDocumentClassInfo) {
        switch name {
        case "caption": captions.configure(options, kind: "")
        case "luatexja-preset": fonts.applyJapanesePreset(options, scale: LaTeXLabelMetrics(info).japaneseScale)
        case "geometry": readOptions(options, geometry: true)
        case "fullpage":
            let margin = options.contains("cm") ? 15.0 : 25.4
            readOptions("margin=\(margin)mm", geometry: true)
        case "a4wide":
            let inches = info.pointSize == 10 ? 5.875 : info.pointSize == 11 ? 6.125 : 6.375
            assigned["textwidth"] = inches * 72.27
        case "parskip":
            variables["parindent"] = "0pt"
            variables["parskip"] = "0.5lh"
            for (key, value) in Self.options(options) {
                if key == "skip" { readLength("parskip", value) }
                if key == "indent" { readLength("parindent", value) }
            }
        case "setspace":
            variables["float-stretch"] = "1"
            for option in Self.options(options) { lineSpacing(option.key, pointSize: info.spacingPointSize) }
        default: fonts.readPackage(name)
        }
    }

    mutating func configureList(_ kind: String, options: String) {
        let parts = kind.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count <= 2,
            parts.allSatisfy({ ["itemize", "description", "enumerate"].contains($0) || (1...6).contains(Int($0) ?? 0) })
        else { return }
        let key = parts.joined(separator: ",")
        Self.applyListOptions(options, to: &listSettings[key, default: [:]])
    }

    func listOptions(_ kind: String, depth: Int, kindDepth: Int, options: String?) -> [String: String] {
        var values: [String: String] = [:]
        // enumitem applies generic, nesting-level and environment settings in that order.
        for key in ["", String(depth), kind, "\(kind),\(kindDepth)"] {
            if let settings = listSettings[key] { values.merge(settings) { _, local in local } }
        }
        if let options { Self.applyListOptions(options, to: &values) }
        return values
    }

    private static func applyListOptions(_ options: String, to values: inout [String: String]) {
        for (key, value) in Self.options(options) {
            switch key {
            case "style": values["style"] = value
            case "nosep":
                values["list-parsep"] = "0pt"
                values["itemsep"] = "0pt"
                values["list-topsep"] = "0pt"
            case "itemsep": if let length = paragraphLength(value) { values["itemsep"] = length }
            case "labelwidth", "labelsep", "parsep", "topsep":
                if let length = paragraphLength(value) {
                    values["list-" + key] = length
                }
            case "leftmargin": if let length = LaTeXSymbols.printLength(value) { values["list-margin"] = length }
            default: break
            }
        }
    }
}

extension LaTeXReader {
    /// Consume only the literal assignment and its optional glue, retaining prose and subsequent commands on this line.
    private func assignment(_ pattern: String) -> String {
        let limit = min(index + 192, characters.count)
        let source = String(characters[index..<limit])
        guard let range = source.range(of: pattern, options: [.regularExpression, .anchored]) else { return "" }
        let match = source[range]
        index += match.count
        return String(match).trimmingCharacters(in: CharacterSet(charactersIn: " =\t"))
    }

    func readPageSetting(_ name: String) -> Bool {
        func assignLength(_ name: String, _ value: String) {
            if document.classInfo.profile.body.readsQuestions, let length = LaTeXSymbols.printLength(value) {
                switch name {
                case "linefillheight":
                    document.exam.linePitch = length
                    return
                case "dottedlinefillheight":
                    document.exam.dottedPitch = length
                    return
                case "linefillthickness":
                    document.exam.lineThickness = length
                    return
                default: break
                }
            }
            // These skips are measured once for each loaded document. A later declaration
            // must never change the space surrounding floats on pages already read.
            if !inPreamble && LaTeXPageSettings.floatRegisters.contains(name) {
                document.recordUnknown(name)
            } else {
                var natural = value
                if name == "parskip", let scale = document.classInfo.jsMagnification,
                    let match = value.wholeMatch(
                        of: /\s*([+-]?[\d.]+)?\s*(em|ex|\\baselineskip)(?:\s+(?:plus|minus).*)?\s*/),
                    let factor = Double(match.1.map(String.init) ?? "1"), factor.isFinite
                {
                    // TeX stores the dimension at assignment, before a chapter switches to Huge.
                    let metrics = LaTeXLabelMetrics(document.classInfo)
                    let unit: Double
                    switch match.2 {
                    case "em": unit = 10 * scale
                    case "ex": unit = 4.30554 * scale
                    default:
                        unit = metrics.baselines[4] * (inPreamble ? 1 : Double(document.pageSettings.stretch) ?? 1)
                    }
                    natural = LaTeXPageSettings.number(factor * unit) + "pt"
                }
                document.pageSettings.readLength(name, natural, pointSize: document.classInfo.pointSize)
            }
        }
        let previousGap = document.pageSettings.columnGap
        let previousRule = document.pageSettings.columnRule
        defer {
            if !inPreamble
                && (previousGap != document.pageSettings.columnGap || previousRule != document.pageSettings.columnRule)
            {
                appendBlock("<template data-latex-spacing \(document.columnSpacing)></template>\n")
            }
        }
        switch name {
        case "geometry": document.pageSettings.readOptions(argument() ?? "", geometry: true)
        case "setlength":
            let register = argument() ?? ""
            let value = evaluatedLength(argument() ?? "")
            if register.hasPrefix("\\") {
                assignLength(String(register.dropFirst()), value)
            }
        case "linefillheight" where document.classInfo.profile.body.readsQuestions,
            "dottedlinefillheight" where document.classInfo.profile.body.readsQuestions,
            "linefillthickness" where document.classInfo.profile.body.readsQuestions,
            "intextsep", "textfloatsep", "floatsep", "abovecaptionskip", "belowcaptionskip", "extrarowheight",
            "columnsep", "columnseprule", "parindent", "parskip", "itemsep", "topsep", "textwidth", "oddsidemargin",
            "evensidemargin", "arrayrulewidth", "tabcolsep", "LTpre", "LTpost", "LTleft", "LTright",
            "topmargin", "textheight",
            "headheight", "headsep", "footskip", "paperwidth", "paperheight", "XeTeXlinebreakskip", "emergencystretch":
            let unit = #"(?:pt|pc|bp|mm|cm|in|em|ex|fil{1,3}|\\baselineskip)"#
            let dimension = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)?[ \t]*"# + unit
            let value = assignment(
                #"[ \t]*=?[ \t]*"# + dimension + #"(?:[ \t]+(?:plus|minus)[ \t]*"# + dimension + ")*")
            assignLength(name, value)
        case "hyphenpenalty", "widowpenalty", "clubpenalty":
            _ = assignment(#"[ \t]*=?[ \t]*[+-]?\d+"#)
        case "XeTeXlinebreaklocale":
            let raw = assignment(#"[ \t]*=?[ \t]*"[^"\n]*""#)
            let locale = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if let language = LaTeXLanguage.tag(locale) {
                let traditional =
                    locale == "zh"
                    && (document.classInfo.mainLanguage == "zh-Hant"
                        || document.pageSettings.fonts.roleVariables["main-font"]?.contains(" TC\"") == true)
                document.classInfo.mainLanguage = traditional ? "zh-Hant" : language
            }
        case "newcolumntype":
            let name = argument() ?? ""
            let parameters = optional()
            let specification = argument() ?? ""
            if let type = name.first, name.count == 1, parameters == nil || parameters == "0",
                specification.utf8.count <= 4096
            {
                document.pageSettings.columnTypes[type] = specification
            }
        case "setlist":
            let kind = optional() ?? ""
            document.pageSettings.configureList(kind, options: argument() ?? "")
        case "captionsetup":
            let kind = optional() ?? ""
            document.pageSettings.captions.configure(argument() ?? "", kind: kind)
        case "tcbset":
            document.pageSettings.boxDefaults.apply(argument() ?? "")
        case "linespread", "setstretch": document.pageSettings.setStretch(argument() ?? "")
        case "onehalfspacing", "doublespacing", "singlespacing":
            document.pageSettings.lineSpacing(name, pointSize: document.classInfo.spacingPointSize)
        case "raggedbottom", "flushbottom", "sloppy", "makeatletter", "makeatother": break
        default: return false
        }
        return true
    }
}

extension LaTeXDocument {
    var columnSpacing: String {
        let gap =
            (pageSettings.columnGap ?? classInfo.publication?.columnGap(size: classInfo.pointSize)).map {
                "data-latex-gap=\"\(LaTeXPageSettings.number($0))\" "
            } ?? ""
        return gap + "data-latex-rule=\"\(LaTeXPageSettings.number(pageSettings.columnRule))\""
    }

    func columnAttributes(_ columns: Int) -> String {
        "data-latex-columns=\"\(columns)\" \(columnSpacing)"
    }

    func columnMarker(_ columns: Int) -> String {
        "<template \(columnAttributes(columns))></template>\n"
    }
}

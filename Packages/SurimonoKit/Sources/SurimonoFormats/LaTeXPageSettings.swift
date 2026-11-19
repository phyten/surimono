import Foundation

/// The document's intended measure is independent of the stock and printable area chosen in Surimono.
struct LaTeXPageSettings {
    // A missing paper option in the standard classes means US Letter, independently of the app stock.
    private var stock = (width: 215.9, height: 279.4)
    private var landscape = false
    private var usesGeometry = false
    private var left: Double?
    private var right: Double?
    private var assignedWidth: Double?
    private var width: Double?
    private var scale = 0.7
    private var variables: [String: String] = [:]
    var fonts = LaTeXFontSettings()
    var columnTypes: [Character: String] = [:]
    var listSettings: [String: [String: String]] = [:]

    var styleVariables: String {
        var values = variables.merging(fonts.roleVariables) { _, font in font }
        let paper = landscape ? stock.height : stock.width
        let geometryWidth: Double?
        if !usesGeometry {
            geometryWidth = nil
        } else if let left, let right {
            // Geometry gives a fully specified margin pair priority over its body width.
            geometryWidth = paper - left - right
        } else if let width {
            geometryWidth = width
        } else if let margin = left ?? right, scale == 0.7 {
            // The unspecified side retains half the margin left by geometry's default 0.7 body.
            geometryWidth = paper * 0.85 - margin
        } else {
            geometryWidth = paper * scale
        }
        let measure = assignedWidth ?? geometryWidth
        if let measure, measure.isFinite, measure > 0 {
            values["text-width"] = Self.number(measure) + "mm"
            values["text-width-tex-pt"] = Self.number(measure * 72.27 / 25.4)
        }
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

    mutating func readOptions(_ raw: String, geometry: Bool) {
        if geometry {
            usesGeometry = true
            assignedWidth = nil
        }
        for (key, value) in Self.options(raw) {
            if let size = Self.paperSizes[key] {
                stock = size
                continue
            }
            switch key {
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
        let first = pair.first.flatMap(Self.millimetres)
        switch key {
        case "margin":
            // geometry's margin={h,v} is one horizontal margin for both sides.
            if let first {
                left = first
                right = first
            }
        case "hmargin":
            if let first {
                left = first
                right = pair.count == 2 ? Self.millimetres(pair[1]) : first
            }
        case "left", "inner", "lmargin", "innermargin": if let first { left = first }
        case "right", "outer", "rmargin", "outermargin": if let first { right = first }
        case "textwidth", "width", "total", "body":
            if let first, first > 0 { width = first }
        case "scale", "hscale":
            if let raw = pair.first, let factor = Double(raw), factor.isFinite, factor > 0, factor <= 1 {
                scale = factor
            }
        case "paper", "papername":
            if let size = Self.paperSizes[value] { stock = size }
        default: break
        }
    }

    static func millimetres(_ source: String) -> Double? {
        let raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count < 64, raw.count > 2,
            let factor = [
                "mm": 1, "cm": 10, "in": 25.4, "pt": 25.4 / 72.27,
                "pc": 12 * 25.4 / 72.27, "bp": 25.4 / 72,
            ][String(raw.suffix(2))],
            let value = Double(raw.dropLast(2).trimmingCharacters(in: .whitespaces)), value.isFinite,
            abs(value * factor) < 100_000
        else { return nil }
        return value * factor
    }

    mutating func readLength(_ name: String, _ value: String) {
        switch name {
        case "textwidth":
            if let length = Self.millimetres(value), length > 0 { assignedWidth = length }
        case "parskip", "parindent":
            if let length = Self.paragraphLength(value) { variables[name] = length }
        default:
            // Side and top offsets position an existing text block in TeX; they do not change its width.
            break
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
        return LaTeXSymbols.cssLength(base)
    }

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

    mutating func readPackage(_ name: String, options: String, pointSize: Int) {
        switch name {
        case "geometry": readOptions(options, geometry: true)
        case "fullpage":
            let margin = options.contains("cm") ? 15.0 : 25.4
            readOptions("margin=\(margin)mm", geometry: true)
        case "a4wide":
            let inches = pointSize == 10 ? 5.875 : pointSize == 11 ? 6.125 : 6.375
            assignedWidth = inches * 25.4
        case "parskip":
            variables["parindent"] = "0pt"
            variables["parskip"] = "0.5lh"
            for (key, value) in Self.options(options) {
                if key == "skip" { readLength("parskip", value) }
                if key == "indent" { readLength("parindent", value) }
            }
        case "setspace":
            for option in Self.options(options) { lineSpacing(option.key, pointSize: pointSize) }
        default: fonts.readPackage(name)
        }
    }

    mutating func configureList(_ kind: String, options: String) {
        guard ["", "itemize", "description", "enumerate"].contains(kind) else { return }
        var values = listSettings[kind] ?? [:]
        Self.applyListOptions(options, to: &values)
        listSettings[kind] = values
    }

    func listAttribute(_ kind: String, options: String?) -> String {
        var values = (listSettings[""] ?? [:]).merging(listSettings[kind] ?? [:]) { _, local in local }
        if let options { Self.applyListOptions(options, to: &values) }
        return values.isEmpty ? "" : " style=\"\(HTML.escape(Self.cssVariables(values)))\""
    }

    private static func applyListOptions(_ options: String, to values: inout [String: String]) {
        for (key, value) in Self.options(options) {
            switch key {
            case "nosep":
                values["itemsep"] = "0pt"
                values["list-topsep"] = "0pt"
            case "itemsep": if let length = paragraphLength(value) { values["itemsep"] = length }
            case "leftmargin": if let length = LaTeXSymbols.cssLength(value) { values["list-margin"] = length }
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
        switch name {
        case "geometry": document.pageSettings.readOptions(argument() ?? "", geometry: true)
        case "setlength":
            let register = argument() ?? ""
            let value = evaluatedLength(argument() ?? "")
            if register.hasPrefix("\\") { document.pageSettings.readLength(String(register.dropFirst()), value) }
        case "parindent", "parskip", "textwidth", "oddsidemargin", "evensidemargin", "topmargin", "textheight",
            "XeTeXlinebreakskip", "emergencystretch":
            let unit = #"(?:pt|pc|bp|mm|cm|in|em|ex|fil{1,3}|\\baselineskip)"#
            let dimension = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)?[ \t]*"# + unit
            let value = assignment(
                #"[ \t]*=?[ \t]*"# + dimension + #"(?:[ \t]+(?:plus|minus)[ \t]*"# + dimension + ")*")
            document.pageSettings.readLength(name, value)
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
        case "tcbset": _ = argument()
        case "linespread", "setstretch": document.pageSettings.setStretch(argument() ?? "")
        case "onehalfspacing", "doublespacing", "singlespacing":
            document.pageSettings.lineSpacing(name, pointSize: document.classInfo.pointSize)
        case "raggedbottom", "flushbottom", "sloppy", "makeatletter", "makeatother": break
        default: return false
        }
        return true
    }
}

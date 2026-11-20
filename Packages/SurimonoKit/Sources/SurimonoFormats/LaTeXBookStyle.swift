import Foundation

/// A KOMA element is a sequence of NFSS declarations, applied after its parent element.
package struct LaTeXElementFont: Codable, Equatable, Sendable {
    package var family: String?
    package var weight: String?
    package var shape: String?
    package var capitals: String?
    package var sizeName: String?
    var sizeInPoints: Double?

    mutating func apply(_ commands: String) {
        for word in commands.split(whereSeparator: { !$0.isLetter }) {
            switch word {
            case "normalfont":
                family = "roman"
                weight = "normal"
                shape = "normal"
                capitals = "normal"
            case "sffamily": family = "sans"
            case "rmfamily": family = "roman"
            case "ttfamily": family = "mono"
            case "bfseries": weight = "bold"
            case "mdseries": weight = "normal"
            case "itshape", "slshape":
                shape = "italic"
                capitals = "normal"
            case "upshape":
                shape = "normal"
                capitals = "normal"
            case "scshape":
                shape = "normal"
                capitals = "small-caps"
            case "tiny", "scriptsize", "footnotesize", "small", "normalsize", "large", "Large", "LARGE", "huge", "Huge":
                sizeName = String(word)
            default: break
            }
        }
    }

    package func pointSize(base: Int) -> Double? {
        if let sizeInPoints { return sizeInPoints }
        guard let sizeName,
            let index = [
                "tiny", "scriptsize", "footnotesize", "small", "normalsize", "large", "Large", "LARGE", "huge", "Huge",
            ]
            .firstIndex(of: sizeName)
        else { return nil }
        let sizes: [[Double]] = [
            [5, 7, 8, 9, 10, 12, 14.4, 17.28, 20.74, 24.88],
            [6, 8, 9, 10, 10.95, 12, 14.4, 17.28, 20.74, 24.88],
            [6, 8, 10, 10.95, 12, 14.4, 17.28, 20.74, 24.88, 24.88],
        ]
        return sizes[base - 10][index]
    }

    func variables(element: String, size: Int) -> [String: String] {
        let families = [
            "roman": "var(--tex-body-fonts)", "sans": "var(--tex-sans-fonts)",
            "mono": "var(--latex-mono-font, \"Surimono Computer Modern Typewriter\"), monospace",
        ]
        let values = [
            "family": family.flatMap { families[$0] }, "weight": weight, "style": shape, "variant": capitals,
            "size": pointSize(base: size).map { "calc(\(LaTeXPageSettings.number($0)) * var(--tex-pt))" },
        ]
        return Dictionary(
            uniqueKeysWithValues: values.compactMap { key, value in value.map { ("koma-" + element + "-" + key, $0) } })
    }
}

struct LaTeXBookStyle: Equatable, Sendable {
    // Use the bundled Computer Modern sans faces only in KOMA documents. Their widths set the
    // gap between the chapter numeral and title and the number of words that fit on a heading line.
    static let sansFaces = [("normal", "normal"), ("bold", "normal"), ("normal", "italic")].compactMap {
        weight, style -> String? in
        guard let data = MathRenderer.fontData(family: "KaTeX_SansSerif", weight: weight, style: style) else {
            return nil
        }
        return
            "@font-face{font-family:'Surimono KOMA Sans';font-weight:\(weight);font-style:\(style);src:url(data:font/ttf;base64,\(data.base64EncodedString())) format('truetype')}"
    }.joined(separator: "\n")

    var division: String?
    var binding = 0.0
    var includeHead = false
    var includeFoot = false
    var chapterStyle = "default"
    var fonts: [String: LaTeXElementFont] = [:]
    var preambleFonts: [String: LaTeXElementFont]?

    var initialFonts: [String: LaTeXElementFont] { preambleFonts ?? fonts }

    mutating func readOptions(_ options: [String]) {
        for (key, value) in LaTeXPageSettings.options(options.joined(separator: ",")) {
            switch key {
            case "DIV": division = value
            case "BCOR": binding = (LaTeXPageSettings.millimetres(value) ?? 0) * 72.27 / 25.4
            case "headinclude": includeHead = value != "false"
            case "footinclude": includeFoot = value != "false"
            default: break
            }
        }
    }

    func resolvedDivision(size: Int, columns: Int, paper: Double, stock: Double, head: Double, foot: Double) -> Double {
        let mm = 72.27 / 25.4
        if let division, let n = Int(division), n >= 4 { return Double(n) }
        let a4 = (207...213).contains(paper / mm) && (294...300).contains(stock / mm)
        if division != "calc", division != "classic", a4 { return [8, 10, 12][size - 10] }
        let excludedHead = includeHead ? 0 : head
        let excludedFoot = includeFoot ? 0 : foot
        if division == "classic", paper - binding + excludedHead + excludedFoot <= stock, stock > paper - binding {
            return max(4, floor(3 * stock / (stock - paper + binding)))
        }
        // For DIV=calc, typearea measures the lower- and upper-case alphabets of the class's body face
        // before packages load. These are its natural widths after weighting for a 66-character line.
        let single = [345.34871, 378.15645, 405.68922][size - 10]
        let target = columns == 2 ? 2 * single + 10 : single
        let block = paper > target ? (paper - target) / 3 : 5 * mm
        let div = max(4, floor(paper / block))
        if stock / div - excludedHead < 5 * mm {
            return max(4, floor(3 * stock / (15 * mm + excludedHead + excludedFoot)))
        }
        return div
    }

    mutating func setFont(_ element: String, commands: String, append: Bool) {
        let defaults = [
            "disposition": #"\normalfont\sffamily\bfseries"#, "chapter": #"\huge"#, "section": #"\Large"#,
            "caption": "", "captionlabel": "", "pagehead": #"\normalfont\slshape"#, "pagenumber": #"\normalfont"#,
        ]
        guard let initial = defaults[element] else { return }
        var font = LaTeXElementFont()
        if append {
            if let previous = fonts[element] { font = previous } else { font.apply(initial) }
        } else if element == "chapter" || element == "section" {
            // Replacing the size declaration leaves the current body size in force.
            font.sizeName = "normalsize"
        } else if element == "disposition" {
            font.apply("normalfont")
        }
        font.apply(commands)
        fonts[element] = font
    }

    func variables(size: Int) -> [String: String] {
        initialFonts.reduce(into: [:]) { result, pair in
            result.merge(pair.value.variables(element: pair.key, size: size)) { _, latest in latest }
        }
    }

    func fontAttribute(elements: [String], size: Int) -> String {
        guard let preambleFonts else { return "" }
        var changed: [String: String] = [:]
        for element in elements where fonts[element] != preambleFonts[element] {
            let current = fonts[element]?.variables(element: element, size: size) ?? [:]
            let initial = preambleFonts[element]?.variables(element: element, size: size) ?? [:]
            for key in Set(current.keys).union(initial.keys) where current[key] != initial[key] {
                changed[key] = current[key] ?? "initial"
            }
        }
        return changed.isEmpty ? "" : " style=\"\(HTML.escape(LaTeXPageSettings.cssVariables(changed)))\""
    }
}

extension LaTeXDocumentClassInfo {
    package var pageHeadFont: LaTeXElementFont? { bookStyle.initialFonts["pagehead"] }
    package var pageNumberFont: LaTeXElementFont? { bookStyle.initialFonts["pagenumber"] }
}

extension LaTeXClassBox {
    static func typeAreaBox(_ info: LaTeXDocumentClassInfo, width paper: Double, height stock: Double, twoSided: Bool)
        -> Self
    {
        let size = info.pointSize
        let baseline = [12.0, 13.6, 14.5][size - 10]
        let options = info.bookStyle
        let binding = min(paper / 2, max(0, options.binding))
        let headHeight = 1.25 * baseline
        let headSep = 1.5 * baseline
        let footSkip = 3.5 * baseline
        let div = options.resolvedDivision(
            size: size, columns: info.columns, paper: paper, stock: stock,
            head: headHeight + headSep, foot: footSkip)
        let h = (paper - binding) / div
        let v = stock / div
        let head = options.includeHead ? headHeight + headSep : 0
        let available = stock - 3 * v - head - (options.includeFoot ? footSkip : 0)
        // typearea rounds upward to an integral number of baselines below topskip.
        let height = Double(size) + ceil((available - Double(size)) / baseline) * baseline
        return Self(
            width: paper - binding - 3 * h, height: height, left: binding + h * (twoSided ? 1 : 1.5),
            top: v + head, headHeight: headHeight, headSep: headSep, footSkip: footSkip)
    }

    static func ruledBookBox(_ info: LaTeXDocumentClassInfo, width paper: Double, height stock: Double, twoSided: Bool)
        -> Self
    {
        let size = info.pointSize
        let baseline = [12.0, 13.6, 14.5][size - 10]
        let inch = 72.27
        let width = floor(min(paper - 2 * inch, [341.0, 369.0, 383.0][size - 10] * Double(info.columns)))
        let height = floor((stock - 3.5 * inch) / baseline) * baseline + Double(size)
        let headSep = (size == 10 ? 0.25 : 0.275) * inch
        let footSkip = size == 12 ? 30 : (size == 10 ? 0.35 : 0.38) * inch
        let topMargin = ((stock - 2 * inch - baseline - headSep - height - footSkip) / 2).rounded(.towardZero)
        let side = ((paper - width) * (twoSided ? 0.4 : 0.5) - inch).rounded(.towardZero)
        return Self(
            width: width, height: height, left: inch + side, top: inch + topMargin + baseline + headSep,
            headHeight: baseline, headSep: headSep, footSkip: footSkip)
    }
}

extension LaTeXReader {
    func readBookClassSetting(_ name: String) -> Bool {
        if name == "chapterstyle", document.classInfo.profile.headings.readsChapterStyle {
            let style = argument() ?? ""
            document.classInfo.bookStyle.chapterStyle =
                ["hangnum", "section", "article"].contains(style) ? style : "default"
            return true
        }
        if ["setkomafont", "addtokomafont"].contains(name), document.classInfo.profile.headings.readsElementFonts {
            let element = argument() ?? ""
            let declaration = argument() ?? ""
            if !inPreamble, document.classInfo.bookStyle.preambleFonts == nil {
                document.classInfo.bookStyle.preambleFonts = document.classInfo.bookStyle.fonts
            }
            document.classInfo.bookStyle.setFont(element, commands: declaration, append: name == "addtokomafont")
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if element == "pagenumber" || element == "pagehead", let font = document.classInfo.bookStyle.fonts[element],
                let data = try? encoder.encode(font)
            {
                pageAction("koma:" + element, String(decoding: data, as: UTF8.self))
            }
            return true
        }
        return false
    }

    func bookHeadingAttributes(_ name: String) -> String {
        let info = document.classInfo
        if info.profile.headings.readsElementFonts {
            return " data-latex-koma-heading=\"\(name)\""
                + info.bookStyle.fontAttribute(elements: ["disposition", name], size: info.pointSize)
        }
        if name == "chapter", info.profile.headings.readsChapterStyle {
            return " data-latex-memoir-style=\"\(info.bookStyle.chapterStyle)\""
        }
        return ""
    }
}

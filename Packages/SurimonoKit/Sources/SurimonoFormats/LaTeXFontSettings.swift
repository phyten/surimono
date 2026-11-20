import Foundation

/// A fontspec family is only a request for installed faces. local() lets WebKit test membership
/// and continue down the theme stack without loading a document's font files.
struct LaTeXFontSettings {
    struct Selection: Hashable {
        let name: String
        let bold: String?
        let explicitBold: String?
        let italic: String?
        let scale: Double?
        let cjk: Bool
        let ideographFallback: String?
        private let knownPostScriptNames: Bool

        init?(
            _ name: String, options: String, cjk: Bool, mono: Bool = false, defaultScale: Double? = nil,
            knownPostScriptNames: Bool = false, index: InstalledFontIndex
        ) {
            let family = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.validName(family) else { return nil }
            let settings = Dictionary(LaTeXPageSettings.options(options).map { ($0.key, $0.value) }) { _, last in last }
            func face(_ key: String) -> String? {
                settings[key].flatMap { raw in
                    let value = raw.replacingOccurrences(of: "*", with: family)
                    return Self.validName(value) ? value : nil
                }
            }
            self.knownPostScriptNames = knownPostScriptNames
            self.name = family
            let namedBold = face("BoldFont")
            explicitBold = namedBold
            let namedItalic = face("ItalicFont")
            scale =
                settings["Scale"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 && $0 <= 10 ? $0 : nil }
                ?? defaultScale
            // A scaled or partly overridden family is exposed through a CSS alias. Name its other
            // installed variants too, since the browser cannot discover sibling faces of an alias.
            let alias = mono && (namedBold != nil || namedItalic != nil || scale != nil)
            let native = !knownPostScriptNames && (alias || cjk) ? index.face(named: family) : nil
            bold = namedBold ?? native?.bold
            italic = namedItalic ?? native?.italic
            ideographFallback =
                knownPostScriptNames ? nil : Self.fallback(for: family, bold: bold, italic: italic, in: index)
            self.cjk = cjk
        }

        // Fontspec also accepts filenames, paths, arbitrary TeX and load options. Only an installed
        // family or face name belongs in a local CSS source. This excludes CSS and HTML delimiters.
        private static func validName(_ name: String) -> Bool {
            !name.isEmpty && name.utf8.count <= 160
                && name.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) || " -._+'()".unicodeScalars.contains($0)
                }
        }

        // A glyph-only Quartz PDF loses which Unicode scalar selected a shared glyph.
        // Check installed faces, including explicit bold and italic variants; a family-name list
        // alone misses aliases, user fonts, and changes to the system fonts after an OS update.
        private static func fallback(for name: String, bold: String?, italic: String?, in index: InstalledFontIndex)
            -> String?
        {
            // The families macOS ships are decided by name, so the same document converts the same way
            // on a Mac that has not downloaded them. Only other faces are probed.
            let requested = name.lowercased()
            if let known = Self.knownFallbacks.first(where: { requested.hasPrefix($0.prefix) }) { return known.alias }
            for face in [name, bold, italic].compactMap({ $0 }) {
                guard let font = index.face(named: face), font.sharesIdeographs else { continue }
                let family = font.family.lowercased()
                if family.contains("song") || family.contains("宋") {
                    return family.contains("tc") || face.lowercased().contains("tc") ? "Song TC" : "Song SC"
                }
                if ["pingfang", "gothic", "sans", "黑", "ゴシック"].contains(where: family.contains) { return "Hei" }
                return "Mincho"
            }
            return nil
        }

        private static let knownFallbacks: [(prefix: String, alias: String)] = [
            ("yumincho", "Mincho"), ("yu mincho", "Mincho"), ("游明朝", "Mincho"),
            ("songti tc", "Song TC"), ("songti sc", "Song SC"), ("stsong", "Song SC"),
        ]

        var needsAlias: Bool { cjk || bold != nil || italic != nil || scale != nil }

        func faceCSS(alias: String, japaneseBold: String? = nil, index: InstalledFontIndex) -> String {
            // Restrict a CJK role to the scripts and punctuation it supplies. Many CJK families have
            // Latin glyphs too; they must not swallow the role explicitly selected by setmainfont.
            let coverage =
                cjk
                ? " unicode-range: U+1100-11FF,U+2E80-2FFF,U+3000-31FF,U+3200-9FFF,U+A960-A97F,U+AC00-D7FF,U+F900-FAFF,U+FE10-FE1F,U+FE30-FE4F,U+FF00-FFEF,U+20000-323AF;"
                : ""
            let adjust = scale.map { " size-adjust: \(LaTeXPageSettings.number($0 * 100))%;" } ?? ""
            func rule(_ face: String, _ variant: String = "", fallback: String? = nil) -> String {
                // local() identifies an individual installed face; a collection's family name
                // need not be its full or PostScript name. Discard Core Text substitutions.
                var sources = ["local(\"\(face)\")"]
                if cjk && !knownPostScriptNames, let ps = index.face(named: face)?.postScriptName,
                    ps != face, Self.validName(ps)
                {
                    sources.insert("local(\"\(ps)\")", at: 0)
                }
                if let fallback, fallback != face { sources.append("local(\"\(fallback)\")") }
                return
                    "@font-face { font-family: \"\(alias)\"; src: \(sources.joined(separator: ", "));\(variant)\(adjust)\(coverage) }"
            }
            return [
                rule(name, fallback: japaneseBold == nil ? nil : "HiraMinProN-W3"),
                (explicitBold ?? japaneseBold ?? bold).map {
                    rule($0, " font-weight: bold;", fallback: japaneseBold == nil ? nil : "HiraKakuProN-W6")
                },
                italic.map { rule($0, " font-style: italic;") },
            ]
            .compactMap { $0 }.joined(separator: "\n")
        }
    }

    let index: InstalledFontIndex

    init(index: InstalledFontIndex) { self.index = index }

    private(set) var mainFontName: String?
    var japaneseMainFontName: String? { japaneseMain?.name }
    private(set) var japaneseMain: Selection?
    private(set) var japaneseSans: Selection?
    var roleVariables: [String: String] = [:]
    var selectors: [String: String] = [:]
    private var aliases: [Selection: Int] = [:]
    private(set) var faceRules: [String] = []

    mutating func family(_ selection: Selection) -> String {
        let quoted = "\"\(selection.name)\""
        let prefix = selection.ideographFallback.map { "\"Surimono \($0) Ideographs\", " } ?? ""
        guard selection.needsAlias else { return prefix + quoted }
        let id: Int
        if let existing = aliases[selection] {
            id = existing
        } else {
            guard aliases.count < 256 else { return quoted }
            id = aliases.count + 1
            aliases[selection] = id
            faceRules.append(selection.faceCSS(alias: "Surimono TeX Local \(id)", index: index))
        }
        let alias = "\"Surimono TeX Local \(id)\""
        return prefix + (selection.cjk ? alias : "\(alias), \(quoted)")
    }

    mutating func setRole(_ role: String, selection: Selection) {
        if role == "main" { mainFontName = selection.name }
        if role == "cjk-main" { japaneseMain = selection }
        if role == "cjk-sans" { japaneseSans = selection }
        let value = family(selection)
        roleVariables["\(role)-font"] = value
    }

    mutating func applyJapanesePreset(_ options: String, scale: Double?) {
        for option in LaTeXPageSettings.options(options) {
            let faces: (String, String)
            switch option.key {
            case "noto", "noto-otf", "noto-otc": faces = ("Noto Serif CJK JP", "Noto Sans CJK JP")
            case "noto-jp": faces = ("Noto Serif JP", "Noto Sans JP")
            case "hiragino-pron": faces = ("HiraMinProN-W3", "HiraKakuProN-W3")
            case "hiragino-pro": faces = ("HiraMinPro-W3", "HiraKakuPro-W3")
            case "ipaex": faces = ("IPAexMincho", "IPAexGothic")
            case "yu-osx": faces = ("YuMincho Medium", "YuGothic Medium")
            case "haranoaji": faces = ("HaranoAjiMincho-Regular", "HaranoAjiGothic-Medium")
            case "morisawa-pro": faces = ("RyuminPro-Light", "GothicBBBPro-Medium")
            case "morisawa-pr6n": faces = ("RyuminPr6N-Light", "GothicBBBPr6N-Medium")
            default: continue
            }
            for (role, face) in [("cjk-main", faces.0), ("cjk-sans", faces.1)] {
                if let selection = Selection(face, options: "", cjk: true, defaultScale: scale, index: index) {
                    setRole(role, selection: selection)
                }
            }
        }
    }

    mutating func readPackage(_ name: String) {
        let role: String
        let family: String
        switch name {
        case "times", "mathptmx", "newtxtext": (role, family) = ("main", "Times New Roman")
        case "helvet": (role, family) = ("sans", "Helvetica Neue")
        case "palatino", "mathpazo", "newpxtext": (role, family) = ("main", "Palatino")
        case "courier": (role, family) = ("mono", "Courier New")
        case "libertine": (role, family) = ("main", "Linux Libertine O")
        case "lmodern", "cm-super":
            (role, family) = ("main", "Surimono Computer Modern")
            if name == "lmodern" {
                // lmtt's bold series comes from the separate Latin Modern Mono Light family.
                // The theme falls back to bundled cmtt when the local TeX faces are unavailable.
                if let mono = Selection(
                    "LMMono10-Regular", options: "BoldFont=LMMonoLt10-Bold,ItalicFont=LMMono10-Italic", cjk: false,
                    index: index)
                {
                    setRole("mono", selection: mono)
                }
            } else {
                roleVariables["mono-font"] = "\"Surimono Computer Modern Typewriter\""
            }
        default: return
        }
        if role == "main" { mainFontName = family }
        roleVariables["\(role)-font"] = "\"\(family)\""
    }
}

extension LaTeXReader {
    func readFont(role: String?, selector: String? = nil) {
        let before = optional()
        let name = argument() ?? ""
        let after = optional()
        let options = [before, after].compactMap { $0 }.joined(separator: ",")
        guard
            let selection = LaTeXFontSettings.Selection(
                name, options: options, cjk: role?.hasPrefix("cjk-") == true, mono: role == "mono",
                defaultScale: role?.hasPrefix("cjk-") == true
                    ? LaTeXLabelMetrics(document.classInfo).japaneseScale : nil,
                index: document.pageSettings.fonts.index)
        else { return }
        if let selector, selector.hasPrefix("\\"), selector.count > 1, document.reserveExpansion() {
            document.pageSettings.fonts.selectors[String(selector.dropFirst())] = document.pageSettings.fonts.family(
                selection)
        } else if let role {
            document.pageSettings.fonts.setRole(role, selection: selection)
        }
    }
}

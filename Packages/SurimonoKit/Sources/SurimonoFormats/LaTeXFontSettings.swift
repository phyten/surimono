import CoreText
import Foundation

/// A fontspec family is only a request for installed faces. local() lets WebKit test membership
/// and continue down the theme stack without loading a document's fonts or enumerating the Mac's fonts.
struct LaTeXFontSettings {
    struct Selection: Hashable {
        let name: String
        let bold: String?
        let italic: String?
        let scale: Double?
        let cjk: Bool

        init?(_ name: String, options: String, cjk: Bool) {
            let family = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.validName(family) else { return nil }
            let settings = Dictionary(LaTeXPageSettings.options(options).map { ($0.key, $0.value) }) { _, last in last }
            func face(_ key: String) -> String? {
                settings[key].flatMap { raw in
                    let value = raw.replacingOccurrences(of: "*", with: family)
                    return Self.validName(value) ? value : nil
                }
            }
            self.name = family
            bold = face("BoldFont")
            italic = face("ItalicFont")
            scale = settings["Scale"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 && $0 <= 10 ? $0 : nil }
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
        var ideographFallback: String? {
            for face in [name, bold, italic].compactMap({ $0 }) {
                var font = CTFontCreateWithName(face as CFString, 12, nil)
                // Core Text substitutes Helvetica for the Windows family spelling on macOS,
                // which would hide the glyph collision in its installed Japanese counterpart.
                if ["yu mincho", "游明朝"].contains(face.lowercased()),
                    CTFontCopyPostScriptName(font) as String == "Helvetica"
                {
                    font = CTFontCreateWithName("YuMincho" as CFString, 12, nil)
                }
                let variants = [CTFontSymbolicTraits.boldTrait, .italicTrait].compactMap { trait in
                    CTFontCreateCopyWithSymbolicTraits(font, 0, nil, trait, trait)
                }
                guard ([font] + variants).contains(where: LaTeXIdeographs.needsFallback) else { continue }
                let family = (CTFontCopyFamilyName(font) as String).lowercased()
                if family.contains("song") || family.contains("宋") {
                    return family.contains("tc") || face.lowercased().contains("tc") ? "Song TC" : "Song SC"
                }
                if ["pingfang", "gothic", "sans", "黑", "ゴシック"].contains(where: family.contains) { return "Hei" }
                return "Mincho"
            }
            return nil
        }

        var needsAlias: Bool { cjk || bold != nil || italic != nil || scale != nil }

        func faceCSS(alias: String) -> String {
            // Restrict a CJK role to the scripts and punctuation it supplies. Many CJK families have
            // Latin glyphs too; they must not swallow the role explicitly selected by setmainfont.
            let coverage =
                cjk
                ? " unicode-range: U+1100-11FF,U+2E80-2FFF,U+3000-31FF,U+3200-9FFF,U+A960-A97F,U+AC00-D7FF,U+F900-FAFF,U+FE10-FE1F,U+FE30-FE4F,U+FF00-FFEF,U+20000-323AF;"
                : ""
            let adjust = scale.map { " size-adjust: \(LaTeXPageSettings.number($0 * 100))%;" } ?? ""
            func rule(_ face: String, _ variant: String = "") -> String {
                "@font-face { font-family: \"\(alias)\"; src: local(\"\(face)\");\(variant)\(adjust)\(coverage) }"
            }
            return [
                rule(name), bold.map { rule($0, " font-weight: bold;") },
                italic.map { rule($0, " font-style: italic;") },
            ]
            .compactMap { $0 }.joined(separator: "\n")
        }
    }

    private(set) var mainFontName: String?
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
            faceRules.append(selection.faceCSS(alias: "Surimono TeX Local \(id)"))
        }
        let alias = "\"Surimono TeX Local \(id)\""
        return prefix + (selection.cjk ? alias : "\(alias), \(quoted)")
    }

    mutating func setRole(_ role: String, selection: Selection) {
        if role == "main" { mainFontName = selection.name }
        let value = family(selection)
        roleVariables["\(role)-font"] = value
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
            roleVariables["mono-font"] = "\"Surimono Computer Modern Typewriter\""
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
        guard let selection = LaTeXFontSettings.Selection(name, options: options, cjk: role?.hasPrefix("cjk-") == true)
        else { return }
        if let selector, selector.hasPrefix("\\"), selector.count > 1, document.reserveExpansion() {
            document.pageSettings.fonts.selectors[String(selector.dropFirst())] = document.pageSettings.fonts.family(
                selection)
        } else if let role {
            document.pageSettings.fonts.setRole(role, selection: selection)
        }
    }
}

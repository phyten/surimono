import Foundation

/// A named skin can set the insets used by later boxes. Resolve the keys in declaration
/// order so a local boxrule resets earlier side rules, exactly as a literal option would.
struct LaTeXBoxOptions {
    private var styles: [String: String] = [:]
    private(set) var balancedBefore = true
    private(set) var values: [String: String] = [:]

    mutating func apply(_ options: String) {
        var remaining = 4096
        var bytes = max(options.utf8.count, 262_144)
        apply(options, expanding: [], remaining: &remaining, bytes: &bytes)
    }

    private mutating func apply(_ options: String, expanding: Set<String>, remaining: inout Int, bytes: inout Int) {
        guard remaining > 0, expanding.count < 16, options.utf8.count <= bytes else { return }
        bytes -= options.utf8.count
        for (key, value) in LaTeXPageSettings.options(options) {
            guard remaining > 0 else { return }
            remaining -= 1
            if key.hasSuffix("/.style") {
                styles[String(key.dropLast(7))] = value
            } else if let style = styles[key], !expanding.contains(key) {
                apply(style, expanding: expanding.union([key]), remaining: &remaining, bytes: &bytes)
            } else {
                switch key {
                case "boxrule":
                    for side in ["leftrule", "rightrule", "toprule", "bottomrule", "titlerule"] { values[side] = value }
                case "left":
                    values["leftupper"] = value
                    values["lefttitle"] = value
                case "right":
                    values["rightupper"] = value
                    values["righttitle"] = value
                case "beforeafter skip", "beforeafter skip balanced":
                    balancedBefore = key.hasSuffix(" balanced")
                    values["before skip"] = value
                    values["after skip"] = value
                case "before skip", "before skip balanced":
                    balancedBefore = key.hasSuffix(" balanced")
                    values["before skip"] = value
                case "after skip balanced": values["after skip"] = value
                case "colback", "colframe", "coltitle", "fonttitle", "title", "arc", "boxsep", "top", "bottom",
                    "leftrule", "rightrule", "toprule", "bottomrule", "titlerule", "lefttitle", "righttitle",
                    "leftupper", "rightupper", "after skip", "breakable", "sharp corners", "parbox":
                    break
                default: continue
                }
                values[key] = value
            }
        }
    }
}

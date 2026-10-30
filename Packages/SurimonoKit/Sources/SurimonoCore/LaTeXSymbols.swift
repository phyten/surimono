import Foundation

/// Tables for the LaTeX converter: text symbols, accents, font sizes and colors.
enum LaTeXSymbols {
    /// Control words that stand for one piece of text.
    static let text: [String: String] = [
        "LaTeX": "LaTeX", "LaTeXe": "LaTeX2ε", "TeX": "TeX", "ldots": "…", "dots": "…", "textellipsis": "…",
        "ss": "ß", "ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ", "o": "ø", "O": "Ø", "aa": "å", "AA": "Å", "l": "ł",
        "L": "Ł", "i": "ı", "j": "ȷ", "copyright": "©", "textcopyright": "©", "textregistered": "®",
        "texttrademark": "™", "S": "§", "P": "¶", "dag": "†", "ddag": "‡", "textdagger": "†", "textdaggerdbl": "‡",
        "pounds": "£", "textsterling": "£", "euro": "€", "texteuro": "€", "textyen": "¥", "textdegree": "°",
        "textbullet": "•", "textperiodcentered": "·", "textendash": "–", "textemdash": "—", "textquoteleft": "‘",
        "textquoteright": "’", "textquotedblleft": "“", "textquotedblright": "”", "textless": "<", "textgreater": ">",
        "textbar": "|", "textasciitilde": "~", "textasciicircum": "^", "textbackslash": "\\", "textunderscore": "_",
        "slash": "/", "textmu": "µ", "textonehalf": "½", "textquarter": "¼", "textthreequarters": "¾",
        "textsection": "§", "textparagraph": "¶", "checkmark": "✓", "textthreesuperior": "³",
        "texttwosuperior": "²", "textonesuperior": "¹", "guillemotleft": "«", "guillemotright": "»",
        "quad": "\u{2003}", "qquad": "\u{2003}\u{2003}", "enspace": "\u{2002}", "thinspace": "\u{2009}",
        "hfill": " ", "hfil": " ", "dotfill": " … ", "relax": "", "protect": "", "noindent": "", "indent": "",
        "centering": "", "raggedright": "", "raggedleft": "", "null": "", "leavevmode": "", "nobreak": "",
        "allowbreak": "", "hline": "", "smallskip": "", "fussy": "", "sloppy": "",
    ]

    /// Control symbols (a backslash and one non-letter).
    static let controlSymbols: [Character: String] = [
        "#": "#", "$": "$", "%": "%", "&": "&", "_": "_", "{": "{", "}": "}", " ": " ", ",": "\u{2009}",
        ";": "\u{2005}", ":": "\u{2005}", "!": "", "-": "", "@": "", "/": "", "\n": " ", "\t": " ", "|": "‖",
    ]

    /// Combining marks for the accent commands: `\'e` is é.
    static let accents: [Character: Character] = [
        "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}", "\"": "\u{0308}", "~": "\u{0303}", "=": "\u{0304}",
        ".": "\u{0307}", "u": "\u{0306}", "v": "\u{030C}", "H": "\u{030B}", "c": "\u{0327}", "k": "\u{0328}",
        "d": "\u{0323}", "b": "\u{0331}", "r": "\u{030A}", "t": "\u{0361}",
    ]

    /// Font size declarations, relative to `\normalsize`.
    static let sizes: [String: Double] = [
        "tiny": 0.5, "scriptsize": 0.7, "footnotesize": 0.8, "small": 0.9, "normalsize": 1, "large": 1.2,
        "Large": 1.44, "LARGE": 1.728, "huge": 2.074, "Huge": 2.488,
    ]

    /// Font declarations, which apply to the rest of their group, and the markup they stand for.
    static let declarations: [String: (open: String, close: String)] = [
        "bfseries": ("<strong>", "</strong>"), "bf": ("<strong>", "</strong>"),
        "itshape": ("<em>", "</em>"), "it": ("<em>", "</em>"), "em": ("<em>", "</em>"),
        "slshape": ("<em>", "</em>"), "sl": ("<em>", "</em>"),
        "ttfamily": ("<code>", "</code>"), "tt": ("<code>", "</code>"),
        "scshape": ("<span class=\"latex-sc\">", "</span>"), "sc": ("<span class=\"latex-sc\">", "</span>"),
        "sffamily": ("<span class=\"latex-sf\">", "</span>"), "sf": ("<span class=\"latex-sf\">", "</span>"),
        "rmfamily": ("", ""), "rm": ("", ""), "mdseries": ("", ""), "upshape": ("", ""), "normalfont": ("", ""),
    ]

    /// Commands with one text argument and the markup around it.
    static let wrappers: [String: (open: String, close: String)] = [
        "textbf": ("<strong>", "</strong>"), "textit": ("<em>", "</em>"), "emph": ("<em>", "</em>"),
        "textsl": ("<em>", "</em>"), "texttt": ("<code>", "</code>"), "underline": ("<u>", "</u>"),
        "uline": ("<u>", "</u>"), "sout": ("<del>", "</del>"), "st": ("<del>", "</del>"),
        "hl": ("<mark>", "</mark>"), "textsc": ("<span class=\"latex-sc\">", "</span>"),
        "textsf": ("<span class=\"latex-sf\">", "</span>"), "textrm": ("", ""), "textup": ("", ""),
        "textmd": ("", ""), "textnormal": ("", ""), "mbox": ("<span class=\"latex-nowrap\">", "</span>"),
        "makebox": ("<span class=\"latex-nowrap\">", "</span>"), "fbox": ("<span class=\"latex-fbox\">", "</span>"),
        "framebox": ("<span class=\"latex-fbox\">", "</span>"), "textsuperscript": ("<sup>", "</sup>"),
        "textsubscript": ("<sub>", "</sub>"), "enquote": ("“", "”"), "text": ("", ""),
    ]

    /// Commands that only set something up for TeX; their arguments are read and dropped. The value is the number of
    /// mandatory arguments; an optional argument in front is dropped too.
    static let ignored: [String: Int] = [
        "setlength": 2, "addtolength": 2, "setcounter": 2, "addtocounter": 2, "stepcounter": 1, "pagestyle": 1,
        "thispagestyle": 1, "pagenumbering": 1, "vspace": 1, "hspace": 1, "geometry": 1, "hypersetup": 1,
        "lstset": 1, "graphicspath": 1, "bibliographystyle": 1, "usetikzlibrary": 1, "numberwithin": 2,
        "newtheoremstyle": 9, "captionsetup": 1, "setmainfont": 1, "setsansfont": 1, "setmonofont": 1,
        "setmainjfont": 1, "setsansjfont": 1, "newlength": 1, "colorlet": 2, "linespread": 1, "usepackage": 1,
        "RequirePackage": 1, "documentclass": 1, "label": 1, "index": 1, "glossary": 1, "nocite": 1,
        "addcontentsline": 3, "markboth": 2, "markright": 1, "setcitestyle": 1,
        "addbibresource": 1, "newcounter": 1, "renewenvironment": 3, "newenvironment": 3, "selectlanguage": 1,
        "hyphenation": 1, "phantom": 1, "hphantom": 1, "vphantom": 1, "includeonly": 1, "titleformat": 5,
        "sisetup": 1, "pgfplotsset": 1, "tikzset": 1, "ExecuteOptions": 1, "PassOptionsToPackage": 2,
        "definecolor": 3, "DeclareMathOperator": 2, "bibitem": 1,
    ]

    /// xcolor's base colors.
    static let colors: [String: (Double, Double, Double)] = [
        "red": (1, 0, 0), "green": (0, 1, 0), "blue": (0, 0, 1), "cyan": (0, 1, 1), "magenta": (1, 0, 1),
        "yellow": (1, 1, 0), "black": (0, 0, 0), "white": (1, 1, 1), "gray": (0.5, 0.5, 0.5),
        "darkgray": (0.25, 0.25, 0.25), "lightgray": (0.75, 0.75, 0.75), "brown": (0.75, 0.5, 0.25),
        "lime": (0.75, 1, 0), "olive": (0.5, 0.5, 0), "orange": (1, 0.5, 0), "pink": (1, 0.75, 0.75),
        "purple": (0.75, 0, 0.25), "teal": (0, 0.5, 0.5), "violet": (0.5, 0, 0.5),
    ]

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    /// A counter value written as `\arabic`, `\alph`, `\Alph`, `\roman` or `\Roman` would write it.
    static func format(_ value: Int, as style: String) -> String {
        switch style {
        case "alph": return letters(value, uppercase: false)
        case "Alph": return letters(value, uppercase: true)
        case "roman": return roman(value).lowercased()
        case "Roman": return roman(value)
        default: return String(value)
        }
    }

    private static func letters(_ value: Int, uppercase: Bool) -> String {
        guard value >= 1 else { return String(value) }
        var number = value
        var result = ""
        while number > 0 {
            number -= 1
            result = String(UnicodeScalar(UInt8((uppercase ? 65 : 97) + number % 26))) + result
            number /= 26
        }
        return result
    }

    private static func roman(_ value: Int) -> String {
        guard value >= 1, value < 4000 else { return String(value) }
        let numerals = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var number = value
        var result = ""
        for (amount, numeral) in numerals {
            while number >= amount {
                result += numeral
                number -= amount
            }
        }
        return result
    }

    /// A CSS color for an xcolor expression: a name (base or defined), `name!50` mixed with white, `name!30!blue`
    /// mixed with another color, or a value in the HTML, rgb, RGB or gray model.
    static func cssColor(_ spec: String, model: String? = nil, defined: [String: (Double, Double, Double)]) -> String? {
        if let rgb = rgb(spec.trimmingCharacters(in: .whitespaces), model: model, defined: defined),
            rgb.0.isFinite, rgb.1.isFinite, rgb.2.isFinite
        {
            func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            return String(format: "#%02x%02x%02x", byte(rgb.0), byte(rgb.1), byte(rgb.2))
        }
        return nil
    }

    static func rgb(_ spec: String, model: String?, defined: [String: (Double, Double, Double)])
        -> (Double, Double, Double)?
    {
        if let model {
            // Only finite numbers: `Double("nan")` parses, and NaN survives min and max.
            let parts = spec.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { $0.flatMap { $0.isFinite ? $0 : nil } }
            switch model {
            case "HTML":
                guard spec.count == 6, let value = Int(spec, radix: 16) else { return nil }
                return (
                    Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255
                )
            case "rgb":
                guard parts.count == 3, let r = parts[0], let g = parts[1], let b = parts[2] else { return nil }
                return (r, g, b)
            case "RGB":
                guard parts.count == 3, let r = parts[0], let g = parts[1], let b = parts[2] else { return nil }
                return (r / 255, g / 255, b / 255)
            case "gray":
                guard parts.count == 1, let gray = parts[0] else { return nil }
                return (gray, gray, gray)
            default:
                return nil
            }
        }
        let terms = spec.split(separator: "!").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = terms.first, var color = defined[first] ?? colors[first] else { return nil }
        var index = 1
        while index < terms.count {
            guard let percent = Double(terms[index]), percent.isFinite else { return nil }
            let other: (Double, Double, Double)
            if index + 1 < terms.count {
                guard let named = defined[terms[index + 1]] ?? colors[terms[index + 1]] else { return nil }
                other = named
            } else {
                other = (1, 1, 1)
            }
            let share = min(max(percent, 0), 100) / 100
            color = (
                color.0 * share + other.0 * (1 - share), color.1 * share + other.1 * (1 - share),
                color.2 * share + other.2 * (1 - share)
            )
            index += 2
        }
        return color
    }

    /// A TeX length as CSS: `0.5\textwidth` is 50%, `3cm` stays 3cm, `1em` stays 1em.
    static func cssLength(_ length: String) -> String? {
        let text = length.trimmingCharacters(in: .whitespaces)
        for relative in ["\\textwidth", "\\linewidth", "\\columnwidth", "\\hsize"] where text.hasSuffix(relative) {
            let factor = text.dropLast(relative.count).trimmingCharacters(in: .whitespaces)
            let value = factor.isEmpty ? 1 : Double(factor)
            return value.map { String(format: "%g%%", $0 * 100) }
        }
        guard
            let match = text.range(
                of: #"^-?[0-9]*\.?[0-9]+\s*(pt|mm|cm|in|em|ex|pc|bp)$"#, options: .regularExpression)
        else { return nil }
        let value = text[match].replacingOccurrences(of: " ", with: "")
        return value.hasSuffix("bp") ? value.replacingOccurrences(of: "bp", with: "pt") : value
    }
}

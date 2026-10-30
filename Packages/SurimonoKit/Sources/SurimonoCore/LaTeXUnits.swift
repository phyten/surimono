import Foundation

/// The basics of siunitx: `\num`, `\qty` (`\SI`), `\unit` (`\si`) and `\ang`, as text and as math.
///
/// Numbers follow siunitx 3's defaults: digits in groups of three once a part has five or more, `e` as `× 10^n`,
/// and a true minus. Units written with macros (`\kilo\metre\per\second`) print as powers (`km s⁻¹`); units written
/// literally (`km/s`) print as written, with `.` and `~` as the space between units.
enum LaTeXUnits {
    struct Number {
        var sign = ""
        var integer = ""
        var fraction: String?
        var exponent: String?
    }

    enum Piece: Equatable {
        case unit(symbol: String, power: String?)
        case text(String)
    }

    // MARK: - Numbers

    static func number(_ source: String) -> Number? {
        var characters = Substring(source.filter { !$0.isWhitespace && $0 != "{" && $0 != "}" })
        var number = Number()
        if let first = characters.first, first == "-" || first == "+" {
            number.sign = first == "-" ? "−" : ""
            characters = characters.dropFirst()
        }
        var mantissa = characters
        if let marker = characters.firstIndex(where: { "eEdD".contains($0) }) {
            mantissa = characters[..<marker]
            var exponent = characters[characters.index(after: marker)...]
            var negative = false
            if let first = exponent.first, first == "-" || first == "+" {
                negative = first == "-"
                exponent = exponent.dropFirst()
            }
            guard !exponent.isEmpty, exponent.allSatisfy(\.isASCIIDigit) else { return nil }
            number.exponent = (negative ? "−" : "") + exponent
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
        guard (1...2).contains(parts.count), parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }) else { return nil }
        number.integer = parts[0].isEmpty ? "0" : String(parts[0])
        if parts.count == 2 { number.fraction = String(parts[1]) }
        guard !(parts[0].isEmpty && (number.fraction ?? "").isEmpty) || number.exponent != nil else { return nil }
        if parts[0].isEmpty, (number.fraction ?? "").isEmpty { number.integer = "" }
        return number
    }

    /// Digits in groups of three, counted from the decimal point, once there are five or more.
    private static func grouped(_ digits: String, fromLeft: Bool, separator: String) -> String {
        guard digits.count >= 5 else { return digits }
        let characters = Array(digits)
        var groups: [String] = []
        if fromLeft {
            for start in stride(from: 0, to: characters.count, by: 3) {
                groups.append(String(characters[start..<min(start + 3, characters.count)]))
            }
        } else {
            var start = 0
            var end = characters.count % 3 == 0 ? 3 : characters.count % 3
            while start < characters.count {
                groups.append(String(characters[start..<end]))
                start = end
                end += 3
            }
        }
        return groups.joined(separator: separator)
    }

    /// A value and its uncertainty, written `1.2+-0.3` or `1.2 \pm 0.3`.
    private static func uncertainty(_ source: String) -> (String, String)? {
        for marker in ["+-", "\\pm"] {
            if let range = source.range(of: marker) {
                return (String(source[..<range.lowerBound]), String(source[range.upperBound...]))
            }
        }
        return nil
    }

    static func numberHTML(_ source: String) -> String {
        let raw = HTML.escape(source.trimmingCharacters(in: .whitespaces))
        if let (value, error) = uncertainty(source) {
            guard let value = number(value), let error = number(error) else { return raw }
            return html(value) + " ± " + html(error)
        }
        return number(source).map(html) ?? raw
    }

    private static func html(_ number: Number) -> String {
        var html = number.sign + grouped(number.integer, fromLeft: false, separator: "\u{202F}")
        if let fraction = number.fraction { html += "." + grouped(fraction, fromLeft: true, separator: "\u{202F}") }
        if let exponent = number.exponent {
            html += (number.integer.isEmpty ? "" : " × ") + "10<sup>\(exponent)</sup>"
        }
        return html
    }

    static func numberMath(_ source: String) -> String {
        if let (value, error) = uncertainty(source) {
            guard let value = number(value), let error = number(error) else { return source }
            return math(value) + "\\pm " + math(error)
        }
        return number(source).map(math) ?? source
    }

    private static func math(_ number: Number) -> String {
        var latex = (number.sign.isEmpty ? "" : "-") + grouped(number.integer, fromLeft: false, separator: "\\,")
        if let fraction = number.fraction { latex += "." + grouped(fraction, fromLeft: true, separator: "\\,") }
        if let exponent = number.exponent {
            let power = exponent.replacingOccurrences(of: "−", with: "-")
            latex += (number.integer.isEmpty ? "" : "\\times ") + "10^{\(power)}"
        }
        return latex
    }

    // MARK: - Units

    static let prefixes: [String: String] = [
        "quecto": "q", "ronto": "r", "yocto": "y", "zepto": "z", "atto": "a", "femto": "f", "pico": "p", "nano": "n",
        "micro": "µ", "milli": "m", "centi": "c", "deci": "d", "deca": "da", "deka": "da", "hecto": "h", "kilo": "k",
        "mega": "M", "giga": "G", "tera": "T", "peta": "P", "exa": "E", "zetta": "Z", "yotta": "Y", "ronna": "R",
        "quetta": "Q", "kibi": "Ki", "mebi": "Mi", "gibi": "Gi", "tebi": "Ti",
    ]

    static let units: [String: String] = [
        "ampere": "A", "candela": "cd", "kelvin": "K", "kilogram": "kg", "gram": "g", "metre": "m", "meter": "m",
        "mole": "mol", "second": "s", "becquerel": "Bq", "degreeCelsius": "°C", "celsius": "°C", "coulomb": "C",
        "farad": "F", "gray": "Gy", "hertz": "Hz", "henry": "H", "joule": "J", "katal": "kat", "lumen": "lm",
        "lux": "lx", "newton": "N", "ohm": "Ω", "pascal": "Pa", "radian": "rad", "siemens": "S", "sievert": "Sv",
        "steradian": "sr", "tesla": "T", "volt": "V", "watt": "W", "weber": "Wb", "astronomicalunit": "au",
        "bel": "B", "decibel": "dB", "dalton": "Da", "day": "d", "electronvolt": "eV", "hectare": "ha", "hour": "h",
        "litre": "L", "liter": "L", "minute": "min", "neper": "Np", "tonne": "t", "percent": "%", "degree": "°",
        "arcminute": "′", "arcsecond": "″", "angstrom": "Å", "bar": "bar", "barn": "b", "knot": "kn",
        "mmHg": "mmHg", "bit": "bit", "byte": "B",
        // siunitx's abbreviations.
        "kg": "kg", "g": "g", "mg": "mg", "m": "m", "cm": "cm", "mm": "mm", "km": "km", "um": "µm", "nm": "nm",
        "s": "s", "ms": "ms", "us": "µs", "ns": "ns", "ps": "ps", "Hz": "Hz", "kHz": "kHz", "MHz": "MHz",
        "GHz": "GHz", "A": "A", "mA": "mA", "uA": "µA", "V": "V", "mV": "mV", "kV": "kV", "W": "W", "mW": "mW",
        "kW": "kW", "MW": "MW", "J": "J", "kJ": "kJ", "N": "N", "kN": "kN", "Pa": "Pa", "kPa": "kPa", "MPa": "MPa",
        "GPa": "GPa", "K": "K", "mol": "mol", "mmol": "mmol", "L": "L", "mL": "mL", "uL": "µL", "eV": "eV",
        "keV": "keV", "MeV": "MeV", "GeV": "GeV", "TeV": "TeV", "kWh": "kWh", "dB": "dB",
    ]

    /// A unit as pieces: units with their powers, or text written literally.
    static func pieces(_ source: String) -> [Piece] {
        let characters = Array(source)
        var pieces: [Piece] = []
        var index = 0
        var prefix = ""
        var inverse = false
        var pendingPower: String?
        var literal = ""
        func group() -> String {
            while index < characters.count, characters[index] == " " { index += 1 }
            guard index < characters.count else { return "" }
            if characters[index] != "{" {
                defer { index += 1 }
                return String(characters[index])
            }
            var depth = 0
            var text = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "{" {
                    depth += 1
                    if depth == 1 { continue }
                }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                text.append(character)
            }
            return text
        }
        func flushLiteral() {
            if !literal.isEmpty { pieces.append(.text(literal)) }
            literal = ""
        }
        func raisePrevious(_ power: String) {
            guard case .unit(let symbol, let current) = pieces.last else { return }
            let negative = current?.hasPrefix("-") == true
            pieces[pieces.count - 1] = .unit(symbol: symbol, power: negative ? "-" + power : power)
        }
        while index < characters.count {
            let character = characters[index]
            guard character == "\\" else {
                literal.append(character)
                index += 1
                continue
            }
            index += 1
            var name = ""
            while index < characters.count, characters[index].isASCII, characters[index].isLetter {
                name.append(characters[index])
                index += 1
            }
            switch name {
            case "per": inverse = true
            case "square": pendingPower = "2"
            case "cubic": pendingPower = "3"
            case "raiseto": pendingPower = group()
            case "squared": raisePrevious("2")
            case "cubed": raisePrevious("3")
            case "tothe": raisePrevious(group())
            default:
                if let symbol = prefixes[name] {
                    flushLiteral()
                    prefix += symbol
                } else if let symbol = units[name] {
                    flushLiteral()
                    let power = pendingPower ?? (inverse ? "1" : nil)
                    pieces.append(.unit(symbol: prefix + symbol, power: inverse ? "-" + (power ?? "1") : power))
                    prefix = ""
                    inverse = false
                    pendingPower = nil
                } else if name.isEmpty, index < characters.count {
                    literal.append(characters[index])
                    index += 1
                } else {
                    literal += name
                }
            }
        }
        flushLiteral()
        return pieces
    }

    static func unitHTML(_ source: String) -> String {
        pieces(source).map { piece -> String in
            switch piece {
            case .unit(let symbol, let power):
                return HTML.escape(symbol) + (power.map { "<sup>\(HTML.escape(minus($0)))</sup>" } ?? "")
            case .text(let text): return literalHTML(text)
            }
        }.joined(separator: "\u{202F}")
    }

    static func unitMath(_ source: String) -> String {
        pieces(source).map { piece -> String in
            switch piece {
            case .unit(let symbol, let power): return mathSymbol(symbol) + (power.map { "^{\($0)}" } ?? "")
            case .text(let text): return literalMath(text)
            }
        }.joined(separator: "\\,")
    }

    private static func minus(_ text: String) -> String { text.replacingOccurrences(of: "-", with: "−") }

    /// Literal units as siunitx 3 prints them: as written, with `.` and `~` between units and `^`, `_` as scripts.
    private static func literalHTML(_ text: String) -> String {
        var html = ""
        var characters = Substring(text)
        while let character = characters.first {
            characters = characters.dropFirst()
            switch character {
            case ".", "~": html += "\u{202F}"
            case "^", "_":
                let tag = character == "^" ? "sup" : "sub"
                let script = scriptArgument(&characters)
                html += "<\(tag)>\(HTML.escape(minus(script)))</\(tag)>"
            case " ": continue
            default: html += HTML.escape(String(character))
            }
        }
        return html
    }

    private static func literalMath(_ text: String) -> String {
        var latex = ""
        var word = ""
        var characters = Substring(text)
        func flushWord() {
            if !word.isEmpty { latex += mathSymbol(word) }
            word = ""
        }
        while let character = characters.first {
            characters = characters.dropFirst()
            switch character {
            case ".", "~":
                flushWord()
                latex += "\\,"
            case "^", "_":
                flushWord()
                latex += "\(character){\(scriptArgument(&characters))}"
            case "/":
                flushWord()
                latex += "/"
            case " ": flushWord()
            default: word.append(character)
            }
        }
        flushWord()
        return latex
    }

    private static func scriptArgument(_ characters: inout Substring) -> String {
        guard let first = characters.first else { return "" }
        guard first == "{", let close = characters.firstIndex(of: "}") else {
            // An unbraced script is a signed number, as in `^-1`.
            var script = ""
            if first == "-" || first == "+" {
                script.append(first)
                characters = characters.dropFirst()
            }
            while let digit = characters.first, digit.isASCIIDigit {
                script.append(digit)
                characters = characters.dropFirst()
            }
            if script.isEmpty || script == "-" || script == "+", let next = characters.first {
                script.append(next)
                characters = characters.dropFirst()
            }
            return script
        }
        let script = String(characters[characters.index(after: characters.startIndex)..<close])
        characters = characters[characters.index(after: close)...]
        return script
    }

    /// Symbols SwaTex draws with KaTeX's own glyphs; a degree sign written as text gets no metrics and stands apart.
    private static let mathSymbols: [Character: String] = [
        "°": "{}^{\\circ}", "Ω": "\\Omega", "′": "{}^{\\prime}", "″": "{}^{\\prime\\prime}", "%": "\\%",
    ]

    /// A unit symbol in upright math. Letters KaTeX's fonts lack in roman, such as µ, are written as text.
    private static func mathSymbol(_ symbol: String) -> String {
        var latex = ""
        var letters = ""
        func flush() {
            guard !letters.isEmpty else { return }
            latex += letters.allSatisfy(\.isASCII) ? "\\mathrm{\(letters)}" : "\\text{\(letters)}"
            letters = ""
        }
        for character in symbol {
            if let replacement = mathSymbols[character] {
                flush()
                latex += replacement
            } else {
                letters.append(character)
            }
        }
        flush()
        return latex
    }

    // MARK: - Math

    private static let commands: Set<String> = ["num", "qty", "SI", "unit", "si", "ang"]

    /// A formula with its siunitx commands written as the math SwaTex reads. A command without its arguments, such
    /// as physics' `\qty(…)`, stays as written.
    static func expandingInMath(_ latex: String) -> String {
        guard commands.contains(where: { latex.contains("\\" + $0) }) else { return latex }
        let characters = Array(latex)
        // Where each brace and bracket closes, found in one pass, so an argument that never closes is not searched for
        // again at every command.
        func closings(_ open: Character, _ close: Character) -> [Int: Int] {
            var closings: [Int: Int] = [:]
            var opened: [Int] = []
            var position = 0
            while position < characters.count {
                let character = characters[position]
                if character == "\\" {
                    position += 2
                    continue
                }
                if character == open {
                    opened.append(position)
                } else if character == close, let start = opened.popLast() {
                    closings[start] = position
                }
                position += 1
            }
            return closings
        }
        let braces = closings("{", "}")
        let brackets = closings("[", "]")
        /// The inside of the group that opens at or after `start`, and where the source goes on after it.
        func group(_ open: Character, from start: Int) -> (Range<Int>, Int)? {
            var cursor = start
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == open,
                let end = (open == "{" ? braces : brackets)[cursor]
            else { return nil }
            return ((cursor + 1)..<end, end + 1)
        }
        /// A command's math and where the source goes on, once all its arguments are found; the arguments are copied
        /// only then, so a command missing one costs nothing.
        func command(_ name: String, at start: Int) -> (String, Int)? {
            var cursor = start
            if let (_, next) = group("[", from: cursor) { cursor = next }
            guard let (first, afterFirst) = group("{", from: cursor) else { return nil }
            let text = { (range: Range<Int>) in String(characters[range]) }
            switch name {
            case "num": return (numberMath(text(first)), afterFirst)
            case "unit", "si": return (unitMath(text(first)), afterFirst)
            case "ang": return (angleMath(text(first)), afterFirst)
            default:
                cursor = afterFirst
                var before: Range<Int>?
                if name == "SI", let (range, next) = group("[", from: cursor) {
                    before = range
                    cursor = next
                }
                guard let (unit, afterUnit) = group("{", from: cursor) else { return nil }
                let prefix = before.map { unitMath(text($0)) + "\\," } ?? ""
                return (prefix + numberMath(text(first)) + "\\," + unitMath(text(unit)), afterUnit)
            }
        }
        var output = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\" else {
                output.append(characters[index])
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, characters[end].isASCII, characters[end].isLetter { end += 1 }
            if end == index + 1 { end = min(end + 1, characters.count) }
            let name = String(characters[(index + 1)..<end])
            if commands.contains(name), let (expansion, next) = command(name, at: end) {
                output += "{\(expansion)}"
                index = next
                continue
            }
            output += String(characters[index..<end])
            index = end
        }
        return output
    }

    // MARK: - Angles

    /// `\ang{12;30;15}` as 12°30′15″.
    static func angleHTML(_ source: String) -> String {
        zip(source.split(separator: ";", omittingEmptySubsequences: false), ["°", "′", "″"])
            .filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { numberHTML(String($0.0)) + $0.1 }.joined()
    }

    static func angleMath(_ source: String) -> String {
        zip(source.split(separator: ";", omittingEmptySubsequences: false), ["^{\\circ}", "'", "''"])
            .filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { numberMath(String($0.0)) + $0.1 }.joined()
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

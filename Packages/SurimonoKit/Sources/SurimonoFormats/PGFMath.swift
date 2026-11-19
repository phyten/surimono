import Foundation

/// Parse PGF's numeric subset without handing expressions to a scripting engine.
struct PGFMath {
    private let input: [Character]
    private let x: Double?
    private var index = 0
    private var next: Character? { index < input.count ? input[index] : nil }

    static func evaluate(_ expression: String, x: Double? = nil) throws -> Double {
        guard expression.utf8.count <= 1024 else { throw TikZError("pgfmath") }
        var parser = PGFMath(input: Array(expression), x: x)
        let result = try parser.expression(0, depth: 0)
        parser.spaces()
        guard parser.next == nil else { throw TikZError(String(expression.prefix(80))) }
        return result
    }

    private mutating func spaces() {
        while next?.isWhitespace == true { index += 1 }
    }

    private mutating func take(_ character: Character) -> Bool {
        spaces()
        guard next == character else { return false }
        index += 1
        return true
    }

    private mutating func expression(_ minimum: Int, depth: Int) throws -> Double {
        guard depth < 48 else { throw TikZError("pgfmath") }
        var value: Double
        if take("-") || take("−") {
            value = try -expression(3, depth: depth + 1)
        } else if take("+") {
            value = try expression(3, depth: depth + 1)
        } else {
            value = try atom(depth: depth)
        }
        guard value.isFinite else { throw TikZError("pgfmath") }
        spaces()
        while let op = next, let priority = Self.precedence[op], priority >= minimum {
            index += 1
            let other = try expression(op == "^" ? priority : priority + 1, depth: depth + 1)
            switch op {
            case "+": value += other
            case "-", "−": value -= other
            case "*": value *= other
            case "/": value /= other
            default: value = pow(value, other)
            }
            guard value.isFinite else { throw TikZError("pgfmath") }
            spaces()
        }
        return value
    }

    private static let precedence: [Character: Int] = ["+": 1, "-": 1, "−": 1, "*": 2, "/": 2, "^": 3]

    private mutating func atom(depth: Int) throws -> Double {
        if take("(") {
            let result = try expression(0, depth: depth + 1)
            guard take(")") else { throw TikZError("pgfmath") }
            return result
        }
        let controlWord = take("\\")
        let start = index
        if next?.isLetter == true {
            while let ch = next, ch.isASCII && (ch.isLetter || ch.isNumber) { index += 1 }
            let name = String(input[start..<index])
            if name == "x", let x { return x }
            guard !controlWord else { throw TikZError("\\" + name) }
            switch name {
            case "pi": return .pi
            case "e": return exp(1)
            default: break
            }
            guard take("(") else { throw TikZError(name) }
            let a = try expression(0, depth: depth + 1)
            if take(",") {
                let b = try expression(0, depth: depth + 1)
                guard take(")") else { throw TikZError(name) }
                switch name {
                case "min": return min(a, b)
                case "max": return max(a, b)
                case "mod": return a.truncatingRemainder(dividingBy: b)
                default: throw TikZError(name)
                }
            }
            guard take(")") else { throw TikZError(name) }
            switch name {
            case "sin": return sin(a * .pi / 180)
            case "cos": return cos(a * .pi / 180)
            case "tan":
                guard abs(a.truncatingRemainder(dividingBy: 180)) != 90 else { throw TikZError(name) }
                return tan(a * .pi / 180)
            case "sqrt": return sqrt(a)
            case "abs": return abs(a)
            case "exp": return exp(a)
            case "ln": return log(a)
            case "log10": return log10(a)
            case "floor": return floor(a)
            case "ceil": return ceil(a)
            case "round": return a.rounded()
            default: throw TikZError(name)
            }
        }
        guard !controlWord else { throw TikZError("pgfmath") }
        while let ch = next, ch.isASCII && (ch.isNumber || ch == ".") { index += 1 }
        if next == "e" || next == "E" {
            index += 1
            if next == "+" || next == "-" { index += 1 }
            while let ch = next, ch.isASCII && ch.isNumber { index += 1 }
        }
        guard let number = Double(String(input[start..<index])) else { throw TikZError("pgfmath") }
        return number
    }
}

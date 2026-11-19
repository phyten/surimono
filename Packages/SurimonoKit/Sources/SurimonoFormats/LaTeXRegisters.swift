import Foundation

extension LaTeXReader {
    static let registerCommands: Set<String> = [
        "newcount", "count", "advance", "multiply", "divide", "the", "number", "numexpr", "dimexpr",
    ]

    /// A count register in horizontal mode is an assignment. Only \the and \number print its value.
    func handleRegister(_ name: String) -> Bool {
        switch name {
        case "newcount":
            if let token = argument(), token.hasPrefix("\\"), token.count > 1, document.reserveExpansion() {
                document.countRegisters[String(token.dropFirst())] = 0
            }
        case "advance", "multiply", "divide":
            skipSpaces()
            let target = registerKey(String(controlToken().dropFirst()), depth: 0)
            skipSpaces()
            if peek() == "b", peek(1) == "y" { index += 2 }
            guard let rhs = integerOperand(), let target else { return true }
            let operation: Character = name == "advance" ? "+" : name == "multiply" ? "*" : "/"
            if let result = arithmetic(document.countRegisters[target] ?? 0, operation, rhs, rounding: false) {
                document.countRegisters[target] = result
            }
        case "number", "the", "numexpr", "dimexpr":
            if let value = printedRegister(name) { appendText(value) }
        default:
            guard name == "count" || document.countRegisters[name] != nil else { return false }
            let key = registerKey(name, depth: 0)
            skipSpaces()
            if peek() == "=" { index += 1 }
            if let value = integerOperand(), let key { document.countRegisters[key] = value }
        }
        return true
    }

    /// Used in both text and math so a loop's formula captures the register value in that iteration.
    func printedRegister(_ name: String) -> String? {
        switch name {
        case "the":
            skipSpaces()
            let token = String(controlToken().dropFirst())
            skipSpacesAfterControlWord()
            if token == "dimexpr" { return expression(dimension: true, depth: 0).map(printedDimension) }
            return numericCommand(token, depth: 0).map(String.init)
        case "numexpr": return expression(dimension: false, depth: 0).map(String.init)
        case "dimexpr": return expression(dimension: true, depth: 0).map(printedDimension)
        default: return integerOperand().map(String.init)
        }
    }

    private func registerKey(_ name: String, depth: Int) -> String? {
        if name == "count" {
            guard let slot = numericAtom(dimension: false, depth: depth + 1), (0...32767).contains(slot) else {
                return nil
            }
            // A decimal key cannot collide with a named control word.
            return "#" + String(slot)
        }
        return document.countRegisters[name] == nil ? nil : name
    }

    func integerOperand() -> Int? { numericAtom(dimension: false, depth: 0) }

    func dimensionOperand() -> Int? { numericAtom(dimension: true, depth: 0) }

    func integerArgument(_ raw: String) -> Int? {
        let reader = LaTeXReader(raw, document: document, isBlock: false)
        let value = reader.integerOperand()
        reader.skipSpaces()
        return reader.peek() == nil ? value : nil
    }

    func evaluatedLength(_ raw: String) -> String {
        let reader = LaTeXReader(raw, document: document, isBlock: false)
        reader.skipSpaces()
        guard reader.controlToken() == "\\dimexpr", let value = reader.expression(dimension: true, depth: 0) else {
            return raw
        }
        reader.skipSpaces()
        return reader.peek() == nil ? printedDimension(value) : raw
    }

    private func numericCommand(_ name: String, dimension: Bool = false, depth: Int) -> Int? {
        switch name {
        case "value", "arabic": return document.counters[argument() ?? ""]
        case "numexpr", "dimexpr": return expression(dimension: name == "dimexpr", depth: depth + 1)
        case "number", "the": return numericAtom(dimension: false, depth: depth + 1)
        default:
            if let key = registerKey(name, depth: depth) { return document.countRegisters[key] ?? 0 }
            if let macro = document.macros[name], !document.stopsExpanding {
                // Expand only tokens that supply a number, including in math. Never dispatch an assignment here.
                if let primitive = macro.primitive {
                    guard depth + document.depth < LaTeXDocument.maximumDepth else { return nil }
                    return numericCommand(primitive, dimension: dimension, depth: depth + 1)
                }
                guard let body = replacement(macro) else { return nil }
                insertExpansion(body)
                return numericAtom(dimension: dimension, depth: depth + 1)
            }
            if name.hasPrefix("the"), document.counters.contains(String(name.dropFirst(3))) {
                return Int(formattedCounter(String(name.dropFirst(3)), forMath: true))
            }
            return nil
        }
    }

    private func numericAtom(dimension: Bool, depth: Int) -> Int? {
        guard document.depth + depth < LaTeXDocument.maximumDepth else {
            document.stopsExpanding = true
            return nil
        }
        skipSpaces()
        var negative = false
        while peek() == "-" || peek() == "+" {
            if peek() == "-" { negative.toggle() }
            index += 1
            skipSpaces()
        }
        let value: Int?
        if peek() == "(" {
            index += 1
            value = sum(dimension: dimension, depth: depth + 1)
            guard peek() == ")" else { return nil }
            index += 1
        } else if peek() == "\\" {
            let name = String(controlToken().dropFirst())
            skipSpacesAfterControlWord()
            value = numericCommand(name, dimension: dimension, depth: depth)
        } else {
            let start = index
            while let char = peek(), char.isASCII && (char.isNumber || (dimension && (char == "." || char == ","))) {
                index += 1
            }
            guard start < index else { return nil }
            let raw = String(characters[start..<index])
            if dimension {
                skipSpaces()
                guard let a = peek(), let b = peek(1), let unit = Self.dimensionUnits[String([a, b]).lowercased()]
                else {
                    return nil
                }
                index += 2
                value = Double(raw.replacingOccurrences(of: ",", with: ".")).flatMap {
                    // TeX rounds the decimal coefficient first, then truncates the physical unit conversion.
                    Int(exactly: (($0 * 65_536).rounded() * unit.numerator / unit.denominator).rounded(.towardZero))
                }
            } else {
                if peek()?.isWhitespace == true { skipSpacesAfterControlWord() }
                return Int((negative ? "-" : "") + raw)
            }
        }
        if peek()?.isWhitespace == true { skipSpacesAfterControlWord() }
        guard let value else { return nil }
        if !negative { return value }
        return arithmetic(0, "-", value)
    }

    static let dimensionUnits: [String: (numerator: Double, denominator: Double)] = [
        "pt": (1, 1), "mm": (7227, 2540), "cm": (7227, 254), "in": (7227, 100), "em": (10, 1), "ex": (43, 10),
        "pc": (12, 1), "bp": (7227, 7200), "sp": (1, 65_536), "dd": (1238, 1157), "cc": (12 * 1238, 1157),
    ]

    private func expression(dimension: Bool, depth: Int) -> Int? {
        let value = sum(dimension: dimension, depth: depth)
        if peek() == "\\" {
            let start = index
            if controlToken() == "\\relax" { skipSpacesAfterControlWord() } else { index = start }
        }
        return value
    }

    private func sum(dimension: Bool, depth: Int) -> Int? {
        var value = product(dimension: dimension, depth: depth)
        while let op = peek(), op == "+" || op == "-" {
            index += 1
            let rhs = product(dimension: dimension, depth: depth)
            value = value.flatMap { lhs in rhs.flatMap { arithmetic(lhs, op, $0) } }
        }
        return value
    }

    private func product(dimension: Bool, depth: Int) -> Int? {
        var value = numericAtom(dimension: dimension, depth: depth)
        while let op = peek(), op == "*" || op == "/" {
            index += 1
            let rhs = numericAtom(dimension: false, depth: depth)
            value = value.flatMap { lhs in rhs.flatMap { arithmetic(lhs, op, $0) } }
        }
        return value
    }

    /// e-TeX expressions round division to the nearest integer. The older \divide primitive truncates.
    private func arithmetic(_ lhs: Int, _ op: Character, _ rhs: Int, rounding: Bool = true) -> Int? {
        let result: (partialValue: Int, overflow: Bool)
        switch op {
        case "+": result = lhs.addingReportingOverflow(rhs)
        case "-": result = lhs.subtractingReportingOverflow(rhs)
        case "*": result = lhs.multipliedReportingOverflow(by: rhs)
        default:
            guard rhs != 0, !(lhs == Int.min && rhs == -1) else { return nil }
            let quotient = lhs / rhs
            let remainder = (lhs % rhs).magnitude
            if rounding && remainder > 0 && remainder >= rhs.magnitude - remainder {
                return quotient + ((lhs < 0) == (rhs < 0) ? 1 : -1)
            }
            return quotient
        }
        return result.overflow ? nil : result.partialValue
    }

    /// TeX's print_scaled uses the shortest decimal that distinguishes adjacent scaled points.
    private func printedDimension(_ value: Int) -> String {
        let magnitude = value.magnitude
        var fraction = 10 * (magnitude % 65_536) + 5
        var delta: UInt = 10
        var digits = ""
        repeat {
            if delta > 65_536 { fraction += 32_768 - 5_000 }
            digits += String(fraction / 65_536)
            fraction = 10 * (fraction % 65_536)
            delta *= 10
        } while fraction > delta
        return (value < 0 ? "-" : "") + String(magnitude / 65_536) + "." + digits + "pt"
    }
}

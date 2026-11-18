import Foundation

extension LaTeXReader {
    static let loopNames: Set<String> = ["foreach", "loop", "whiledo", "multido", "forloop"]

    /// Reevaluate conditions in the current document so assignments in one iteration are visible to the next.
    func readLoop(_ name: String) {
        switch name {
        case "foreach": foreachLoop()
        case "loop": primitiveLoop()
        case "whiledo":
            let test = argument() ?? ""
            let body = argument() ?? ""
            var quota = LoopQuota(test, body)
            while !document.stopsExpanding && condition(test) && quota.next(document) {
                readExpansionBody(body)
            }
        case "multido": multidoLoop()
        case "forloop": counterLoop()
        default: break
        }
    }

    /// Empty bodies and false-only nested branches still cost an iteration. Charge the condition too:
    /// a large expression in a small loop body should not be copied and parsed 10,000 times for free.
    private struct LoopQuota {
        var iterations = 0
        let cost: Int

        init(_ sources: String...) {
            cost = sources.reduce(0) { $0 + $1.count }
        }

        /// Allow 10,000 iterations for long lists. A stuck loop then stops expansion, preserving text already read.
        mutating func next(_ document: LaTeXDocument) -> Bool {
            guard iterations < 10_000 else {
                document.stopsExpanding = true
                return false
            }
            iterations += 1
            return document.reserveExpansion(characters: cost)
        }
    }

    /// \forloop steps the document counter itself, so changes made by the body carry into the next test.
    private func counterLoop() {
        let step = Int(optional() ?? "1") ?? 1
        let counter = argument() ?? ""
        let initial = Int(inline(argument() ?? ""))
        let test = argument() ?? ""
        let body = argument() ?? ""
        guard let initial else { return }
        document.counters[counter] = initial
        var quota = LoopQuota(test, body)
        while !document.stopsExpanding && condition(test) && quota.next(document) {
            readExpansionBody(body)
            document.counters.add(step, to: counter)
        }
    }

    /// In plain TeX \repeat closes the loop's test, so its opening conditional has no matching \fi in the body.
    private func primitiveLoop() {
        let start = index
        var nestedLoops = 0
        // Fully closed conditionals belong to the body. The unmatched conditional separates the part that
        // always runs from the part that runs only when another iteration follows.
        var unmatched: [(start: Int, name: String, after: Int)] = []
        var declared: Set<String> = []
        while let word = nextStructuralWord(declared: &declared) {
            if word.name == "loop" {
                nestedLoops += 1
            } else if word.name == "repeat" {
                if nestedLoops > 0 {
                    nestedLoops -= 1
                } else {
                    guard let test = unmatched.first else { return }
                    let before = String(characters[start..<test.start])
                    let after = String(characters[test.after..<word.start])
                    skipSpacesAfterControlWord()
                    var quota = LoopQuota(before, after)
                    while quota.next(document) {
                        readExpansionBody(before)
                        let reader = LaTeXReader(after, document: document, isBlock: false)
                        reader.skipSpacesAfterControlWord()
                        guard !document.stopsExpanding, reader.primitiveTest(test.name) else { break }
                        readExpansionBody(reader.rest)
                    }
                    return
                }
            } else if nestedLoops == 0 {
                if isConditionalPrimitive(word.name) || declared.contains(word.name) {
                    unmatched.append((word.start, word.name, word.after))
                } else if word.name == "fi", !unmatched.isEmpty {
                    unmatched.removeLast()
                }
            }
        }
    }

    /// Bind each tuple just for its iteration so an inner loop can reuse an outer variable name.
    private func foreachLoop() {
        var variables: [String] = []
        repeat {
            skipSpaces()
            let token = controlToken()
            guard token.count > 1 else { return }
            variables.append(String(token.dropFirst()))
            skipSpaces()
            if peek() != "/" { break }
            index += 1
        } while peek() != nil
        guard peek() == "i", peek(1) == "n" else { return }
        index += 2
        let list = argument() ?? ""
        let body = argument() ?? ""
        let entries = Self.splitList(list, separator: ",")
        var quota = LoopQuota(body, variables.joined())
        let saved = variables.map { document.macros[$0] }
        let outer = document.loopMathNames
        document.loopMathNames.formUnion(variables)
        defer {
            document.loopMathNames = outer
            for (key, value) in zip(variables, saved) { document.macros[key] = value }
        }
        func visit(_ entry: String) -> Bool {
            guard quota.next(document) else { return false }
            let values = variables.count == 1 ? [entry] : Self.splitList(entry, separator: "/")
            for (position, key) in variables.enumerated() {
                let value = values.indices.contains(position) ? values[position] : values.last ?? ""
                document.macros[key] = .init(parameters: 0, defaultArgument: nil, body: value)
            }
            readExpansionBody(body)
            return !document.stopsExpanding
        }
        var position = 0
        while position < entries.count {
            let entry = entries[position]
            if entry == "...", position > 0, position + 1 < entries.count,
                let last = Self.decimal(entries[position - 1]), let end = Self.decimal(entries[position + 1])
            {
                var step: Decimal = last <= end ? 1 : -1
                if position >= 2, let previous = Self.decimal(entries[position - 2]) { step = last - previous }
                var current = last
                // Generate one value at a time. Decimal steps keep 0.1,...,0.3 from missing the last entry.
                while !step.isNaN && step != 0 {
                    let next = current + step
                    guard !next.isNaN, next != current, step > 0 ? next <= end : next >= end else { break }
                    guard visit(NSDecimalNumber(decimal: next).stringValue) else { return }
                    current = next
                }
                position += 2
            } else {
                guard visit(entry) else { return }
                position += 1
            }
        }
    }

    /// Snapshot only the iteration's local meanings. A formula with a forward reference can be drawn after
    /// its loop has finished; copying the document's entire static preamble for every iteration would be wasteful.
    func mathWithLoopVariables(_ latex: String) -> String? {
        guard !document.loopMathNames.isEmpty, latex.contains("\\") else { return latex }
        var definitions = ""
        for name in document.loopMathNames.sorted() {
            guard let macro = document.macros[name], macro.specification.isEmpty, macro.primitive == nil else {
                continue
            }
            guard document.reserveExpansion(characters: name.count + macro.body.count + 7) else { return nil }
            definitions += "\\def\\\(name){\(macro.body)}"
        }
        return definitions + latex
    }

    /// Accept only a full decimal entry within Decimal's 38-digit precision for a range endpoint.
    private static func decimal(_ source: String) -> Decimal? {
        // Foundation accepts a numeric prefix followed by text. Such an entry remains a list item.
        let digits = source.drop(while: { $0 == "+" || $0 == "-" })
        guard digits.utf8.count <= 38, !digits.isEmpty, digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
            digits.filter({ $0 == "." }).count <= 1
        else { return nil }
        return Decimal(string: source, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Braces and escapes protect commas and slashes that belong to a value rather than separating values.
    private static func splitList(_ source: String, separator: Character) -> [String] {
        var result: [String] = []
        var start = source.startIndex
        var depth = 0
        var escaped = false
        for index in source.indices {
            let ch = source[index]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth = max(0, depth - 1)
            } else if ch == separator, depth == 0 {
                result.append(source[start..<index].trimmingCharacters(in: .whitespacesAndNewlines))
                start = source.index(after: index)
            }
        }
        result.append(source[start...].trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }

    /// Bind all variables before reading the body so each has its value for the same iteration.
    private func multidoLoop() {
        let specification = argument() ?? ""
        let count = Int(inline(argument() ?? "")) ?? 0
        let body = argument() ?? ""
        var variables: [(name: String, value: Int, step: Int)] = []
        for assignment in Self.splitList(specification, separator: ",") {
            let pair = assignment.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].first == "\\" else { return }
            let terms = pair[1].split(separator: "+", maxSplits: 1)
            guard terms.count == 2, let initial = Int(terms[0]), let step = Int(terms[1]) else { return }
            variables.append((String(pair[0].dropFirst()), initial, step))
        }
        let saved = variables.map { document.macros[$0.name] }
        let outer = document.loopMathNames
        document.loopMathNames.formUnion(variables.map(\.name))
        defer {
            document.loopMathNames = outer
            for (variable, value) in zip(variables, saved) { document.macros[variable.name] = value }
        }
        var quota = LoopQuota(body, specification)
        for _ in 0..<max(0, count) {
            guard quota.next(document) else { break }
            for variable in variables {
                document.macros[variable.name] = .init(
                    parameters: 0, defaultArgument: nil, body: String(variable.value))
            }
            readExpansionBody(body)
            for position in variables.indices {
                let next = variables[position].value.addingReportingOverflow(variables[position].step)
                if next.overflow { return }
                variables[position].value = next.partialValue
            }
        }
    }
}

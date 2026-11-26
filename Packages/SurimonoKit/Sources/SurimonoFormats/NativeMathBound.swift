/// A conservative proof for primitive definitions with literal delimiters or a redefined symbol.
/// All control sequences in the expression and replacements must be in this closed table. An argument
/// may contain nullary calls; only one argument-taking call may appear, and only in the original input.
enum NativeMathBound {
    private struct Macro {
        var parameters = 0
        var copies = Array(repeating: 0, count: 9)
        var bytes = 0
        var calls: [String] = []
    }

    private static func literal(_ token: String) -> Bool {
        token.utf8.count == 1
            && token.first.map { $0.isASCII && ($0.isLetter || $0.isNumber || " +-=/().,;:[]{}_^".contains($0)) }
                == true
    }

    static func accepts(_ formula: String, definitions: String) -> Bool {
        let limit = PreviewMathExpansion.maximumBytes
        guard !definitions.isEmpty, definitions.utf8.count <= limit,
            formula.utf8.count <= limit - definitions.utf8.count,
            let preamble = try? PreviewMathExpansion.tokens(definitions, limit: limit),
            let expression = try? PreviewMathExpansion.tokens(formula, limit: limit)
        else { return false }
        if preamble.first != "\\def" {
            return boundedRawSignature(
                preamble, expression: expression, bytes: definitions.utf8.count + formula.utf8.count)
        }
        var tokens = preamble[...]
        var macros: [String: Macro] = [:]
        while let command = tokens.popFirst() {
            if command == " " { continue }
            guard command == #"\def"#, let name = tokens.popFirst(),
                PreviewMathExpansion.controlWord(name) || name == #"\!"#,
                PreviewMathExpansion.permitted(name), macros[name] == nil
            else { return false }
            var macro = Macro()
            while let token = tokens.first, token != "{" {
                tokens.removeFirst()
                if token == "#" {
                    macro.parameters += 1
                    guard macro.parameters <= 9, tokens.popFirst() == String(macro.parameters) else { return false }
                } else if !literal(token) || token == "}" {
                    return false
                }
            }
            guard tokens.popFirst() == "{" else { return false }
            var depth = 1
            while depth > 0 {
                guard let token = tokens.popFirst() else { return false }
                if token == "}" { depth -= 1 }
                if depth == 0 { break }
                if token == "{" { depth += 1 }
                macro.bytes += token.utf8.count
                if token == "#" {
                    guard let digit = tokens.popFirst(), let i = Int(digit), i > 0, i <= macro.parameters else {
                        return false
                    }
                    macro.bytes += digit.utf8.count
                    macro.copies[i - 1] += 1
                } else if token.hasPrefix("\\") {
                    macro.calls.append(token)
                } else if !literal(token) {
                    return false
                }
            }
            macros[name] = macro
        }

        // Charge both the stored replacement and everything scheduled by its descendants. Count a call
        // even for an empty body. Keep the native parser within its own 1,000-call ceiling.
        let maximumCalls = 1_000
        var calls = 0
        var cost = definitions.utf8.count + formula.utf8.count
        var visiting: Set<String> = []
        func charge(_ name: String) -> Bool {
            guard let macro = macros[name], visiting.count < PreviewMathExpansion.maximumDepth,
                visiting.insert(name).inserted
            else { return false }
            defer { visiting.remove(name) }
            calls += 1
            cost += macro.bytes
            guard calls <= maximumCalls, cost <= limit else { return false }
            for child in macro.calls {
                guard macros[child]?.parameters == 0, charge(child) else { return false }
            }
            return true
        }
        var callWithArguments: Macro?
        for token in expression {
            if literal(token) { continue }
            guard let macro = macros[token], charge(token) else { return false }
            if macro.parameters > 0 {
                guard callWithArguments == nil else { return false }
                callWithArguments = macro
            }
        }
        if let macro = callWithArguments {
            // Any argument costs at most the entire charged expression, including every nullary call
            // in it. Each occurrence can duplicate all that work. Check by division before multiplying.
            let copies = macro.copies.reduce(0, +)
            guard cost <= limit / (1 + copies), calls <= maximumCalls / (1 + copies) else { return false }
        }
        return cost <= limit
    }

    /// In 0.6.0 handleNewcommand consumes a single token as its body if it is not braced. For a
    /// default argument that token is "["; no argument is ever copied. For a star it assigns to
    /// "*" and consumes the braced name as its body. No following token here can invoke that star.
    /// Restrict the remaining stream to literal math and primitive font/accent commands: it must
    /// not introduce another assignment or synthesize additional calls.
    private static func boundedRawSignature(_ preamble: [String], expression: [String], bytes: Int) -> Bool {
        var input = preamble[...]
        guard let kind = input.popFirst(), [#"\newcommand"#, #"\renewcommand"#, #"\providecommand"#].contains(kind)
        else { return false }
        let starred = input.first == "*"
        if starred { input.removeFirst() }
        guard input.popFirst() == "{", let name = input.popFirst(), PreviewMathExpansion.controlWord(name),
            PreviewMathExpansion.permitted(name), input.popFirst() == "}"
        else { return false }
        let primitives: Set<String> = [#"\mathbb"#, #"\mathbf"#, #"\mathrm"#, #"\vec"#, #"\epsilon"#]
        if !starred {
            guard !primitives.contains(name), input.popFirst() == "[", let digit = input.popFirst(),
                digit.utf8.count == 1, let count = Int(digit), (1...9).contains(count),
                input.popFirst() == "]", input.popFirst() == "["
            else { return false }
        }
        var calls = 0
        for tokens in [input, expression[...]] {
            for token in tokens {
                if !starred && token == name {
                    calls += 1
                } else if !literal(token) && token != "#" && !primitives.contains(token) {
                    return false
                }
            }
        }
        return calls < 1_000 && calls <= PreviewMathExpansion.maximumBytes - bytes
    }
}

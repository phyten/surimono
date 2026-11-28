import SwaTex
import Synchronization

/// Bound the entire token stream without building replacements or estimating sizes from parsed arguments.
enum NativeMathBound {
    struct Bound {
        var bytes = 0
        var work = 0
        var steps = 0
    }

    private struct Macro {
        var body: [String]
        var uses: [Int]
        var unavailable = false
        var ordinaryArguments: Bool
    }

    private static let limit = PreviewMathExpansion.maximumBytes
    private static let infinity = PreviewMathExpansion.maximumWork + 1

    private static func add(_ a: Int, _ b: Int) -> Int { min(infinity, a + b) }
    private static func multiply(_ a: Int, _ b: Int) -> Int {
        a > infinity / max(1, b) ? infinity : a * b
    }

    private struct Potential {
        var bytes = 0
        var steps = 0
        var transfers = 0
        // Stop at the first duplicating call on each branch. Linear calls cannot copy this frontier.
        var firstDuplicator: String?
        var ambiguous = false
        var depth = 0
        mutating func include(_ other: Self) {
            bytes = add(bytes, other.bytes)
            steps = add(steps, other.steps)
            transfers = add(transfers, other.transfers)
            depth = max(depth, other.depth)
            ambiguous = ambiguous || other.ambiguous || (firstDuplicator != nil && other.firstDuplicator != nil)
            firstDuplicator = firstDuplicator ?? other.firstDuplicator
        }
    }

    static func accepts(_ formula: String, definitions: String) -> Bool {
        bound(formula, definitions: definitions) != nil
    }

    /// For a conversion report only: the first token of the formula, or of a definition it uses, that the bound has
    /// no cost for. Nil when there is none, or when the definitions themselves cannot be read.
    static func firstUnknownToken(_ formula: String, definitions: String) -> String? {
        let bytes = add(min(infinity, definitions.utf8.count), min(infinity, formula.utf8.count))
        guard bytes <= PreviewMathExpansion.maximumWork else { return nil }
        var lexer = Lexer(definitions + formula)
        let boundary = definitions.utf8.count
        var preamble: [String] = []
        var expression: [String] = []
        while true {
            let token = lexer.lex()
            if token.isEOF { break }
            if token.loc.start >= boundary { expression.append(token.text) } else { preamble.append(token.text) }
        }
        var declarations = Declarations(tokens: preamble[...])
        let macros = declarations.read() ?? [:]
        var visited = Set<String>()
        func first(_ tokens: [String]) -> String? {
            for token in tokens where token != "\\begin" && token != "\\end" {
                if let macro = macros[token] {
                    if macro.unavailable { return token }
                    if visited.insert(token).inserted, let inner = first(macro.body) { return inner }
                } else if native(token) == nil {
                    return token
                }
            }
            return nil
        }
        return first(expression)
    }

    static func bound(_ formula: String, definitions: String) -> Bound? {
        let bytes = add(min(infinity, definitions.utf8.count), min(infinity, formula.utf8.count))
        guard bytes <= PreviewMathExpansion.maximumWork, formula.utf8.count <= limit else { return nil }
        // Use the same lexical stream as SwaTex. A final comment in a header can swallow part
        // of the first line of math; a control word could also straddle the supplied boundary.
        var lexer = Lexer(definitions + formula)
        let boundary = definitions.utf8.count
        var preamble: [String] = []
        var expression: [String] = []
        while true {
            let token = lexer.lex()
            if token.isEOF { break }
            if token.loc.start >= boundary {
                expression.append(token.text)
            } else {
                guard token.loc.end <= boundary else { return nil }
                preamble.append(token.text)
            }
        }
        if let bound = boundedRawSignature(preamble, expression: expression, bytes: bytes) { return bound }
        var declarations = Declarations(tokens: preamble[...])
        guard let macros = declarations.read() else { return nil }
        var cache: [String: Potential] = [:]
        var children: [String: Potential] = [:]
        var active = Set<String>()
        func potential(_ tokens: [String]) -> Potential? {
            var result = Potential()
            for (index, token) in tokens.enumerated() {
                if token == "\\begin" || token == "\\end" {
                    guard tokens.dropFirst(index + 1).first == "{",
                        let close = tokens[(index + 1)...].prefix(12).firstIndex(of: "}"),
                        close - index <= 12,
                        [
                            "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "aligned", "gathered",
                            "cases",
                        ].contains(tokens[(index + 2)..<close].joined())
                    else { return nil }
                }
                result.bytes = add(result.bytes, token.utf8.count)
                guard let macro = macros[token] else {
                    guard let node = native(token) else { return nil }
                    result.include(node)
                    continue
                }
                guard !macro.unavailable else { return nil }
                if let known = cache[token] {
                    result.include(known)
                    continue
                }
                guard StackSpace.hasRoom, active.count < PreviewMathExpansion.maximumDepth,
                    active.insert(token).inserted,
                    var child = potential(macro.body)
                else { return nil }
                active.remove(token)
                children[token] = child
                child.depth += 1
                child.steps = add(child.steps, 1)
                if !macro.uses.isEmpty { child.transfers = add(child.transfers, 1) }
                if (macro.uses.max() ?? 0) > 1 {
                    child.firstDuplicator = token
                    child.ambiguous = false
                }
                cache[token] = child
                result.include(child)
            }
            return result
        }
        guard let root = potential(expression), root.depth <= PreviewMathExpansion.maximumDepth else { return nil }
        var frontier = root
        var factor = 1
        while !frontier.ambiguous, let name = frontier.firstDuplicator, let macro = macros[name],
            let next = children[name]
        {
            // All remaining argument slices are disjoint. Charge the largest use count against the
            // WHOLE stream. No other live duplicator can be among those arguments; the next ones
            // can only come from this call's literal body. The call graph is acyclic.
            factor = multiply(factor, macro.uses.max() ?? 1)
            frontier = next
        }
        var transfers = multiply(root.transfers, factor)
        if frontier.ambiguous {
            // With two live duplicators one might copy the other. A second certificate is
            // possible for closed, explicitly grouped arithmetic; otherwise do not guess.
            guard let closed = closedFactor(expression, macros: macros) else { return nil }
            factor = closed
            transfers = root.transfers
        }
        let output = multiply(root.bytes, factor)
        let calls = add(declarations.assignments, multiply(root.steps, factor))
        let work = add(bytes, multiply(output, add(1, transfers)))
        guard output <= limit, work <= PreviewMathExpansion.maximumWork, calls < 1_000 else { return nil }
        return Bound(bytes: output, work: work, steps: calls)
    }

    /// A closed term is an atom, a parameter, a braced sequence, or a user call with all of its
    /// ordinary arguments present as literal groups. Substitution preserves this grammar. No
    /// native argument reader, delimiter, or trailing command can move a token to a sibling.
    /// This proves only independence and the maximum copy factor along a token lineage. Its
    /// argument byte charge is still the potential of the WHOLE formula, never a parsed slice.
    private static func closedFactor(_ expression: [String], macros: [String: Macro]) -> Int? {
        var cache: [String: Int] = [:]
        func sequence(_ input: inout ArraySlice<String>, group: Bool, depth: Int) -> Int? {
            guard StackSpace.hasRoom, depth <= PreviewMathExpansion.maximumDepth else { return nil }
            var maximum = 1
            while let token = input.popFirst() {
                if token == "}" { return group ? maximum : nil }
                if token == "{" {
                    guard let inner = sequence(&input, group: true, depth: depth + 1) else { return nil }
                    maximum = max(maximum, inner)
                } else if let macro = macros[token] {
                    guard macro.ordinaryArguments else { return nil }
                    var bodyCost = cache[token]
                    if bodyCost == nil {
                        var body = macro.body[...]
                        bodyCost = sequence(&body, group: false, depth: depth + 1)
                        cache[token] = bodyCost
                    }
                    guard let bodyCost else { return nil }
                    var argumentCost = 1
                    for _ in macro.uses {
                        while input.first == " " { input.removeFirst() }
                        guard input.popFirst() == "{", let inner = sequence(&input, group: true, depth: depth + 1)
                        else { return nil }
                        argumentCost = max(argumentCost, inner)
                    }
                    let copies = max(1, macro.uses.max() ?? 0)
                    maximum = max(maximum, multiply(multiply(copies, bodyCost), argumentCost))
                } else if token == "#" {
                    // Parameter validity has already been checked in Declarations.
                    guard let digit = input.popFirst(), Int(digit) != nil else { return nil }
                } else if !literal(token) || token == "^" || token == "_" {
                    return nil
                }
            }
            return group ? nil : maximum
        }
        var input = expression[...]
        return sequence(&input, group: false, depth: 0)
    }

    // Pinned parser actions which do not generate control sequences or duplicate an argument.
    // Unknown commands, active characters, dynamic assignment and re-lexing are not leaves.
    private static let paperNotation: Set<String> = [
        #"\R"#, #"\N"#, #"\C"#, #"\vec"#, #"\epsilon"#, #"\bra"#, #"\ket"#, #"\square"#, #"\argmin"#, #"\argmax"#,
        #"\!"#,
    ]
    private static let atoms = Set(
        #"alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta iota kappa lambda mu nu xi pi rho sigma tau upsilon phi varphi chi psi omega Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega S P in cap cup subset subseteq supset supseteq infty lfloor rfloor lceil rceil lVert rVert lvert rvert langle rangle nabla partial mid vert Vert sim approx equiv le ge leq geq to times cdot pm mp sum prod int iint iiint oint det dim exp lim log ln max min sin cos tan gcd sup inf rm limits nolimits "#
            .split(separator: " ").map { "\\" + $0 })
    static func ordinarySymbol(_ name: String) -> Bool {
        (atoms.contains(name) && SymbolInfo(name: name, mode: .math) != nil) || symbolLeaf(name)
    }

    private static let leaves = Mutex<[String: Bool]>([:])

    /// Any control word in SwaTex's math symbol table that is neither a macro nor a function: the parser reads
    /// exactly this one token and makes one symbol node of it. It copies nothing and reads no argument, so it
    /// costs only its own bytes. Deciding this from the pinned parser, not from a list, keeps a symbol that a
    /// list forgot from refusing every formula in a document with a single definition.
    private static func symbolLeaf(_ name: String) -> Bool {
        guard PreviewMathExpansion.controlWord(name), PreviewMathExpansion.permitted(name),
            SymbolInfo(name: name, mode: .math) != nil
        else { return false }
        if let known = leaves.withLock({ $0[name] }) { return known }
        // noexpand turns an expandable builtin into relax. A one-token parse tells a function, which
        // takes precedence over the symbol table, from a symbol.
        let leaf =
            (try? Parser("\\noexpand" + name).fetch().text) == name
            && (try? Parser(name).parse()).map { $0.count == 1 && $0[0].isSymbolNode } == true
        leaves.withLock { $0[name] = leaf }
        return leaf
    }

    private static let groups = Set(
        #"frac dfrac tfrac sqrt mathbb mathbf mathcal mathrm mathsf mathit mathtt mathfrak boldsymbol left right middle vec hat bar tilde overline underline text textrm textbf textit textsf texttt begin end color textcolor mathord mathop mathrel mathbin mathopen mathclose mathinner operatornamewithlimits"#
            .split(separator: " ").map { "\\" + $0 })

    private static func literal(_ token: String) -> Bool {
        token.utf8.count == 1
            && token.first.map { $0.isASCII && ($0.isLetter || $0.isNumber || " +-=/().,;:[]{}_^".contains($0)) }
                == true
    }

    private static func native(_ token: String) -> Potential? {
        if atoms.contains(token) { return Potential() }
        if groups.contains(token) { return Potential(transfers: 3) }
        if token.utf8.count == 1, token != "~", token != "\\", token != "%" { return Potential() }
        switch token {
        case #"\$"#, #"\{"#, #"\}"#, #"\%"#, #"\_"#, #"\|"#, #"\ "#, #"\\"#: return Potential(transfers: 1)
        // Each constant includes all literal descendants and argument-forwarding steps, in either mode.
        case #"\,"#, #"\;"#, #"\:"#, #"\!"#, #"\dotsc"#, #"\dotsx"#, #"\operatorname"#:
            return Potential(bytes: 96, steps: 5, transfers: 4)
        case #"\quad"#, #"\qquad"#, #"\boxed"#, #"\TextOrMath"#, #"\R"#, #"\N"#, #"\bra"#, #"\ket"#, #"\dots"#,
            #"\cdots"#, #"\dotsb"#, #"\dotsm"#, #"\dotso"#:
            return Potential(bytes: 48, steps: 2, transfers: 3)
        // ne reaches neq, html@mathml, not and two short char codes: 137 bytes and 5 expansions in 0.6.0.
        case #"\argmin"#, #"\argmax"#, #"\ne"#, #"\neq"#, #"\not"#:
            return Potential(bytes: 192, steps: 12, transfers: 6)
        case #"\char"#: return Potential(bytes: 320, steps: 1, transfers: 2)
        default: return symbolLeaf(token) ? Potential() : nil
        }
    }

    // Names reached without a matching source token by the admitted native helpers. In particular
    // array environments inspect arraystretch and locally assign cr. Do not let a document change
    // the meaning of a helper hidden inside a fixed native cost.
    static let implicitCalls: [String: [String]] = {
        var calls = [
            #"\begin"#: [#"\arraystretch"#, #"\cr"#], #"\cr"#: [#"\\"#, #"\relax"#],
            #"\dotsc"#: [#"\ldots"#, #"\,"#], #"\char"#: [#"\@char"#],
            #"\operatorname"#: [#"\@ifstar"#, #"\operatornamewithlimits"#, #"\operatorname@"#],
            #"\boxed"#: [#"\fbox"#, #"\displaystyle"#], #"\DOTSB"#: [#"\relax"#],
            #"\bra"#: [#"\mathinner"#, #"\langle"#], #"\ket"#: [#"\mathinner"#, #"\rangle"#],
            #"\dotsx"#: [#"\ldots"#, #"\,"#], #"\dotso"#: [#"\ldots"#],
            #"\ne"#: [#"\neq"#], #"\neq"#: [#"\mathrel"#, #"\not"#, #"\char"#],
            #"\not"#: [#"\mathrel"#, #"\mathrlap"#, #"\nobreak"#, #"\char"#],
        ]
        for name in [#"\dots"#, #"\dotsb"#, #"\dotsm"#] { calls[name] = [#"\cdots"#] }
        for name in [#"\R"#, #"\N"#] { calls[name] = [#"\mathbb"#] }
        for name in [#"\quad"#, #"\qquad"#] { calls[name] = [#"\hskip"#, #"\relax"#] }
        for name in [#"\,"#, #"\;"#, #"\:"#, #"\!"#] { calls[name] = [#"\TextOrMath"#, #"\kern"#, #"\mskip"#] }
        for name in [#"\argmin"#, #"\argmax"#] { calls[name] = [#"\DOTSB"#, #"\operatorname"#, #"\,"#] }
        return calls
    }()
    static let implicitNames = Set(implicitCalls.values.joined())

    static func mayDeclare(_ name: String) -> Bool {
        (PreviewMathExpansion.controlWord(name) || name == #"\!"#) && PreviewMathExpansion.permitted(name)
            && !implicitNames.contains(name) && !AppMathInput.conditional(name)
            && (paperNotation.contains(name) || (!PreviewMathMacro.isBuiltin(name) && native(name) == nil))
    }

    private struct Declarations {
        var tokens: ArraySlice<String>
        var assignments = 0

        mutating func read() -> [String: Macro]? {
            var macros: [String: Macro] = [:]
            while let kind = tokens.popFirst() {
                if kind == " " { continue }
                if kind == #"\let"# {
                    guard let name = tokens.popFirst(), mayDeclare(name) else { return nil }
                    while tokens.first == " " { tokens.removeFirst() }
                    if tokens.first == "=" {
                        tokens.removeFirst()
                        // handleLet skips exactly one token here. Comments can separate two space tokens.
                        if tokens.first == " " { tokens.removeFirst() }
                    }
                    guard let source = tokens.popFirst(), PreviewMathExpansion.controlWord(source),
                        PreviewMathExpansion.permitted(source)
                    else { return nil }
                    // A simple let only saves a meaning. Its use (including from another body)
                    // has no static summary, but an unused binding does not stop later formulas.
                    macros[name] = Macro(body: [], uses: [], unavailable: true, ordinaryArguments: false)
                    continue
                }
                let primitive = kind == #"\def"#
                let op = kind == #"\DeclareMathOperator"#
                guard primitive || op || [#"\newcommand"#, #"\renewcommand"#, #"\providecommand"#].contains(kind) else {
                    return nil
                }
                let star = op && tokens.first == "*"
                if star { tokens.removeFirst() }
                let braced = !primitive && tokens.first == "{"
                if braced { tokens.removeFirst() }
                guard let name = tokens.popFirst(), mayDeclare(name),
                    !braced || tokens.popFirst() == "}"
                else { return nil }
                var count = 0
                var ordinaryArguments = true
                if !primitive { while tokens.first == " " { tokens.removeFirst() } }
                if primitive {
                    while let token = tokens.first, token != "{" {
                        tokens.removeFirst()
                        if token == "#" {
                            count += 1
                            guard count <= 9, tokens.popFirst() == String(count) else { return nil }
                        } else {
                            guard literal(token), token != "}" else { return nil }
                            ordinaryArguments = false
                        }
                    }
                } else if !op, tokens.first == "[" {
                    tokens.removeFirst()
                    guard let digit = tokens.popFirst(), digit.utf8.count == 1, let n = Int(digit), (0...9).contains(n),
                        tokens.popFirst() == "]"
                    else { return nil }
                    count = n
                }
                while tokens.first == " " { tokens.removeFirst() }
                guard tokens.popFirst() == "{" else { return nil }
                var depth = 1
                var body: [String] = []
                var uses = Array(repeating: 0, count: count)
                while let token = tokens.popFirst() {
                    if token == "}" { depth -= 1 }
                    if depth == 0 { break }
                    if token == "{" { depth += 1 }
                    if token == "#" {
                        guard let digit = tokens.popFirst(), digit.utf8.count == 1,
                            let n = Int(digit), (1...9).contains(n), n <= count
                        else { return nil }
                        uses[n - 1] += 1
                        // Account for both stored parameter-marker tokens, even before substitution.
                        body += ["#", digit]
                    } else {
                        body.append(token)
                    }
                }
                guard depth == 0 else { return nil }
                if op { body = [#"\operatorname"#] + (star ? ["*"] : []) + ["{"] + body + ["}"] }
                macros[name] = Macro(body: body, uses: uses, ordinaryArguments: ordinaryArguments)
                if !primitive { assignments += 1 }
            }
            return macros
        }
    }

    /// Re-audit handleNewcommand and its lexer on every SwaTex upgrade.
    /// In 0.6.0 handleNewcommand consumes a single token as its body if it is not braced. For a
    /// default argument that token is "["; no argument is ever copied. For a star it assigns to
    /// "*" and consumes the braced name as its body. No following token here can invoke that star.
    /// Restrict the remaining stream to literal math and primitive font/accent commands: it must
    /// not introduce another assignment or synthesize additional calls.
    private static func boundedRawSignature(_ preamble: [String], expression: [String], bytes: Int) -> Bound? {
        var input = preamble[...]
        guard let kind = input.popFirst(), [#"\newcommand"#, #"\renewcommand"#, #"\providecommand"#].contains(kind)
        else { return nil }
        let starred = input.first == "*"
        if starred { input.removeFirst() }
        guard input.popFirst() == "{", let name = input.popFirst(), PreviewMathExpansion.controlWord(name),
            PreviewMathExpansion.permitted(name), input.popFirst() == "}"
        else { return nil }
        let primitives: Set<String> = [#"\mathbb"#, #"\mathbf"#, #"\mathrm"#, #"\vec"#, #"\epsilon"#]
        if !starred {
            guard !primitives.contains(name), input.popFirst() == "[", let digit = input.popFirst(),
                digit.utf8.count == 1, let count = Int(digit), (1...9).contains(count),
                input.popFirst() == "]", input.popFirst() == "["
            else { return nil }
        }
        var calls = 0
        var scans = 0
        for tokens in [input, expression[...]] {
            for token in tokens {
                if !starred && token == name {
                    calls += 1
                } else if primitives.contains(token) {
                    scans += 1
                } else if !literal(token) && token != "#" {
                    return nil
                }
            }
        }
        let output = add(bytes, calls)
        let work = multiply(output, 2 + scans + calls)
        guard calls + 1 < 1_000, output <= limit, work <= PreviewMathExpansion.maximumWork else { return nil }
        return Bound(bytes: output, work: work, steps: calls + 1)
    }
}

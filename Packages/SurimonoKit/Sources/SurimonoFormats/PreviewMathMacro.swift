import SwaTex

/// Parse only the selected, size-checked declarations. Unused document definitions never reach this table.
struct PreviewMathMacro {
    enum Part {
        case literal(String)
        case argument(Int)
    }
    let parameters: Int
    let defaultArgument: ArraySlice<String>?
    let body: [Part]

    private typealias Refusal = PreviewMathExpansion.Refusal

    static func read(_ source: String, app: Bool = false) throws -> [String: Self] {
        var input = try PreviewMathExpansion.tokens(
            source, limit: app ? PreviewMathExpansion.maximumBytes : PreviewConversion.maximumFormulaBytes)[...]
        var macros: [String: Self] = [:]
        while let kind = input.popFirst() {
            if kind == " " { continue }
            guard
                ["\\def", "\\newcommand", "\\renewcommand", "\\providecommand", "\\DeclareMathOperator"].contains(kind)
            else { throw Refusal.unsupported }
            let starred = kind != "\\def" && input.take("*")
            // The app's LaTeX reader normalizes starred commands and consumes optional defaults.
            // Raw SwaTex 0.6.0 interprets those signatures differently from LaTeX.
            if app && starred && kind != "\\DeclareMathOperator" { throw Refusal.unsupported }
            input.skipSpaces()
            let name: String
            if kind != "\\def", input.first == "{" {
                let group = try input.group()
                guard group.count == 1, let word = group.first else { throw Refusal.unsupported }
                name = word
            } else {
                guard let word = input.popFirst() else { throw Refusal.unsupported }
                name = word
            }
            guard PreviewMathExpansion.controlWord(name), PreviewMathExpansion.permitted(name) else {
                throw Refusal.unsupported
            }
            var count = 0
            var optional: ArraySlice<String>?
            input.skipSpaces()
            if kind == "\\def" {
                while input.take("#") {
                    count += 1
                    guard count <= 9, input.take(String(count)) else { throw Refusal.unsupported }
                }
            } else if kind != "\\DeclareMathOperator", input.first == "[" {
                let digits = try input.group(optional: true)
                guard digits.count == 1, let digit = digits.first, let number = Int(digit), (0...9).contains(number)
                else { throw Refusal.unsupported }
                count = number
                input.skipSpaces()
                if count > 0, input.first == "[" {
                    if app { throw Refusal.unsupported }
                    optional = try input.group(optional: true)
                    guard optional?.allSatisfy(PreviewMathExpansion.permitted) == true else {
                        throw Refusal.unsupported
                    }
                }
            }
            input.skipSpaces()
            var replacement = try input.group()
            // R and argmax already exist in SwaTex 0.6.0. Accept only these literal paper conventions.
            let standardR =
                kind != "\\DeclareMathOperator" && name == "\\R" && count == 0
                && replacement.elementsEqual(["\\mathbb", "{", "R", "}"])
            let operatorText = ["a", "r", "g", "\\,", "m", "a", "x"]
            let standardOperator =
                kind == "\\DeclareMathOperator" && name == "\\argmax"
                && (replacement.elementsEqual(operatorText)
                    || replacement.elementsEqual(["\\mathrm", "{"] + operatorText + ["}"]))
            let builtin = isBuiltin(name)
            if !app, kind == "\\providecommand", builtin || macros[name] != nil { continue }
            // The app reader lowers DeclareMathOperator to this primitive declaration.
            let normalizedOperator =
                app && kind == "\\def" && name == "\\argmax" && count == 0
                && replacement.elementsEqual(["\\operatorname", "{", "\\mathrm", "{"] + operatorText + ["}", "}"])
            // These notation commands can be replaced in the app's bounded token stack. The
            // resulting parser starts with no user definitions, including for these builtin names.
            let paperNotation = app && Self.paperNotation.contains(name) && kind != "\\newcommand"
            if builtin && !standardR && !standardOperator && !normalizedOperator && !paperNotation {
                throw Refusal.unsupported
            }
            if kind == "\\renewcommand", !builtin, macros[name] == nil { throw Refusal.unsupported }
            var body: [Part] = []
            if kind == "\\DeclareMathOperator" {
                body.append(.literal("\\operatorname"))
                if starred { body.append(.literal("*")) }
                body.append(.literal("{"))
            }
            while let token = replacement.popFirst() {
                if token == "#" {
                    guard let digit = replacement.popFirst(), let n = Int(digit), n > 0, n <= count else {
                        throw Refusal.unsupported
                    }
                    body.append(.argument(n - 1))
                } else {
                    guard PreviewMathExpansion.permitted(token) else { throw Refusal.unsupported }
                    body.append(.literal(token))
                }
            }
            if kind == "\\DeclareMathOperator" { body.append(.literal("}")) }
            macros[name] = Self(parameters: count, defaultArgument: optional, body: body)
        }
        return macros
    }

    private static let paperNotation: Set<String> = [
        #"\R"#, #"\N"#, #"\C"#, #"\vec"#, #"\epsilon"#, #"\bra"#, #"\ket"#, #"\square"#, #"\argmin"#, #"\argmax"#,
    ]

    /// SwaTex has no public name lookup. Its noexpand lookup returns relax for any expandable builtin;
    /// it receives just one validated control word, with no user arguments or replacement text.
    private static func isBuiltin(_ name: String) -> Bool {
        if SymbolInfo(name: name, mode: .math) != nil || SymbolInfo(name: name, mode: .text) != nil { return true }
        if (try? Parser("\\noexpand" + name).fetch().text) != name { return true }
        // The non-expandable primitives and implicit control words in the pinned parser's function registry.
        return [
            "\\relax", "\\limits", "\\nolimits", "\\mathop", "\\tag", "\\hbox", "\\left", "\\right", "\\middle",
            "\\mathchoice", "\\mathord", "\\mathbin", "\\mathrel", "\\mathopen", "\\mathclose", "\\mathpunct",
            "\\mathinner",
            "\\begingroup", "\\endgroup", "\\begin", "\\end",
        ].contains(name)
    }
}

extension ArraySlice where Element == String {
    fileprivate mutating func take(_ token: String) -> Bool {
        guard first == token else { return false }
        removeFirst()
        return true
    }

    fileprivate mutating func skipSpaces() {
        while take(" ") {}
    }

    fileprivate mutating func group(optional: Bool = false) throws -> Self {
        guard take(optional ? "[" : "{") else { throw PreviewMathExpansion.Refusal.unsupported }
        let source = self
        var depth = 0
        while let token = popFirst() {
            if depth == 0 && token == (optional ? "]" : "}") { return source[..<(startIndex - 1)] }
            if token == "{" { depth += 1 }
            if token == "}" { depth -= 1 }
            guard (0...PreviewMathExpansion.maximumDepth).contains(depth) else {
                throw PreviewMathExpansion.Refusal.depth
            }
        }
        throw PreviewMathExpansion.Refusal.unsupported
    }
}

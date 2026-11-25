import SwaTex

/// The print pipeline uses the full validated preamble. Finder indexes individual assignments instead.
struct MathDefinitions {
    var source: String
    var containsOnlyPrimitiveDefinitions = true
    var preview: PreviewMathDefinitions?

    init(source: String = "") {
        self.source = source
        if PreviewConversion.isActive {
            preview = PreviewMathDefinitions()
            if !source.isEmpty { preview?.append(source[...]) }
        }
    }

    func preamble(for formula: String) -> String? {
        if let preview { return preview.preamble(for: formula) }
        return source
    }
}

/// A Finder formula carries only the declarations it can reach, in their original order.
/// The reader copies this value at TeX group boundaries, just like its ordinary math preamble.
struct PreviewMathDefinitions {
    private struct Declaration {
        let source: String?
        let captured: Int?
        let dependencies: Set<String>
    }

    private var declarations: [Declaration] = []
    private var latest: [String: Int] = [:]

    /// One Org header can declare several commands. Walk slices so a large replacement need not be
    /// copied into a character array just to find the next top-level declaration.
    mutating func appendHeader(_ header: String) {
        var cursor = header.startIndex
        var nextCheck = cursor
        var start: String.Index?
        var depth = 0
        while cursor < header.endIndex {
            if cursor >= nextCheck {
                guard !PreviewConversion.expired else { return }
                nextCheck = header.utf8.index(cursor, offsetBy: 4096, limitedBy: header.endIndex) ?? header.endIndex
            }
            let token = cursor
            let character = header[cursor]
            header.formIndex(after: &cursor)
            switch character {
            case "%":
                if let start { append(header[start..<token]) }
                return
            case "{": depth += 1
            case "}": depth = max(0, depth - 1)
            case "\\" where cursor < header.endIndex:
                if depth == 0,
                    header[token...].prefixMatch(of: /\\(?:def|newcommand|renewcommand|providecommand)(?![A-Za-z@])/)
                        != nil
                {
                    if let start { append(header[start..<token]) }
                    start = token
                }
                // An escaped brace, percent or backslash cannot start another token.
                header.formIndex(after: &cursor)
            default: break
            }
        }
        if let start { append(header[start...]) }
    }

    mutating func append(_ source: Substring) {
        let limit = PreviewConversion.maximumFormulaBytes
        // Remember an oversized assignment by name, even when it shadows a built-in command.
        let fits = source.utf8.count <= limit
        let text = fits ? String(source) : String(decoding: source.utf8.prefix(limit), as: UTF8.self)
        var lexer = Lexer(text)
        let command = lexer.lex().text
        var name = lexer.lex().text
        while ["{", "*", " "].contains(name) { name = lexer.lex().text }
        guard name.hasPrefix("\\") else { return }
        if ["\\providecommand", "\\newcommand"].contains(command), latest[name] != nil { return }

        var dependencies: Set<String> = []
        var captured: Int?
        if fits {
            while true {
                let token = lexer.lex()
                if token.isEOF { break }
                guard token.text.hasPrefix("\\") else { continue }
                if command == "\\let" {
                    // A let copies the meaning at the assignment; a def looks up its body's names at use.
                    captured = latest[token.text]
                    break
                }
                dependencies.insert(token.text)
            }
            if command == "\\renewcommand" { captured = latest[name] }
        }
        latest[name] = declarations.count
        declarations.append(.init(source: fits ? text : nil, captured: captured, dependencies: dependencies))
    }

    func preamble(for formula: String) -> String? {
        var remaining = PreviewConversion.maximumFormulaBytes - formula.utf8.count
        guard remaining >= 0, !PreviewConversion.expired else { return nil }
        guard !latest.isEmpty, formula.contains("\\") else { return "" }
        var lexer = Lexer(formula)
        var pending: [Int] = []
        while true {
            let token = lexer.lex()
            if token.isEOF { break }
            if let id = latest[token.text] { pending.append(id) }
        }
        var selected: Set<Int> = []
        while let id = pending.popLast() {
            guard selected.insert(id).inserted else { continue }
            let declaration = declarations[id]
            guard let source = declaration.source, source.utf8.count <= remaining else { return nil }
            remaining -= source.utf8.count
            if let captured = declaration.captured { pending.append(captured) }
            pending += declaration.dependencies.compactMap { latest[$0] }
        }
        return selected.sorted().compactMap { declarations[$0].source }.joined()
    }
}

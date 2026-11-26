import SwaTex

/// Only a statically costed expression can carry user assignments into the native parser.
enum AppMathInput {
    enum Route {
        case original, boundedNative
    }

    private static let assignments: Set<String> = [
        #"\def"#, #"\let"#, #"\newcommand"#, #"\renewcommand"#, #"\providecommand"#, #"\DeclareMathOperator"#,
    ]

    /// Split leading assignments using the same token boundaries as the parser. Check the source size before lexing.
    /// Anything after a preamble must be the formula itself; it cannot be silently discarded during validation.
    static func afterLeadingDeclarations(_ source: String) -> String? {
        guard source.utf8.count <= PreviewMathExpansion.maximumBytes else { return nil }
        var lexer = Lexer(source)
        var token = lexer.lex()
        while token.isSpace { token = lexer.lex() }
        while assignments.contains(token.text) {
            let kind = token.text
            token = lexer.lex()
            if kind != #"\def"# && token.text == "*" { token = lexer.lex() }
            if token.text == "{" && kind != #"\def"# && kind != #"\let"# {
                token = lexer.lex()
                guard token.isCommand, PreviewMathExpansion.permitted(token.text), lexer.lex().text == "}" else {
                    return nil
                }
            } else if !token.isCommand || !PreviewMathExpansion.permitted(token.text) {
                return nil
            }
            if kind == #"\let"# {
                token = lexer.lex()
                if token.text == "=" { token = lexer.lex() }
                while token.isSpace { token = lexer.lex() }
                guard token.isCommand else { return nil }
            } else {
                token = lexer.lex()
                var parameter = 0
                while token.text != "{" {
                    guard !token.isEOF else { return nil }
                    if kind == #"\def"# && token.text == "#" {
                        parameter += 1
                        guard parameter <= 9, lexer.lex().text == String(parameter) else { return nil }
                    }
                    token = lexer.lex()
                }
                var depth = 1
                while depth > 0 {
                    token = lexer.lex()
                    guard !token.isEOF else { return nil }
                    if token.text == "{" { depth += 1 }
                    if token.text == "}" { depth -= 1 }
                }
            }
            token = lexer.lex()
            while token.isSpace { token = lexer.lex() }
        }
        let first = source.utf8.index(source.utf8.startIndex, offsetBy: token.loc.start)
        return String(source[first...])
    }

    static func prepare(_ source: String, definitions: String) -> (input: String, route: Route)? {
        // Preserve long native expressions, verbatim spelling and whitespace in text nodes. Check raw
        // source so a change in comment handling inside a native argument cannot hide an assignment.
        if definitions.isEmpty && !requiresInspection(source) { return (source, .original) }
        var formula = source
        var preamble = definitions
        if assignments.contains(where: { source.hasPrefix($0) }) {
            // Markdown has no separate preamble. Only its leading top-level declarations precede
            // the expression; an assignment anywhere in the expression itself fails the proof.
            guard source.utf8.count <= PreviewMathExpansion.maximumWork - definitions.utf8.count else { return nil }
            guard let tail = afterLeadingDeclarations(source) else { return nil }
            formula = tail
            preamble += String(decoding: source.utf8.dropLast(tail.utf8.count), as: UTF8.self)
        }
        if preamble.isEmpty {
            guard standalone(formula) else { return nil }
            return (source, .original)
        }
        guard NativeMathBound.accepts(formula, definitions: preamble) else { return nil }
        return (definitions + source, .boundedNative)
    }

    // Preserve the existing limits for the few native helpers with non-linear or re-lexed input,
    // even in formulas without a user declaration. Always return the original source.
    private static func standalone(_ formula: String) -> Bool {
        guard !requiresInspection(formula, allowFixedHelpers: true),
            let tokens = try? PreviewMathExpansion.tokens(formula, limit: PreviewMathExpansion.maximumBytes),
            tokens.allSatisfy(PreviewMathExpansion.permitted),
            !tokens.contains(where: { conditional($0) })
        else { return false }
        let special = tokens.filter(PreviewMathExpansion.specialBuiltins.contains)
        guard special.count <= 4, !special.contains(#"\Braket"#) || tokens.filter({ $0 == "|" }).count <= 64 else {
            return false
        }
        return !special.contains(where: { $0 == #"\ce"# || $0 == #"\pu"# })
            || (try? PreviewMathExpansion.checkChemistry(formula)) != nil
    }

    static func conditional(_ word: String) -> Bool {
        ((word.hasPrefix(#"\if"#) || word.hasPrefix(#"\If"#)) && word != #"\iff"#)
            || [#"\else"#, #"\fi"#, #"\or"#, #"\unless"#].contains(word)
    }

    private static func requiresInspection(_ source: String, allowFixedHelpers: Bool = false) -> Bool {
        // SwaTex lexes ASCII control words in UTF-8. A Swift Character (or a regex matching
        // graphemes) can span both the final ASCII letter and a following combining mark.
        let bytes = source.utf8
        var cursor = bytes.startIndex
        while let slash = bytes[cursor...].firstIndex(of: 92) {
            cursor = bytes.index(after: slash)
            while cursor < bytes.endIndex, PreviewMathExpansion.wordByte(bytes[cursor]) {
                if bytes[cursor] == 64 { return true }
                bytes.formIndex(after: &cursor)
            }
            let word = bytes[slash..<cursor]
            if word.starts(with: [92, 105, 102]) || word.starts(with: [92, 73, 102]) {
                if !word.elementsEqual(#"\iff"#.utf8) { return true }
            }
            if word.count > 1, word.count <= PreviewMathExpansion.longestInspectedWord,
                PreviewMathExpansion.inspectedWords.contains(String(decoding: word, as: UTF8.self))
            {
                if !allowFixedHelpers
                    || !PreviewMathExpansion.specialBuiltins.contains(String(decoding: word, as: UTF8.self))
                {
                    return true
                }
            }
        }
        return false
    }
}

import SwaTex

/// Only a statically costed expression can carry user assignments into the native parser.
enum AppMathInput {
    enum Route {
        case original, expanded, boundedNative
    }

    private static let assignments: Set<String> = [
        #"\def"#, #"\let"#, #"\newcommand"#, #"\renewcommand"#, #"\providecommand"#, #"\DeclareMathOperator"#,
    ]

    /// Split leading assignments using the same token boundaries as the parser. Check the source size before lexing.
    /// Anything after a preamble must be the formula itself; it cannot be silently discarded during validation.
    static func readPrefix(_ source: String, into index: inout PreviewMathDefinitions) -> String? {
        guard source.utf8.count <= PreviewMathExpansion.maximumBytes else { return nil }
        var lexer = Lexer(source)
        var token = lexer.lex()
        while token.isSpace { token = lexer.lex() }
        while assignments.contains(token.text) {
            let kind = token.text
            let start = token.loc.start
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
            let bytes = source.utf8
            let lower = bytes.index(bytes.startIndex, offsetBy: start)
            let upper = bytes.index(bytes.startIndex, offsetBy: lexer.pos)
            index.append(source[lower..<upper])
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
        var declarations = definitions
        if !definitions.isEmpty || assignments.contains(where: { source.hasPrefix($0) }) {
            var index = PreviewMathDefinitions(app: true)
            guard readPrefix(definitions, into: &index) == "" else { return nil }
            if assignments.contains(where: { source.hasPrefix($0) }) {
                guard let tail = readPrefix(source, into: &index) else { return nil }
                formula = tail
            }
            guard let selected = index.preamble(for: formula) else { return nil }
            declarations = selected
            if selected.isEmpty && !requiresInspection(formula) { return (formula, .original) }
        }
        var expansion = PreviewMathExpansion()
        do {
            let result = try expansion.expand(formula, definitions: declarations, app: true)
            return (result, expansion.steps == 0 ? .original : .expanded)
        } catch PreviewMathExpansion.Refusal.unsupported {
            guard NativeMathBound.accepts(formula, definitions: declarations) else { return nil }
            return (declarations + formula, .boundedNative)
        } catch {
            return nil
        }
    }

    private static func requiresInspection(_ source: String) -> Bool {
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
            if word.count > 1, word.count <= PreviewMathExpansion.longestInspectedWord,
                PreviewMathExpansion.inspectedWords.contains(String(decoding: word, as: UTF8.self))
            {
                return true
            }
        }
        return false
    }
}

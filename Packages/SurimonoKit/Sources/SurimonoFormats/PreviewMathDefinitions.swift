import SwaTex

/// Index assignments once, so an unrelated or over-budget declaration cannot spoil the next formula.
struct MathDefinitions {
    var source: String
    var containsOnlyPrimitiveDefinitions = true
    var preambleTooLarge = false
    var rawHeaderMayProduceOutput = false
    var preview: PreviewMathDefinitions?
    var app = PreviewMathDefinitions(app: true)

    init(source: String = "") {
        self.source = source
        if PreviewConversion.isActive {
            preview = PreviewMathDefinitions()
            if !source.isEmpty { preview?.append(source[...]) }
        } else if !source.isEmpty {
            app.append(source[...])
        }
    }

    func preamble(for formula: String) -> String? {
        if let preview { return preview.preamble(for: formula) }
        guard let selected = app.preamble(for: formula) else { return nil }
        if selected.isEmpty && !rawHeaderMayProduceOutput
            && (source.isEmpty || source == #"\def\ensuremath#1{#1}"#)
        {
            return ""
        }
        // Never silently recompose a different native preamble. In particular, a raw optional
        // signature can emit ordinary input before a formula even when the name is not called.
        guard !preambleTooLarge, source.utf8.count <= PreviewMathExpansion.maximumWork else { return nil }
        return source
    }
}

/// A formula carries only the declarations it can reach, in their original order.
/// The reader copies this value at TeX group boundaries, just like its ordinary math preamble.
struct PreviewMathDefinitions {
    private struct Declaration {
        let source: String?
        let previous: Int?
        let dependencies: Set<String>
    }

    private let app: Bool

    init(app: Bool = false) {
        self.app = app
    }

    private var declarations: [Declaration] = []
    var insideGroup = false
    private var hasDynamicName = false
    private var latest: [String: Int] = [:]

    /// One Org header can declare several commands. Walk slices so a large replacement need not be
    /// copied into a character array just to find the next top-level declaration.
    mutating func appendHeader(_ header: String, unsupported: Bool = false) {
        var cursor = header.startIndex
        var nextCheck = cursor
        var start: String.Index?
        var depth = 0
        var unsupportedPrefix = unsupported
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
                if let start { append(header[start..<token], unsupported: unsupportedPrefix) }
                return
            case "{": depth += 1
            case "}": depth = max(0, depth - 1)
            case "\\" where cursor < header.endIndex:
                if let match = header[token...].prefixMatch(
                    of:
                        /\\(?:def|gdef|edef|xdef|let|futurelet|newcommand|renewcommand|providecommand|DeclareMathOperator)(?![A-Za-z@])/
                ) {
                    if depth == 0 {
                        if let start {
                            append(header[start..<token], unsupported: unsupportedPrefix)
                        } else {
                            unsupportedPrefix = unsupported || header[..<token].contains { !$0.isWhitespace }
                        }
                        start = token
                    } else if start == nil {
                        // A grouped assignment cannot be hoisted to the document preamble.
                        let tail = header[match.range.upperBound...]
                        var lexer = Lexer(
                            String(decoding: tail.utf8.prefix(PreviewConversion.maximumFormulaBytes), as: UTF8.self))
                        var name = lexer.lex().text
                        while [" ", "{", "*"].contains(name) { name = lexer.lex().text }
                        reject(name)
                    }
                }
                // An escaped brace, percent or backslash cannot start another token.
                header.formIndex(after: &cursor)
            default: break
            }
        }
        if let start { append(header[start...], unsupported: unsupportedPrefix) }
    }

    func isRejected(_ name: String) -> Bool {
        latest[name].map { declarations[$0].source == nil } ?? false
    }

    mutating func replaceWithReaderDefinition(_ name: String) {
        if insideGroup { reject(name) } else { latest.removeValue(forKey: name) }
    }

    mutating func reject(_ name: String) {
        if name == "\\csname" { hasDynamicName = true }
        latest[name] = declarations.count
        declarations.append(.init(source: nil, previous: nil, dependencies: []))
    }

    mutating func append(_ source: Substring, expectedName: String? = nil, unsupported: Bool = false) {
        let limit = app ? PreviewMathExpansion.maximumBytes : PreviewConversion.maximumFormulaBytes
        let fits = source.utf8.count <= limit
        let text = fits ? String(source) : String(decoding: source.utf8.prefix(limit), as: UTF8.self)
        var lexer = Lexer(text)
        let command = lexer.lex().text
        var target = lexer.lex()
        while ["{", "*", " "].contains(target.text) { target = lexer.lex() }
        let name = target.text
        if let expectedName, expectedName != name {
            // The prose reader may have resolved a dynamically constructed definition name.
            reject(expectedName)
            return
        }
        guard PreviewMathExpansion.controlWord(name) || (app && name.hasPrefix("\\") && name.count == 2),
            name != "\\csname"
        else {
            reject(name)
            return
        }
        if app && command == "\\let" {
            reject(name)
            return
        }
        if command == (app ? "\\newcommand" : "\\providecommand"), latest[name] != nil { return }
        guard fits, !insideGroup, !unsupported,
            ["\\def", "\\newcommand", "\\renewcommand", "\\providecommand", "\\DeclareMathOperator"].contains(command),
            command != "\\newcommand" || latest[name] == nil
        else {
            reject(name)
            return
        }

        var dependencies: Set<String> = []
        while true {
            let token = lexer.lex()
            if token.isEOF { break }
            if token.text.hasPrefix("\\") { dependencies.insert(token.text) }
        }
        let previous = command == "\\renewcommand" ? latest[name] : nil
        latest[name] = declarations.count
        declarations.append(Declaration(source: text, previous: previous, dependencies: dependencies))
    }

    func preamble(for formula: String) -> String? {
        if app && (latest.isEmpty || !formula.contains("\\")) { return "" }
        var remaining =
            (app ? PreviewMathExpansion.maximumBytes : PreviewConversion.maximumFormulaBytes) - formula.utf8.count
        guard app || remaining >= 0, !PreviewConversion.expired else { return nil }
        if hasDynamicName, formula.contains("\\") { return nil }
        guard !latest.isEmpty else { return "" }
        var lexer = Lexer(formula)
        var pending: [Int] = []
        let hasImplicitBinding = app && NativeMathBound.implicitNames.contains { latest[$0] != nil }
        var visitedNative: Set<String> = []
        func enqueue(_ name: String) {
            if let id = latest[name] {
                pending.append(id)
            } else if hasImplicitBinding, let calls = NativeMathBound.implicitCalls[name],
                visitedNative.insert(name).inserted
            {
                for callee in calls { enqueue(callee) }
            }
        }
        while true {
            let token = lexer.lex()
            if token.isEOF { break }
            if token.text.hasPrefix("\\") {
                enqueue(token.text)
                if remaining < 0 && !pending.isEmpty { return nil }
            }
        }
        var selected: Set<Int> = []
        while let id = pending.popLast() {
            guard selected.insert(id).inserted else { continue }
            let declaration = declarations[id]
            guard let bytes = declaration.source?.utf8.count, bytes <= remaining else { return nil }
            remaining -= bytes
            if let previous = declaration.previous { pending.append(previous) }
            for name in declaration.dependencies { enqueue(name) }
        }
        return selected.sorted().compactMap { declarations[$0].source }.joined()
    }
}

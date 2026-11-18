import Foundation

extension LaTeXReader {
    private static let primitiveNames: Set<String> = [
        "if", "iftrue", "iffalse", "ifx", "ifdefined", "ifcsname", "ifnum", "ifdim", "ifodd", "ifcase",
        "ifpdf", "ifxetex", "ifluatex", "ifPDFTeX", "ifXeTeX", "ifLuaTeX",
    ]
    private static let testNames: Set<String> = [
        "ifthenelse", "ifbool", "notbool", "iftoggle", "nottoggle", "ifdef", "ifundef", "ifcsdef",
        "ifstrequal", "ifstrempty", "ifblank", "ifnumequal", "ifnumgreater", "ifnumless", "ifdefempty",
    ]
    private static let assignments: Set<String> = [
        "newif", "newboolean", "newbool", "newtoggle", "setboolean", "setbool", "booltrue", "boolfalse",
        "toggletrue", "togglefalse",
    ]

    /// Only primitives and declared \if names introduce a level that must close with \fi.
    func isConditionalPrimitive(_ name: String) -> Bool {
        Self.primitiveNames.contains(name)
            || (name.hasPrefix("if") && document.booleans[String(name.dropFirst(2))] != nil)
    }

    /// Recognize \footrue and \foofalse only after foo has been declared, to leave other commands alone.
    private func booleanSetter(_ name: String) -> (String, Bool)? {
        let value = name.hasSuffix("true")
        guard value || name.hasSuffix("false") else { return nil }
        let key = String(name.dropLast(value ? 4 : 5))
        return document.booleans[key] == nil ? nil : (key, value)
    }

    func isControlCommand(_ name: String) -> Bool {
        isConditionalPrimitive(name) || Self.testNames.contains(name) || Self.assignments.contains(name)
            || Self.loopNames.contains(name) || booleanSetter(name) != nil
    }

    /// Only the chosen branch reenters the reader, so discarded assignments and labels cannot affect later text.
    func handleControl(_ name: String) -> Bool {
        if isConditionalPrimitive(name) {
            let choice = name == "ifcase" ? integerOperand() ?? -1 : (primitiveTest(name) ? 0 : -1)
            choosePrimitiveBranch(choice, cases: name == "ifcase")
        } else if Self.testNames.contains(name) {
            let condition = packageTest(name)
            let yes = argument() ?? ""
            let no = argument() ?? ""
            insertExpansion(condition ? yes : no)
        } else if Self.assignments.contains(name) {
            assignBoolean(name)
        } else if let (key, value) = booleanSetter(name) {
            document.booleans[key] = value
        } else if Self.loopNames.contains(name) {
            readLoop(name)
        } else {
            return false
        }
        return true
    }

    /// Keep etoolbox toggles separate because a toggle and a boolean can have the same name.
    private func assignBoolean(_ command: String) {
        let key = argument() ?? ""
        switch command {
        case "newif":
            if key.hasPrefix("\\if") { document.booleans[String(key.dropFirst(3))] = false }
        case "newtoggle", "togglefalse": document.toggles[key] = false
        case "toggletrue": document.toggles[key] = true
        case "setbool", "setboolean": document.booleans[key] = argument()?.lowercased() == "true"
        case "booltrue": document.booleans[key] = true
        default: document.booleans[key] = false
        }
    }

    /// Run selected source in the current paragraph and float. Macro frame ends belong to the enclosing
    /// source's character array, so they must be restored with its cursor.
    func readExpansionBody(_ source: String) {
        guard !source.isEmpty, !document.stopsExpanding else { return }
        guard document.depth < LaTeXDocument.maximumDepth else {
            document.stopsExpanding = true
            return
        }
        let parent = (characters, index, macroFrameEnds, inPreamble)
        defer {
            (characters, index, macroFrameEnds, inPreamble) = parent
            document.depth -= 1
        }
        document.depth += 1
        characters = Array(source)
        index = 0
        macroFrameEnds = []
        if inPreamble {
            readPreamble()
        } else {
            while !document.endedDocument, let next = peek() { step(next) }
        }
    }

    /// Scanning an unselected branch never expands a token. In particular its counter assignments,
    /// definitions, unknown commands, and loops have no effects.
    private func choosePrimitiveBranch(_ choice: Int, cases: Bool) {
        var level = 0
        var branch = 0
        var selected: Range<Int>?
        var begin = index
        var fallback = false
        var declared: Set<String> = []
        var loops = 0
        while let token = nextStructuralWord(declared: &declared) {
            if token.name == "loop" {
                loops += 1
                continue
            }
            if token.name == "repeat", loops > 0 {
                loops -= 1
                continue
            }
            if loops > 0 { continue }
            if isConditionalPrimitive(token.name) || declared.contains(token.name) {
                level += 1
                continue
            }
            if token.name == "fi" && level > 0 {
                level -= 1
                continue
            }
            // A nested \if owns its \else and \fi. Only a separator at the opening test's depth ends our branch.
            guard level == 0, token.name == "fi" || token.name == "else" || (cases && token.name == "or") else {
                continue
            }
            if selected == nil, fallback || branch == choice { selected = begin..<token.start }
            if token.name == "fi" { break }
            fallback = token.name == "else"
            branch += 1
            skipSpacesAfterControlWord()
            begin = index
        }
        skipSpacesAfterControlWord()
        if let selected { insertExpansion(String(characters[selected])) }
    }

    /// A control token being defined or compared is an operand, not another opening conditional. Keep
    /// prospective boolean names local to this scan: the skipped branch must not actually define them.
    func nextStructuralWord(declared: inout Set<String>) -> (start: Int, name: String, after: Int)? {
        while let ch = peek() {
            if let end = LaTeXLexer.opaqueEnd(characters, at: index) {
                index = end
            } else if ch == "{" {
                index += 1
                _ = balanced()
            } else if ch == "\\" {
                let start = index
                let token = controlToken()
                guard token.dropFirst().first?.isLetter == true else { continue }
                let spelling = String(token.dropFirst())
                let name = document.macros[spelling]?.primitive ?? spelling
                let after = index
                switch name {
                case "newif":
                    let target = commandName()
                    if target.hasPrefix("if") { declared.insert(target) }
                case "newbool", "newboolean":
                    if let key = argument() { declared.insert("if" + key) }
                case "let":
                    let target = commandName()
                    skipSpaces()
                    if peek() == "=" { index += 1 }
                    let source = commandName()
                    if isConditionalPrimitive(source) || declared.contains(source) { declared.insert(target) }
                case "def", "ifdefined", "ifdef", "ifundef", "ifdefempty": _ = argument()
                case "ifx", "if":
                    _ = argument()
                    _ = argument()
                default: break
                }
                return (start, name, after)
            } else {
                index += 1
            }
        }
        return nil
    }

    /// Primitive tests consume their operands from the input, leaving the first branch token for the caller.
    func primitiveTest(_ name: String) -> Bool {
        switch name {
        // Japanese and English papers commonly have a Unicode branch for LuaTeX. Choose it consistently
        // without depending on the engines installed on the Mac.
        // Keep pdfTeX and XeTeX false so separate engine checks cannot select conflicting alternatives.
        case "ifluatex", "ifLuaTeX", "iftrue": return true
        case "ifpdf", "ifPDFTeX", "ifxetex", "ifXeTeX", "iffalse": return false
        case "ifdefined": return isDefinedCommand(commandName())
        case "ifcsname": return isDefinedCommand(readCSName())
        case "ifodd": return integerOperand().map { !$0.isMultiple(of: 2) } ?? false
        case "ifnum": return comparison { integerOperand() }
        case "ifdim": return comparison { dimensionOperand() }
        case "ifx", "if":
            let left = comparisonToken(expanding: name == "if")
            let right = comparisonToken(expanding: name == "if")
            if left == right { return true }
            guard left.hasPrefix("\\"), right.hasPrefix("\\") else { return false }
            let a = String(left.dropFirst())
            let b = String(right.dropFirst())
            if name == "if" { return true }
            // \ifx compares meanings without expansion: aliases can match a primitive, and macros must agree on
            // both parameter text and replacement text. Two undefined control sequences also have the same meaning.
            let lhs = document.macros[a]
            let rhs = document.macros[b]
            if (rhs == nil && lhs?.primitive == b) || (lhs == nil && rhs?.primitive == a) { return true }
            if let lhs, let rhs { return lhs == rhs }
            return !isDefinedCommand(a) && !isDefinedCommand(b)
        default: return document.booleans[String(name.dropFirst(2))] ?? false
        }
    }

    /// Unlike ifx, if expands an operand before comparing its character code. Put replacements back in
    /// the source so multi-token macros and their following arguments keep ordinary TeX token order.
    private func comparisonToken(expanding: Bool) -> String {
        while let character = peek() {
            if character == "%" {
                skipSpaces()
            } else if character == "\\" {
                retireMacroFrames()
                let token = controlToken()
                let name = String(token.dropFirst())
                if name.first?.isLetter == true { skipSpacesAfterControlWord() }
                guard expanding, !document.stopsExpanding, let macro = document.macros[name], macro.primitive == nil
                else { return token }
                _ = handleMacro(name)
            } else {
                index += 1
                return String(character)
            }
        }
        return ""
    }

    private func commandName() -> String {
        let token = argument() ?? ""
        if token.hasPrefix("\\") { skipSpacesAfterControlWord() }
        return token.hasPrefix("\\") ? String(token.dropFirst()) : ""
    }

    private func comparison<T: Comparable>(_ operand: () -> T?) -> Bool {
        let lhs = operand()
        skipSpaces()
        guard let operation = peek(), ["<", "=", ">"].contains(operation) else { return false }
        index += 1
        guard let rhs = operand(), let lhs else { return false }
        switch operation {
        case "<": return lhs < rhs
        case ">": return lhs > rhs
        default: return lhs == rhs
        }
    }

    /// Read just the signed integer or counter value so the comparison operator and following branch remain intact.
    func integerOperand() -> Int? {
        skipSpaces()
        var negative = false
        while peek() == "-" || peek() == "+" {
            if peek() == "-" { negative.toggle() }
            index += 1
            skipSpaces()
        }
        let raw: String
        if peek() == "\\" {
            let token = controlToken()
            if token == "\\value" || token == "\\arabic" {
                raw = String(document.counters[argument() ?? ""])
            } else {
                raw = inline(token)
            }
        } else {
            let start = index
            while let ch = peek(), ch.isASCII && ch.isNumber { index += 1 }
            raw = String(characters[start..<index])
        }
        if peek()?.isWhitespace == true { skipSpacesAfterControlWord() }
        return Int((negative ? "-" : "") + raw)
    }

    /// Normalize both operands to the same unit before comparison, including lengths written in different units.
    private func dimensionOperand() -> Double? {
        skipSpaces()
        let start = index
        if peek() == "-" || peek() == "+" { index += 1 }
        while let ch = peek(), ch.isNumber || ch == "." { index += 1 }
        let number = Double(String(characters[start..<index]))
        skipSpaces()
        let units = [
            "pt": 1.0, "mm": 72.27 / 25.4, "cm": 72.27 / 2.54, "in": 72.27,
            "em": 10.0, "ex": 4.3, "pc": 12.0, "bp": 72.27 / 72, "sp": 1.0 / 65_536,
        ]
        guard let a = peek(), let b = peek(1), let points = units[String([a, b]).lowercased()] else { return nil }
        index += 2
        skipSpacesAfterControlWord()
        // TeX compares dimensions in integer scaled points; rounding avoids a false inequality across units.
        return number.map { ($0 * points * 65_536).rounded() }
    }

    /// Package predicates consume braced operands, leaving both branch arguments for their caller.
    private func packageTest(_ name: String) -> Bool {
        switch name {
        case "ifthenelse": return condition(argument() ?? "")
        case "ifbool", "notbool": return (document.booleans[argument() ?? ""] ?? false) == (name == "ifbool")
        case "iftoggle", "nottoggle": return (document.toggles[argument() ?? ""] ?? false) == (name == "iftoggle")
        case "ifcsdef": return isDefinedCommand(argument() ?? "")
        case "ifdef", "ifundef": return isDefinedCommand(commandName()) == (name == "ifdef")
        case "ifdefempty": return document.macros[commandName()]?.body.isEmpty == true
        case "ifstrequal":
            let lhs = argument()
            return argument() == lhs
        case "ifstrempty": return argument()?.isEmpty == true
        case "ifblank": return argument()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
        default:
            let lhs = Int(inline(argument() ?? ""))
            let rhs = Int(inline(argument() ?? ""))
            guard let lhs, let rhs else { return false }
            switch name {
            case "ifnumequal": return lhs == rhs
            case "ifnumless": return lhs < rhs
            default: return lhs > rhs
            }
        }
    }

    /// Require the test to consume its whole argument so a valid prefix cannot select a branch for malformed input.
    func condition(_ text: String) -> Bool {
        let reader = LaTeXReader(text, document: document, isBlock: false)
        let result = reader.logicalExpression(depth: 0)
        reader.skipSpaces()
        return result && reader.peek() == nil
    }

    /// ifthen evaluates and/or left to right. Parentheses are the package tokens \( and \), not math here.
    private func logicalExpression(depth: Int) -> Bool {
        guard document.depth + depth < LaTeXDocument.maximumDepth else {
            document.stopsExpanding = true
            return false
        }
        var result = logicalAtom(depth: depth)
        while true {
            skipSpaces()
            let start = index
            let op = controlToken().lowercased()
            guard op == "\\and" || op == "\\or" else {
                index = start
                return result
            }
            let next = logicalAtom(depth: depth)
            result = op == "\\and" ? result && next : result || next
        }
    }

    /// Fold repeated negation before evaluating its operand so a run of negations costs no extra stack frames.
    private func logicalAtom(depth: Int) -> Bool {
        skipSpaces()
        var inverted = false
        var start = index
        var token = controlToken()
        while token.lowercased() == "\\not" {
            inverted.toggle()
            skipSpaces()
            start = index
            token = controlToken()
        }
        let result: Bool
        switch token {
        case "\\(":
            result = logicalExpression(depth: depth + 1)
            skipSpaces()
            if controlToken() != "\\)" { return false }
        case "\\equal":
            let lhs = inline(argument() ?? "")
            result = inline(argument() ?? "") == lhs
        case "\\isodd":
            result = Int(inline(argument() ?? "")).map { !$0.isMultiple(of: 2) } ?? false
        case "\\boolean":
            result = document.booleans[argument() ?? ""] ?? false
        default:
            index = start
            result = comparison { integerOperand() }
        }
        return result != inverted
    }
}

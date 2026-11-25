import Foundation

extension LaTeXReader {
    private static let xparseBranches: Set<String> = ["IfValueTF", "IfNoValueTF", "IfBooleanTF"]

    private static let mathCounterFormats: Set<String> = [
        "arabic", "roman", "Roman", "alph", "Alph", "fnsymbol", "value",
    ]

    private static let mathRegisters: Set<String> = ["number", "the", "numexpr", "dimexpr"]

    /// A cheap source check lets ordinary formulas bypass the reader's counter pass.
    static func mayUseMathCounter(_ source: String) -> Bool {
        mathRegisters.contains { source.contains("\\" + $0) }
            || mathCounterFormats.contains { source.contains("\\" + $0) }
    }

    /// A prefix match alone would misread \theta as a reference to a counter named ta.
    private func isMathCounter(_ name: String) -> Bool {
        if Self.mathCounterFormats.contains(name) || Self.mathRegisters.contains(name) { return true }
        guard name.hasPrefix("the") else { return false }
        let counter = String(name.dropFirst(3))
        return document.counters.contains(counter) || document.theorems[counter]?.counter != nil
    }

    /// SwaTex already expands ordinary definitions; keep its input (including the accessible label) intact unless a
    /// token actually needs the reader. This pass never treats a math character or an unknown math command as prose.
    func expandMathCommands(_ latex: String, includingCounters: Bool = true) -> String {
        guard !PreviewConversion.isActive, latex.contains("\\"),
            document.hasExtendedMathDefinitions || (includingCounters && Self.mayUseMathCounter(latex))
                || latex.contains("\\If")
                || latex.contains("\\csname")
        else { return latex }
        return LaTeXReader(latex, document: document, isBlock: false).readMathCommands(
            includingCounters: includingCounters)
    }

    /// Copy ordinary math as written so SwaTex keeps its own tokenization on either side of a reader expansion.
    private func readMathCommands(includingCounters: Bool) -> String {
        var result = ""
        var endsInWord = false
        /// A letter copied after an expanded control word must start a fresh token when SwaTex reads the result.
        func append(_ piece: String) {
            guard let first = piece.first else { return }
            if endsInWord, first.isASCII, first.isLetter { result.append(" ") }
            result += piece
            endsInWord = Self.endsInControlWord(piece[...])
        }
        var start = index
        var dependencies: [String: Bool] = [:]
        var visiting: Set<String> = []
        /// An ordinary wrapper can call an xparse macro indirectly. Cache finished searches and skip cyclic edges.
        func needsReader(_ name: String) -> Bool {
            if isMathCounter(name) { return includingCounters }
            if Self.xparseBranches.contains(name) || name == "csname" { return true }
            guard let macro = document.macros[name] else { return false }
            if macro.extendedMath { return true }
            if let cached = dependencies[name] { return cached }
            guard document.hasExtendedMathDefinitions, !document.stopsExpanding, visiting.insert(name).inserted
            else { return false }
            defer { visiting.remove(name) }
            guard visiting.count < LaTeXDocument.maximumDepth, StackSpace.hasRoom,
                macro.body.utf8.count <= 50_000_000 - document.expansionWork
            else {
                document.stopsExpanding = true
                return false
            }
            document.expansionWork += macro.body.utf8.count
            guard macro.body.contains("\\") else {
                dependencies[name] = false
                return false
            }
            let scanner = LaTeXReader(macro.body, document: document, isBlock: false)
            while let ch = scanner.peek() {
                // An apparent dependency in a comment or verbatim text cannot affect the formula.
                if let opaque = LaTeXLexer.opaqueEnd(scanner.characters, at: scanner.index) {
                    scanner.index = opaque
                } else if ch == "\\" {
                    let called = String(scanner.controlToken().dropFirst())
                    if called == "begin", let environment = scanner.argument(),
                        document.environments[environment] != nil
                    {
                        dependencies[name] = true
                        return true
                    }
                    if needsReader(called) {
                        dependencies[name] = true
                        return true
                    }
                } else {
                    scanner.index += 1
                }
            }
            dependencies[name] = false
            return false
        }

        while let ch = peek() {
            if let opaque = LaTeXLexer.opaqueEnd(characters, at: index) {
                index = opaque
                continue
            }
            guard ch == "\\" else {
                index += 1
                continue
            }
            retireMacroFrames()
            let before = index
            let token = controlToken()
            let name = String(token.dropFirst())
            if name == "begin" {
                let after = index
                if let key = argument(), let environment = document.environments[key] {
                    append(String(characters[start..<before]))
                    let begin = replacement(environment.begin)
                    let body = environmentBody(key)
                    start = index
                    if let begin {
                        guard begin.utf8.count + body.utf8.count + environment.end.utf8.count <= 2_000_000
                        else {
                            document.stopsExpanding = true
                            continue
                        }
                        insertExpansion(Self.joinTokens(Self.joinTokens(begin, body), environment.end))
                    }
                } else {
                    index = after
                }
                continue
            }
            guard token == missingArgument || needsReader(name) else { continue }
            append(String(characters[start..<before]))
            skipSpacesAfterControlWord()
            if let macro = document.macros[name] {
                if let source = replacement(macro) { insertExpansion(source) }
            } else if Self.mathRegisters.contains(name) {
                let operand = index
                if let value = printedRegister(name) {
                    append(value)
                } else {
                    index = operand
                    append(token)
                }
            } else if Self.mathCounterFormats.contains(name) {
                let key = (argument() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                insertExpansion(LaTeXSymbols.format(document.counters[key], as: name))
            } else if isMathCounter(name) {
                insertExpansion(formattedCounter(String(name.dropFirst(3)), forMath: true))
            } else if Self.xparseBranches.contains(name) {
                insertExpansion(xparseBranch(name))
            } else if token == missingArgument {
                append("\\text{-NoValue-}")
            } else if name == "csname" {
                let key = readCSName()
                if let macro = document.macros[key] {
                    if let source = replacement(macro) { insertExpansion(source) }
                } else if !key.isEmpty {
                    append("\\" + key)
                }
            }
            start = index
        }
        append(String(characters[start...]))
        return result
    }
}

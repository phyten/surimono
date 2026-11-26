import Foundation
import SwaTex

/// The extended LaTeX reader (xparse, counters and environments) splices source rather than lexer tokens.
final class ReaderMathBudget {
    var scheduled = 0
    var inspected = 0
    var steps = 0
    var refused = false

    func available(pending: ArraySlice<Character>, depth: Int) -> Int {
        guard !refused, steps < PreviewMathExpansion.maximumSteps, depth < PreviewMathExpansion.maximumDepth
        else { return -1 }
        var room = PreviewMathExpansion.maximumBytes
        for character in pending {
            room -= character.utf8.count
            if room < 0 { return -1 }
        }
        return min(room, PreviewMathExpansion.maximumWork - scheduled)
    }

    func reserve(bytes: Int, pending: ArraySlice<Character>, depth: Int) -> Bool {
        guard bytes <= available(pending: pending, depth: depth) else {
            refused = true
            return false
        }
        steps += 1
        scheduled += bytes
        return true
    }
}

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

    /// The shared math expander handles ordinary definitions; keep its input (including the accessible label) intact unless a
    /// token actually needs the reader. This pass never treats a math character or an unknown math command as prose.
    func expandMathCommands(_ latex: String, includingCounters: Bool = true, budget: ReaderMathBudget? = nil) -> String?
    {
        guard !PreviewConversion.isActive, latex.contains("\\"),
            document.hasExtendedMathDefinitions || (includingCounters && Self.mayUseMathCounter(latex))
                || latex.contains("\\If")
                || latex.contains("\\csname")
        else { return latex }
        // An unrelated xparse definition must not impose the expansion input limit on long native math.
        if latex.utf8.count > PreviewMathExpansion.maximumBytes {
            var lexer = Lexer(latex)
            while true {
                let token = lexer.lex()
                if token.isEOF { return latex }
                guard let name = token.commandName else { continue }
                if document.macros[name] != nil || Self.xparseBranches.contains(name) || name == "csname"
                    || (includingCounters && isMathCounter(name))
                {
                    break
                }
                if name == "begin", !document.environments.isEmpty {
                    guard lexer.lex().text == "{" else { break }
                    var key = ""
                    var part = lexer.lex()
                    while !part.isEOF && part.text != "}" {
                        guard part.text.utf8.count <= PreviewMathExpansion.maximumBytes - key.utf8.count else {
                            return nil
                        }
                        key += part.text
                        part = lexer.lex()
                    }
                    if document.environments[key] != nil { break }
                }
            }
        }
        let budget = budget ?? ReaderMathBudget()
        guard !budget.refused, latex.utf8.count <= PreviewMathExpansion.maximumBytes,
            latex.utf8.count <= PreviewMathExpansion.maximumWork - budget.scheduled
        else {
            budget.refused = true
            document.mathExpansionLimitReached = true
            return nil
        }
        let reader = LaTeXReader(latex, document: document, isBlock: false)
        budget.scheduled += latex.utf8.count
        reader.mathBudget = budget
        let result = reader.readMathCommands(includingCounters: includingCounters)
        if reader.mathBudget?.refused == true {
            document.mathExpansionLimitReached = true
            return nil
        }
        return result
    }

    /// Copy ordinary math as written so SwaTex keeps its own tokenization on either side of a reader expansion.
    private func readMathCommands(includingCounters: Bool) -> String? {
        var result = ""
        var endsInWord = false
        /// A letter copied after an expanded control word must start a fresh token when SwaTex reads the result.
        func append(_ piece: String) {
            guard let first = piece.first else { return }
            let space = endsInWord && first.isASCII && first.isLetter
            guard piece.utf8.count + (space ? 1 : 0) <= PreviewMathExpansion.maximumBytes - result.utf8.count else {
                mathBudget?.refused = true
                return
            }
            if space { result.append(" ") }
            result += piece
            endsInWord = Self.endsInControlWord(piece[...])
        }
        var start = index
        var dependencies: [String: Bool] = [:]
        var visiting: Set<String> = []
        /// An ordinary wrapper can call an xparse macro indirectly. Cache finished searches and skip cyclic edges.
        func needsReader(_ name: String) -> Bool {
            if document.mathDefinitions.app.isRejected("\\" + name) {
                mathBudget?.refused = true
                return false
            }
            if isMathCounter(name) { return includingCounters }
            if Self.xparseBranches.contains(name) || name == "csname" { return true }
            guard let macro = document.macros[name] else { return false }
            if macro.extendedMath { return true }
            if let cached = dependencies[name] { return cached }
            guard document.hasExtendedMathDefinitions, !document.stopsExpanding, mathBudget?.refused != true,
                visiting.insert(name).inserted
            else { return false }
            defer { visiting.remove(name) }
            guard visiting.count <= PreviewMathExpansion.maximumDepth, StackSpace.hasRoom,
                macro.body.utf8.count <= PreviewMathExpansion.maximumWork - (mathBudget?.inspected ?? 0)
            else {
                mathBudget?.refused = true
                return false
            }
            mathBudget?.inspected += macro.body.utf8.count
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
            guard mathBudget?.refused != true else { return nil }
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
                    guard !document.mathDefinitions.app.isRejected("environment:" + key) else {
                        mathBudget?.refused = true
                        return nil
                    }
                    append(String(characters[start..<before]))
                    let begin = replacement(environment.begin)
                    let body = environmentBody(key)
                    start = index
                    guard let begin else { return nil }
                    let joinedBytes = begin.utf8.count + body.utf8.count + environment.end.utf8.count
                    guard joinedBytes <= PreviewMathExpansion.maximumBytes - 2 else {
                        mathBudget?.refused = true
                        return nil
                    }
                    insertExpansion(Self.joinTokens(Self.joinTokens(begin, body), environment.end))
                } else {
                    index = after
                }
                continue
            }
            guard token == missingArgument || needsReader(name) else { continue }
            append(String(characters[start..<before]))
            skipSpacesAfterControlWord()
            if let macro = document.macros[name] {
                guard let source = replacement(macro) else { return nil }
                insertExpansion(source)
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
                mathBudget?.refused = true
                return nil
            }
            start = index
        }
        append(String(characters[start...]))
        return result
    }
}

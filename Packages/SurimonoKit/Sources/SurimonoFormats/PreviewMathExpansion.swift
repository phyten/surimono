import SwaTex

/// Finder's token stack contains only bounded replacements. SwaTex receives the finished expression, never a preamble.
struct PreviewMathExpansion {
    enum Refusal: Error { case unsupported, recursion, depth, steps, size }
    static let maximumSteps = 1_024
    static let maximumDepth = 32
    static let maximumBytes = 8_192
    static let maximumWork = 65_536

    private(set) var steps = 0
    private(set) var scheduledBytes = 0
    private(set) var outputBytes = 0
    private(set) var peakPendingBytes = 0

    /// Every replacement token inherits the call chain. Distinct call sites in the original input
    /// allow finite nesting in arguments; a generated self-reference or a revisited site is recursive.
    private final class Call {
        let name: String
        let parent: Call?
        let sourceIndex: Int?
        let depth: Int

        init(_ name: String, sourceIndex: Int?, parent: Call?) throws {
            self.sourceIndex = sourceIndex
            self.name = name
            self.parent = parent
            depth = (parent?.depth ?? 0) + 1
            guard depth <= maximumDepth else { throw Refusal.depth }
            var ancestor = parent
            while let call = ancestor {
                if call.name == name, sourceIndex == nil || call.sourceIndex == sourceIndex { throw Refusal.recursion }
                ancestor = call.parent
            }
        }
    }

    private struct Item {
        let text: String
        let call: Call?
        var sourceIndex: Int?
    }

    private enum Argument {
        case supplied([Item])
        case preset(ArraySlice<String>)
    }

    private var stack: [Item] = []
    private var pendingBytes = 0
    private var output = ""
    private var afterControlWord = false
    private var specialUses = 0
    private var hasChemistry = false
    private var hasBraket = false
    private var bars = 0

    mutating func expand(_ formula: String, definitions: String) throws -> String {
        self = Self()
        let limit = PreviewConversion.maximumFormulaBytes
        guard formula.utf8.count <= limit, definitions.utf8.count <= limit - formula.utf8.count else {
            throw Refusal.size
        }
        let macros = try PreviewMathMacro.read(definitions)
        let tokens = try Self.tokens(formula)
        for (index, token) in tokens.enumerated().reversed() {
            guard Self.permitted(token) else { throw Refusal.unsupported }
            try push(Item(text: token, call: nil, sourceIndex: index))
        }
        while let item = pop() {
            if let macro = macros[item.text] {
                guard steps < Self.maximumSteps else { throw Refusal.steps }
                guard !PreviewConversion.expired else { throw CancellationError() }
                steps += 1
                let call = try Call(item.text, sourceIndex: item.sourceIndex, parent: item.call)
                var arguments: [Argument] = []
                for index in 0..<macro.parameters {
                    if index == 0, let fallback = macro.defaultArgument {
                        skipSpaces()
                        if stack.last?.text == "[" {
                            arguments.append(.supplied(try argument(optional: true)))
                        } else {
                            // The default is part of the definition and inherits its recursion chain.
                            arguments.append(.preset(fallback))
                        }
                    } else {
                        arguments.append(.supplied(try argument(optional: false)))
                    }
                }
                for part in macro.body.reversed() {
                    switch part {
                    case .literal(let text): try push(Item(text: text, call: call))
                    case .argument(let index):
                        switch arguments[index] {
                        case .supplied(let items):
                            for token in items.reversed() {
                                try push(Item(text: token.text, call: call, sourceIndex: token.sourceIndex))
                            }
                        case .preset(let tokens):
                            for token in tokens.reversed() { try push(Item(text: token, call: call)) }
                        }
                    }
                }
            } else {
                try emit(item.text)
            }
        }
        if hasChemistry { try Self.checkChemistry(output) }
        return output
    }

    /// Charge each individual stack write, including every copy of every substituted argument, before appending it.
    private mutating func push(_ item: Item) throws {
        let bytes = item.text.utf8.count
        guard bytes <= Self.maximumBytes - pendingBytes, bytes <= Self.maximumWork - scheduledBytes else {
            throw Refusal.size
        }
        pendingBytes += bytes
        scheduledBytes += bytes
        peakPendingBytes = max(peakPendingBytes, pendingBytes)
        stack.append(item)
    }

    private mutating func pop() -> Item? {
        guard let item = stack.popLast() else { return nil }
        pendingBytes -= item.text.utf8.count
        return item
    }

    private mutating func skipSpaces() {
        while stack.last?.text == " " { _ = pop() }
    }

    /// All argument storage is transferred from the already charged stack. At most nine arguments are live.
    private mutating func argument(optional: Bool) throws -> [Item] {
        skipSpaces()
        guard let first = pop(), first.text != "}" else { throw Refusal.unsupported }
        if !optional && first.text != "{" { return [first] }
        var argument: [Item] = []
        var depth = 0
        while let item = pop() {
            if depth == 0 && item.text == (optional ? "]" : "}") { return argument }
            if item.text == "{" { depth += 1 }
            if item.text == "}" { depth -= 1 }
            guard (0...Self.maximumDepth).contains(depth) else { throw Refusal.depth }
            argument.append(item)
        }
        throw Refusal.unsupported
    }

    private mutating func emit(_ text: String) throws {
        // These public braket/set commands use fixed delimiters. tmspace copies its sign into both mode branches.
        if text == "\\ce" || text == "\\pu" { hasChemistry = true }
        if text == "\\Braket" { hasBraket = true }
        if text == "|" { bars += 1 }
        if hasBraket && bars > 64 { throw Refusal.size }
        if ["\\tmspace", "\\Braket", "\\Set", "\\set", "\\ce", "\\pu"].contains(text) {
            specialUses += 1
            guard specialUses <= 4 else { throw Refusal.size }
        }
        let separates = afterControlWord && text.utf8.first.map(Self.wordByte) == true
        let bytes = text.utf8.count + (separates ? 1 : 0)
        guard bytes <= Self.maximumBytes - outputBytes else { throw Refusal.size }
        if separates { output += " " }
        output += text
        outputBytes += bytes
        afterControlWord = Self.controlWord(text)
    }

    /// mhchem re-lexes generated TeX. Accept short literal chemical notation, with no TeX or nested input.
    private static func checkChemistry(_ source: String) throws {
        var lexer = Lexer(source)
        while true {
            let token = lexer.lex()
            if token.isEOF { return }
            guard token.text == "\\ce" || token.text == "\\pu" else { continue }
            guard lexer.lex().text == "{" else { throw Refusal.unsupported }
            var bytes = 0
            while true {
                let next = lexer.lex()
                if next.text == "}" { break }
                guard !next.isEOF, next.text.utf8.count == 1, let c = next.text.first, c.isASCII,
                    c.isLetter || c.isNumber || " .,+-/=()<>".contains(c)
                else { throw Refusal.unsupported }
                bytes += 1
                guard bytes <= 128 else { throw Refusal.size }
            }
        }
    }

    static func wordByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 64
    }

    static func controlWord(_ text: String) -> Bool {
        text.utf8.first == 92 && text.utf8.count > 1 && text.utf8.dropFirst().allSatisfy(wordByte)
    }

    static func tokens(_ source: String) throws -> [String] {
        // Every lexer token consumes at least one byte of this already bounded source.
        guard source.utf8.count <= PreviewConversion.maximumFormulaBytes else { throw Refusal.size }
        var lexer = Lexer(source)
        var result: [String] = []
        while true {
            let token = lexer.lex()
            if token.isEOF { return result }
            result.append(token.text)
        }
    }

    static func permitted(_ token: String) -> Bool {
        guard token.hasPrefix("\\") else { return true }
        // Internal braket helpers accept arbitrary replacement delimiters.
        return !token.contains("@") && !token.hasPrefix("\\verb") && !forbidden.contains(token)
    }

    private static let forbidden: Set<String> = [
        "\\", "\\def", "\\gdef", "\\edef", "\\xdef", "\\let", "\\futurelet", "\\global", "\\long",
        "\\newcommand", "\\renewcommand", "\\providecommand", "\\DeclareMathOperator", "\\expandafter",
        "\\noexpand", "\\csname", "\\endcsname", "\\catcode", "\\makeatletter", "\\makeatother",
    ]
}

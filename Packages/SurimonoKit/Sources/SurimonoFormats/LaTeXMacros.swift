import Foundation

extension LaTeXDocument {
    /// Stop expanding on the first overrun so the reader can still print the surrounding paper and report one issue.
    func reserveExpansion(characters: Int = 0) -> Bool {
        guard !endedDocument else { return false }
        // 200,000 calls allow many short substitutions but bound even empty ones. Two million generated characters
        // leave room for a long paper while also bounding macros that double their output in just a few calls.
        guard !stopsExpanding, expansions < 200_000, characters <= 2_000_000 - expandedCharacters else {
            stopsExpanding = true
            return false
        }
        expansions += 1
        expandedCharacters += characters
        return true
    }

    /// Keep the parameter text and replacement together so aliases retain the meaning in force at definition time.
    struct Macro: Equatable {
        /// The calling convention determines where each argument ends and the following prose resumes.
        enum Parameter: Equatable {
            case mandatory
            case optional(String?)
            case star
            case delimited(String)
        }

        var prefix = ""
        var specification: [Parameter]
        let body: String
        var primitive: String?
        // Babel replaces the caption control words when it activates another language.
        var captionLanguage: String?
        var extendedMath = false

        init(parameters: Int, defaultArgument: String?, body: String) {
            specification = Array(repeating: .mandatory, count: parameters)
            if parameters > 0, let defaultArgument { specification[0] = .optional(defaultArgument) }
            self.body = body
        }

        init(prefix: String = "", specification: [Parameter], body: String) {
            self.prefix = prefix
            self.specification = specification
            self.body = body
        }
    }
}

extension LaTeXReader {
    private typealias Macro = LaTeXDocument.Macro

    /// Definitions, including a saved meaning from \let, take precedence over the reader's own commands.
    func handleMacro(_ name: String) -> Bool {
        if let macro = document.macros[name], macro.captionLanguage == nil || macro.captionLanguage == document.language
        {
            if let primitive = macro.primitive {
                guard document.reserveExpansion() else { return true }
                if let symbol = primitive.first, primitive.count == 1, !(symbol.isASCII && symbol.isLetter) {
                    controlSymbol(symbol)
                } else if !macroPrimitive(primitive) {
                    dispatchBuiltin(primitive)
                }
            } else if let body = replacement(macro) {
                insertExpansion(body)
            }
            return true
        }
        return macroPrimitive(name)
    }

    /// Kept separate from user definitions so a saved primitive can run even after its original name is redefined.
    private func macroPrimitive(_ name: String) -> Bool {
        if name == "SurimonoNoValue" + document.nonce {
            appendText("-NoValue-")
            return true
        }
        switch name {
        case "newcommand", "renewcommand", "providecommand", "DeclareRobustCommand", "newenvironment",
            "renewenvironment", "NewDocumentCommand", "RenewDocumentCommand", "NewDocumentEnvironment",
            "RenewDocumentEnvironment":
            define(name)
        case "def": defineTeXMacro()
        case "let": letCommand()
        case "IfValueTF", "IfNoValueTF", "IfBooleanTF":
            insertExpansion(xparseBranch(name))
        case "csname":
            let key = readCSName()
            guard !key.isEmpty, document.reserveExpansion() else { return true }
            guard document.depth < LaTeXDocument.maximumDepth, StackSpace.hasRoom else {
                document.stopsExpanding = true
                return true
            }
            document.depth += 1
            dispatch(key)
            document.depth -= 1
        default: return false
        }
        return true
    }

    /// Leave both alternatives as source until the argument's presence or star selects one.
    func xparseBranch(_ name: String) -> String {
        let value = argument() ?? ""
        let yes = argument() ?? ""
        let no = argument() ?? ""
        let take: Bool
        switch name {
        case "IfNoValueTF": take = value == missingArgument
        case "IfValueTF": take = value != missingArgument
        default: take = value == "\\BooleanTrue"
        }
        return take ? yes : no
    }

    /// The command's name can itself contain an expansion, for example a counter value.
    func readCSName() -> String {
        guard let end = LaTeXLexer.find("endcsname", in: characters, from: index) else {
            index = characters.count
            return ""
        }
        let raw = String(characters[index..<end])
        index = end + "\\endcsname".count
        skipSpacesAfterControlWord()
        return (raw.contains("\\") ? HTML.unescape(inline(raw)) : raw).filter { !$0.isWhitespace }
    }

    /// Copy the current meaning so a later redefinition of the source leaves the \let target intact.
    private func letCommand() {
        guard let name = definitionName() else { return }
        defer { document.didDefineMacro(name) }
        skipSpaces()
        if peek() == "=" { index += 1 }
        skipSpaces()
        if peek() == "\\" {
            let source = String(controlToken().dropFirst())
            if let macro = document.macros[source] {
                document.macros[name] = macro
            } else if isDefinedCommand(source) {
                var alias = Macro(specification: [], body: "")
                alias.primitive = source
                document.macros[name] = alias
            } else {
                document.macros.removeValue(forKey: name)
            }
            addMathDefinition("\\let\\\(name)=\\\(source) ")
            if source.last?.isLetter == true { skipSpacesAfterControlWord() }
        } else if let value = argument() {
            document.macros[name] = Macro(specification: [], body: value)
            if document.mathDefinitions.preview != nil {
                document.mathDefinitions.preview?.reject("\\" + name)
            } else {
                addMathDefinition("\\def\\\(name){\(value)}")
            }
        }
    }

    /// A definition may name its target directly, in braces, or through \csname.
    private func definitionName() -> String? {
        guard let token = argument()?.trimmingCharacters(in: .whitespacesAndNewlines),
            token.hasPrefix("\\"), token.count > 1
        else { return nil }
        if token == "\\csname" { return readCSName() }
        return String(token.dropFirst())
    }

    /// Commands and environment openings share argument rules, including a default for the first argument.
    private func define(_ command: String) {
        let start = index
        _ = star()
        let environment = command.hasSuffix("environment") || command.hasSuffix("Environment")
        let name = environment ? argument() : definitionName()
        let xparse = command.contains("Document")
        let parameters: [Macro.Parameter]?
        if xparse {
            parameters = xparseParameters(argument() ?? "")
        } else {
            let count = optional().map { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            let defaultArgument = (count ?? 0) > 0 ? optional() : nil
            // TeX allows up to nine parameters. Ignore an invalid definition after consuming its body.
            if let count, (0...9).contains(count) {
                parameters = Macro(parameters: count, defaultArgument: defaultArgument, body: "").specification
            } else {
                parameters = nil
            }
        }
        let body = argument() ?? ""
        let end = environment ? argument() ?? "" : nil
        guard let name, !name.isEmpty else { return }
        guard let parameters else {
            if !environment { document.mathDefinitions.preview?.reject("\\" + name) }
            return
        }
        var macro = Macro(specification: parameters, body: body)
        // SwaTex accepts the prefix of an optional-default declaration but lays out the remainder
        // as ordinary math in every subsequent formula. Expand that signature at its call site.
        macro.extendedMath = xparse
        if case .optional = parameters.first { macro.extendedMath = true }
        if macro.extendedMath || environment || Self.mayUseMathCounter(body) || body.contains("\\If")
            || body.contains("\\csname")
        {
            document.hasExtendedMathDefinitions = true
        }
        if let end {
            document.environments[name] = (macro, end)
        } else {
            if command == "providecommand", isDefinedCommand(name) { return }
            document.macros[name] = macro
            if parameters.isEmpty { readFancyRule(name, value: body) }
            document.didDefineMacro(name)
            if document.mathDefinitions.preview != nil {
                recordPreviewDefinition(command, name: name, start: start)
            } else if !macro.extendedMath {
                let signature = parameters.indices.map { "#\($0 + 1)" }.joined()
                addMathDefinition("\\def\\\(name)\(signature){\(body)}")
            }
        }
    }

    /// Keep the original signature. Normalizing through the prose reader could hide unsupported syntax.
    private func recordPreviewDefinition(_ command: String, name: String, start: Int) {
        let target = "\\" + name
        guard index - start <= PreviewConversion.maximumFormulaBytes else {
            document.mathDefinitions.preview?.reject(target)
            return
        }
        let source = "\\" + command + String(characters[start..<index])
        document.mathDefinitions.preview?.append(source[...], expectedName: target)
    }

    /// A definition every formula starts with; one SwaTex cannot read is left out, so it cannot break the others.
    func addMathDefinition(_ definition: String) {
        guard !document.stopsExpanding else { return }
        if document.mathDefinitions.preview != nil {
            document.mathDefinitions.preview?.append(definition[...])
            return
        }
        // A definition inside a loop is still a definition. Rechecking a growing preamble on every
        // iteration must draw from the same finite work budget as expanding the loop itself.
        guard !document.mathDefinitions.source.hasSuffix(definition) else { return }
        let cost = document.mathDefinitions.source.utf8.count + definition.utf8.count
        guard cost <= 50_000_000 - document.expansionWork else {
            document.stopsExpanding = true
            return
        }
        document.expansionWork += cost
        // Neither storing replacement tokens nor copying a control word expands its meaning.
        // A prefix made only of these assignments leaves the validation formula "x" unchanged.
        if !document.mathDefinitions.containsOnlyPrimitiveDefinitions || !StackSpace.hasRoom
            || !MathRenderer.isOrdinaryDefinition(definition)
        {
            guard MathRenderer.html("x", display: false, macros: document.mathDefinitions.source + definition) != nil
            else { return }
            document.mathDefinitions.containsOnlyPrimitiveDefinitions = false
        }
        document.mathDefinitions.source += definition
    }

    /// Reject the whole signature on an unsupported specifier, since subsequent arguments could otherwise shift.
    private func xparseParameters(_ source: String) -> [Macro.Parameter]? {
        let reader = LaTeXReader(source, document: document, isBlock: false)
        var result: [Macro.Parameter] = []
        reader.skipSpaces()
        while let kind = reader.peek() {
            guard result.count < 9 else { return nil }
            reader.index += 1
            switch kind {
            case "m": result.append(.mandatory)
            case "s": result.append(.star)
            case "o": result.append(.optional(nil))
            case "O":
                guard let value = reader.argument() else { return nil }
                result.append(.optional(value))
            default: return nil
            }
            reader.skipSpaces()
        }
        return result
    }

    /// Text before #1 must match at the call site. Text after each parameter specifies where that argument ends.
    private func defineTeXMacro() {
        let start = index
        guard let name = definitionName() else { return }
        defer { document.didDefineMacro(name) }
        skipSpacesAfterControlWord()
        var delimiters = [""]
        var valid = true
        while let character = peek(), character != "{" {
            if character == "%" {
                skipComment()
            } else if character == "#", let next = peek(1) {
                valid = valid && next.wholeNumberValue == delimiters.count && delimiters.count <= 9
                if valid { delimiters.append("") }
                index += 2
            } else if character == "\\" {
                delimiters[delimiters.count - 1] += controlToken()
            } else {
                delimiters[delimiters.count - 1].append(character)
                index += 1
            }
        }
        let body = argument() ?? ""
        if document.mathDefinitions.preview != nil { recordPreviewDefinition("def", name: name, start: start) }
        guard valid else { return }
        if Self.mayUseMathCounter(body) || body.contains("\\If") || body.contains("\\csname") {
            document.hasExtendedMathDefinitions = true
        }
        let parameters = delimiters.dropFirst().map { $0.isEmpty ? Macro.Parameter.mandatory : .delimited($0) }
        document.macros[name] = .init(prefix: delimiters[0], specification: parameters, body: body)
        if parameters.isEmpty { readFancyRule(name, value: body) }
        let signature = delimiters.enumerated().map { ($0.offset == 0 ? "" : "#\($0.offset)") + $0.element }.joined()
        if document.mathDefinitions.preview == nil, name.count == 1 || name.allSatisfy({ $0.isASCII && $0.isLetter }) {
            addMathDefinition("\\def\\\(name)\(signature){\(body)}")
        }
    }

    /// Match only at token boundaries outside brace groups so an inner comma, for example, stays in the argument.
    func delimitedArgument(_ delimiter: String) -> String? {
        let marker = Array(delimiter)
        let start = index
        let endsInWord = Self.endsInControlWord(delimiter[...])
        while let character = peek() {
            if character == marker.first {
                guard marker.count <= 50_000_000 - document.expansionWork else {
                    document.stopsExpanding = true
                    return nil
                }
                document.expansionWork += marker.count
            }
            // Look ahead for a letter. Otherwise, \end would also match the start of \ending.
            if character == marker.first, characters[index...].starts(with: marker),
                !(endsInWord && peek(marker.count)?.isASCII == true && peek(marker.count)?.isLetter == true)
            {
                let value = String(characters[start..<index])
                index += marker.count
                if endsInWord { skipSpacesAfterControlWord() }
                // As with an ordinary argument, a single outer group is stripped once.
                if value.first == "{" {
                    let reader = LaTeXReader(value, document: document, isBlock: false)
                    if let contents = reader.argument(), reader.peek() == nil { return contents }
                }
                return value
            }
            if character == "{" {
                index += 1
                _ = balanced()
            } else if character == "\\" {
                _ = controlToken()
            } else if character == "%" {
                skipComment()
            } else {
                index += 1
            }
        }
        return nil
    }

    /// An omitted optional argument must compare differently from the literal text -NoValue-.
    var missingArgument: String { "\\SurimonoNoValue" + document.nonce }

    /// Count each substitution before appending it. A doubling definition must not allocate its next oversized body.
    func replacement(_ macro: LaTeXDocument.Macro) -> String? {
        guard characters[index...].starts(with: macro.prefix) else { return nil }
        index += macro.prefix.count
        var arguments: [String] = []
        for spec in macro.specification {
            switch spec {
            case .mandatory: arguments.append(argument() ?? "")
            case .optional(let fallback): arguments.append(optional() ?? fallback ?? missingArgument)
            case .star:
                arguments.append(star() ? "\\BooleanTrue" : "\\BooleanFalse")
            case .delimited(let marker):
                guard let value = delimitedArgument(marker) else { return nil }
                arguments.append(value)
            }
        }
        guard !document.stopsExpanding else { return nil }
        guard macro.body.utf8.count <= 50_000_000 - document.expansionWork else {
            document.stopsExpanding = true
            return nil
        }
        document.expansionWork += macro.body.utf8.count
        // Allow a substantial paragraph or table in one substitution, but cap it at 100,000 characters so a single
        // expansion cannot consume the entire document allowance.
        let limit = min(100_000, 2_000_000 - document.expandedCharacters)
        let sizes = arguments.map(\.count)
        var size = 0
        var result = ""
        var endsInWord = false
        func append(_ source: Substring, size length: Int) -> Bool {
            guard let first = source.first else { return true }
            let space = endsInWord && first.isASCII && first.isLetter
            size += length + (space ? 1 : 0)
            guard size <= limit else {
                document.stopsExpanding = true
                return false
            }
            if space { result.append(" ") }
            result += source
            endsInWord = Self.endsInControlWord(source)
            return true
        }

        // Scan the definition once. Each argument is copied without searching it, so its own #1 stays literal.
        var start = macro.body.startIndex
        var cursor = start
        while cursor < macro.body.endIndex {
            let position = cursor
            let character = macro.body[cursor]
            cursor = macro.body.index(after: cursor)
            if character == "\\", cursor < macro.body.endIndex {
                // An escaped # is a control symbol, not the start of a parameter.
                cursor = macro.body.index(after: cursor)
                continue
            }
            guard character == "#", cursor < macro.body.endIndex else { continue }
            let next = macro.body[cursor]
            guard next == "#" || (next.wholeNumberValue.map { (1...9).contains($0) && $0 <= arguments.count } ?? false)
            else { continue }
            let literal = macro.body[start..<position]
            guard append(literal, size: literal.count) else { return nil }
            if let number = next.wholeNumberValue {
                guard append(arguments[number - 1][...], size: sizes[number - 1]) else { return nil }
            } else if !append("#", size: 1) {
                return nil
            }
            cursor = macro.body.index(after: cursor)
            start = cursor
        }
        let last = macro.body[start...]
        guard append(last, size: last.count) else { return nil }
        return result
    }

    /// Read the three pieces in one group so a declaration in the opening applies throughout the environment.
    func expandEnvironment(_ name: String, _ environment: (begin: LaTeXDocument.Macro, end: String)) {
        let begin = replacement(environment.begin)
        let body = environmentBody(name)
        guard let begin else { return }
        let size = begin.count + body.count + environment.end.count
        guard size <= 2_000_000 - document.expandedCharacters else {
            document.stopsExpanding = true
            return
        }
        // TeX tokenizes the definition separately from the user's body. A final font switch
        // must not swallow a newline/space belonging to that body when we join them as source.
        let lastWord = begin.reversed().prefix(while: { $0.isASCII && $0.isLetter }).reversed()
        let fontSwitch = LaTeXSymbols.declarations[String(lastWord)] != nil && Self.endsInControlWord(begin[...])
        let opening = fontSwitch && body.first?.isWhitespace == true ? begin + "{}" : begin
        let source = Self.joinTokens(Self.joinTokens(opening, body), environment.end)
        guard document.reserveExpansion(characters: source.count) else { return }
        readEnvironmentGroup(source)
    }

    /// Inserting a control word next to a literal letter must not turn the two tokens into a different command.
    static func endsInControlWord(_ text: Substring) -> Bool {
        guard let last = text.last, last.isASCII, last.isLetter else { return false }
        var cursor = text.endIndex
        while cursor != text.startIndex {
            let before = text.index(before: cursor)
            guard text[before].isASCII, text[before].isLetter else { break }
            cursor = before
        }
        var escaped = false
        while cursor != text.startIndex {
            cursor = text.index(before: cursor)
            guard text[cursor] == "\\" else { break }
            escaped.toggle()
        }
        return escaped
    }

    /// Preserve token boundaries when splicing independently read pieces of TeX source.
    static func joinTokens(_ left: String, _ right: String) -> String {
        guard let first = right.first, first.isASCII, first.isLetter, endsInControlWord(left[...])
        else { return left + right }
        return left + " " + right
    }

    /// Measure frame ends from the unchanged tail because inserting another expansion shifts absolute indices.
    func retireMacroFrames() {
        while let end = macroFrameEnds.last, characters.count - index <= end { macroFrameEnds.removeLast() }
    }

    /// Put replacement tokens ahead of unread input so a generated command can take its arguments from that input.
    func insertExpansion(_ body: String) {
        let remaining = characters.count - index
        let next = peek()
        let separate = next?.isASCII == true && next?.isLetter == true && Self.endsInControlWord(body[...])
        let expansion = separate ? body + " " : body
        let size = expansion.count
        guard macroFrameEnds.count + document.depth < LaTeXDocument.maximumDepth, StackSpace.hasRoom,
            remaining + size <= 50_000_000 - document.expansionWork
        else {
            document.stopsExpanding = true
            return
        }
        guard document.reserveExpansion(characters: size), !expansion.isEmpty else { return }
        document.expansionWork += remaining + size
        macroFrameEnds.append(remaining)
        characters.insert(contentsOf: expansion, at: index)
    }

    /// Definition tests and \providecommand must recognize the same built-ins that the reader can dispatch.
    func isDefinedCommand(_ name: String) -> Bool {
        if name.count == 1, let symbol = name.first,
            LaTeXSymbols.controlSymbols[symbol] != nil || LaTeXSymbols.accents[symbol] != nil
        {
            return true
        }
        if document.environments[name] != nil || document.theorems[name] != nil { return true }
        return document.defaultCaption(name) != nil || document.macros[name] != nil
            || LaTeXSymbols.wrappers[name] != nil
            || LaTeXSymbols.declarations[name] != nil
            || LaTeXSymbols.text[name] != nil || LaTeXSymbols.sizes[name] != nil || LaTeXSymbols.ignored[name] != nil
            || Self.builtinNames.contains(name) || document.classInfo.definesClassCommand(name)
            || document.exam.listCommands.contains(name)
            || isControlCommand(name)
            || Self.registerCommands.contains(name) || document.countRegisters[name] != nil
            || (name.hasPrefix("the") && document.counters.contains(String(name.dropFirst(3))))
    }

    private static let builtinNames: Set<String> = [
        "begin", "end", "part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph",
        "maketitle", "tableofcontents", "title", "author", "date", "today", "ref", "eqref", "autoref", "cref", "Cref",
        "labelcref", "namecref", "crefrange", "crefname", "Crefname", "pageref", "vref", "nameref", "cite", "citep",
        "citeauthor", "citeyear", "addbibresource", "citet", "parencite", "textcite", "autocite", "bibliography",
        "printbibliography", "newtheorem", "theoremstyle",
        "declaretheorem", "qed", "qedsymbol", "qedhere", "num", "qty", "SI", "unit", "si", "ang", "footnote",
        "footnotemark", "footnotetext", "thanks", "href", "hyperref", "hyperlink", "hypertarget", "url", "nolinkurl",
        "path", "verb", "lstinline", "mintinline", "textcolor", "color", "colorbox", "fcolorbox", "newline",
        "linebreak",
        "newpage", "clearpage", "cleardoublepage", "pagebreak", "par", "bigskip", "medskip", "smallskip", "item",
        "input", "include", "subfile", "import", "includeonly", "tikzexternalize", "tikzsetnextfilename",
        "lstinputlisting", "inputminted", "appendix", "newcommand", "renewcommand",
        "providecommand", "def", "let", "DeclareRobustCommand", "NewDocumentCommand", "RenewDocumentCommand",
        "NewDocumentEnvironment", "RenewDocumentEnvironment", "IfNoValueTF", "IfValueTF", "IfBooleanTF", "csname",
        "endcsname", "includegraphics", "caption", "c", "k", "d", "b", "r", "t", "u", "v", "H", "sethlcolor",
        "MakeUppercase", "MakeLowercase", "uppercase", "lowercase", "value", "arabic", "alph", "Alph", "roman",
        "Roman", "fnsymbol", "counterwithin", "counterwithout", "refstepcounter", "ensuremath", "endgraf",
        "texorpdfstring", "foreignlanguage", "parbox", "rule", "raisebox", "resizebox", "scalebox", "rotatebox",
        "subfloat", "subfigure", "subcaption", "subcaptionbox", "tcbox", "newtcolorbox", "newtcbtheorem", "makecell",
        "tatechuyoko", "rensuji", "ruby", "jruby",
        "BooleanTrue", "BooleanFalse", "lstset", "lstdefinestyle",
    ]
}

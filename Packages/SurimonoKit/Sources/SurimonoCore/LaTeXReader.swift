import Foundation

/// Reads LaTeX source into HTML. A block reader makes paragraphs and blocks; an inline reader makes the text of one
/// argument or group. Readers for nested groups and environments share the document's state.
final class LaTeXReader {
    private enum Space {
        case space
        case newline
    }

    private let document: LaTeXDocument
    private var characters: [Character]
    private var index = 0
    private let isBlock: Bool
    private var output = ""
    private var paragraph = ""
    private var newlines = 0
    private var pendingSpace: Space?
    private var lastCharacter: Character?
    /// Closing markup for declarations such as `\bfseries`, which last to the end of their group.
    private var openDeclarations: [String] = []
    /// The float a `\caption` here belongs to: figures and tables are numbered apart.
    private var floatKind: String?

    init(_ text: String, document: LaTeXDocument, isBlock: Bool) {
        self.document = document
        characters = Array(text)
        self.isBlock = isBlock
    }

    func read() -> String {
        while let character = peek() { step(character) }
        if isBlock {
            flush()
            return output
        }
        closeDeclarations()
        return paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Characters

    private func peek(_ offset: Int = 0) -> Character? {
        index + offset < characters.count ? characters[index + offset] : nil
    }

    private func step(_ character: Character) {
        switch character {
        case "\\": command()
        case "%": skipComment()
        case "{":
            index += 1
            appendHTML(inline(balanced()), last: lastCharacter)
        case "}": index += 1
        case "$": dollarMath()
        case "\n": newline()
        case " ", "\t":
            index += 1
            if pendingSpace == nil { pendingSpace = .space }
        case "~":
            index += 1
            appendHTML("&nbsp;")
        case "-":
            var count = 0
            while peek() == "-" && count < 3 {
                index += 1
                count += 1
            }
            appendText(count == 3 ? "—" : count == 2 ? "–" : "-")
        case "`", "'":
            index += 1
            let double = peek() == character
            if double { index += 1 }
            appendText(character == "`" ? (double ? "“" : "‘") : (double ? "”" : "’"))
        default:
            index += 1
            appendText(String(character))
        }
    }

    /// TeX ignores a comment and the end of its line, and the spaces that start the next line.
    private func skipComment() {
        while let character = peek(), character != "\n" { index += 1 }
        if peek() == "\n" { index += 1 }
        while peek() == " " || peek() == "\t" { index += 1 }
    }

    /// The source not read yet.
    private var rest: String { index < characters.count ? String(characters[index...]) : "" }

    private func newline() {
        index += 1
        newlines += 1
        if newlines >= 2 {
            paragraphBreak()
        } else if pendingSpace == nil {
            pendingSpace = .newline
        }
        while peek() == " " || peek() == "\t" { index += 1 }
    }

    // MARK: - Output

    private func startContent() {
        newlines = 0
    }

    /// The pending space, unless it is the end of a line between two CJK characters, which TeX's Japanese engines
    /// drop.
    private func pendingSeparator(before next: Character?) -> String {
        defer { pendingSpace = nil }
        guard let pendingSpace, !paragraph.isEmpty, !paragraph.hasSuffix(" ") else { return "" }
        if pendingSpace == .newline, let lastCharacter, let next, LaTeXSymbols.isCJK(lastCharacter),
            LaTeXSymbols.isCJK(next)
        {
            return ""
        }
        return " "
    }

    private func appendText(_ text: String) {
        guard let first = text.first else { return }
        startContent()
        paragraph += pendingSeparator(before: first) + HTML.escape(text)
        lastCharacter = text.last
    }

    private func appendHTML(_ html: String, last: Character? = "x") {
        guard !html.isEmpty else { return }
        startContent()
        paragraph += pendingSeparator(before: html.first) + html
        lastCharacter = last
    }

    private func appendBlock(_ html: String) {
        startContent()
        if isBlock {
            flush()
            output += html
        } else {
            paragraph += html
        }
        pendingSpace = nil
    }

    private func paragraphBreak() {
        if isBlock {
            flush()
        } else if pendingSpace == nil {
            pendingSpace = .space
        }
    }

    private func closeDeclarations() {
        paragraph += openDeclarations.reversed().joined()
        openDeclarations = []
    }

    private func flush() {
        closeDeclarations()
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { output += "<p>\(text)</p>\n" }
        paragraph = ""
        pendingSpace = nil
        lastCharacter = nil
        newlines = 0
    }

    private func inline(_ text: String) -> String {
        let reader = LaTeXReader(text, document: document, isBlock: false)
        reader.floatKind = floatKind
        return reader.read()
    }

    private func blocks(_ text: String) -> String {
        let reader = LaTeXReader(text, document: document, isBlock: true)
        reader.floatKind = floatKind
        return reader.read()
    }

    /// An item's or a note's HTML: a single paragraph without its `<p>`.
    private func compact(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<p>"), trimmed.hasSuffix("</p>"),
            trimmed.components(separatedBy: "<p>").count == 2
        {
            return String(trimmed.dropFirst(3).dropLast(4))
        }
        return trimmed
    }

    // MARK: - Arguments

    private func skipSpaces() {
        while let character = peek() {
            if character == " " || character == "\t" || character == "\n" {
                index += 1
            } else if character == "%" {
                skipComment()
            } else {
                break
            }
        }
    }

    /// The source up to the brace that closes the one just read, without it. Escaped braces and comments do not
    /// count; with `comments` off, `%` is an ordinary character, as hyperref reads a URL.
    private func balanced(open: Character = "{", close: Character = "}", comments: Bool = true) -> String {
        var depth = 1
        var text: [Character] = []
        while let character = peek() {
            index += 1
            if character == "\\", let next = peek() {
                text += [character, next]
                index += 1
                continue
            }
            if character == "%" && comments {
                text.append(character)
                while let comment = peek(), comment != "\n" {
                    text.append(comment)
                    index += 1
                }
                continue
            }
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { break }
            }
            text.append(character)
        }
        return String(text)
    }

    /// A braced argument's source, or a single token as TeX takes it when there are no braces.
    private func argument(comments: Bool = true) -> String? {
        skipSpaces()
        guard let character = peek() else { return nil }
        if character == "{" {
            index += 1
            return balanced(comments: comments)
        }
        if character == "\\" { return controlToken() }
        if character == "}" { return nil }
        index += 1
        return String(character)
    }

    private func optional() -> String? {
        let start = index
        skipSpaces()
        guard peek() == "[" else {
            index = start
            return nil
        }
        index += 1
        var depth = 0
        var text: [Character] = []
        while let character = peek() {
            index += 1
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == "]" && depth == 0 { break }
            text.append(character)
        }
        return String(text)
    }

    private func star() -> Bool {
        guard peek() == "*" else { return false }
        index += 1
        return true
    }

    private func controlToken() -> String {
        guard peek() == "\\" else { return "" }
        index += 1
        var name = "\\"
        while let character = peek(), character.isASCII, character.isLetter {
            name.append(character)
            index += 1
        }
        if name == "\\", let character = peek() {
            name.append(character)
            index += 1
        }
        return name
    }

    /// Reads the argument count of `count` mandatory arguments after an optional one, and drops them.
    private func dropArguments(_ count: Int) {
        _ = optional()
        for _ in 0..<count { _ = argument() }
    }

    // MARK: - Commands

    private func command() {
        index += 1
        guard let next = peek() else { return }
        guard next.isASCII, next.isLetter else {
            index += 1
            controlSymbol(next)
            return
        }
        var name = ""
        while let character = peek(), character.isASCII, character.isLetter {
            name.append(character)
            index += 1
        }
        skipSpacesAfterControlWord()
        dispatch(name)
    }

    /// TeX skips the spaces after a control word, and the end of its line, but not a blank line.
    private func skipSpacesAfterControlWord() {
        while peek() == " " || peek() == "\t" { index += 1 }
        guard peek() == "\n" else { return }
        var lookahead = index + 1
        while lookahead < characters.count, characters[lookahead] == " " || characters[lookahead] == "\t" {
            lookahead += 1
        }
        if lookahead < characters.count, characters[lookahead] == "\n" { return }
        index = lookahead
    }

    private func controlSymbol(_ symbol: Character) {
        switch symbol {
        case "\\":
            _ = star()
            _ = optional()
            appendHTML("<br>")
        case "(": inlineMath(closing: "\\)")
        case "[": displayMath(closing: "\\]")
        default:
            if let mark = LaTeXSymbols.accents[symbol] {
                accent(mark)
            } else if let text = LaTeXSymbols.controlSymbols[symbol] {
                if symbol == " " || symbol == "\n" || symbol == "\t" {
                    appendText(" ")
                } else if !text.isEmpty {
                    appendText(text)
                }
            } else {
                appendText(String(symbol))
            }
        }
    }

    private func accent(_ mark: Character) {
        let base: String
        if let argument = argument() {
            switch argument {
            case "\\i": base = "ı"
            case "\\j": base = "ȷ"
            default: base = String(argument.first ?? " ")
            }
        } else {
            base = " "
        }
        appendText((base + String(mark)).precomposedStringWithCanonicalMapping)
    }

    private func dispatch(_ name: String) {
        if let macro = document.macros[name], !document.stopsExpanding, document.expansions < 10_000 {
            expand(macro)
            return
        }
        switch name {
        case "begin": environment()
        case "end": _ = argument()
        case "part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph":
            section(name)
        case "maketitle": appendBlock(titleBlock())
        case "tableofcontents": appendBlock(document.placeholder("T", 0))
        case "title": document.title = argument()
        case "author": document.authors = argument()
        case "date": document.date = argument() ?? ""
        case "today": appendText(document.today())
        case "label": label()
        case "ref", "autoref", "cref", "Cref", "pageref", "vref", "nameref":
            appendHTML(document.reference(argument() ?? "", style: .number))
        case "eqref": appendHTML(document.reference(argument() ?? "", style: .equation))
        case "cite", "citep", "citet", "parencite", "textcite", "autocite":
            _ = optional()
            _ = optional()
            appendText(
                "[\((argument() ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))]"
            )
        case "footnote", "thanks": footnote()
        case "href": link()
        case "url", "nolinkurl":
            let url = unescapedURL(argument(comments: false) ?? "")
            appendHTML("<a class=\"latex-url\" href=\"\(HTML.escape(url))\">\(HTML.escape(url))</a>")
        case "verb": verbatimInline()
        case "lstinline", "mintinline":
            _ = optional()
            if name == "mintinline" { _ = argument() }
            if peek() == "{" {
                index += 1
                appendHTML("<code>\(HTML.escape(balanced()))</code>")
            } else {
                verbatimInline()
            }
        case "textcolor": coloredText()
        case "color": colorDeclaration()
        case "colorbox", "fcolorbox": colorBox(framed: name == "fcolorbox")
        case "newline", "linebreak":
            _ = optional()
            appendHTML("<br>")
        case "newpage", "clearpage", "cleardoublepage", "pagebreak":
            _ = optional()
            appendBlock("<div class=\"latex-pagebreak\"></div>\n")
        case "par": paragraphBreak()
        case "bigskip": appendBlock("<div class=\"latex-vspace\" style=\"height: 12pt\"></div>\n")
        case "medskip": appendBlock("<div class=\"latex-vspace\" style=\"height: 6pt\"></div>\n")
        case "smallskip": appendBlock("<div class=\"latex-vspace\" style=\"height: 3pt\"></div>\n")
        case "vspace":
            _ = star()
            if let length = argument().flatMap(LaTeXSymbols.cssLength) {
                appendBlock("<div class=\"latex-vspace\" style=\"height: \(length)\"></div>\n")
            }
        case "hspace":
            _ = star()
            if let length = argument().flatMap(LaTeXSymbols.cssLength) {
                appendHTML("<span class=\"latex-hspace\" style=\"width: \(length)\"></span>")
            }
        case "item": appendText("• ")
        case "input", "include", "subfile", "lstinputlisting", "inputminted":
            if name == "lstinputlisting" { _ = optional() }
            if name == "inputminted" { _ = argument() }
            let file = argument() ?? ""
            appendBlock(unsupported(document.isJapanese ? "ファイル \(file) は読み込みません" : "\(file) is not included"))
        case "graphicspath": document.graphicsPaths = graphicsPaths(argument() ?? "")
        case "appendix":
            document.isAppendix = true
            document.sectionCounters[document.hasChapters ? 0 : 1] = 0
        case "newcommand", "renewcommand", "providecommand": define(name)
        case "def": defineTeXMacro()
        case "DeclareMathOperator": declareOperator()
        case "definecolor": defineColor()
        case "includegraphics": appendHTML(image())
        case "caption": caption()
        case "c", "k", "d", "b", "r", "t", "u", "v", "H":
            if let mark = LaTeXSymbols.accents[Character(name)] { accent(mark) }
        default: generic(name)
        }
    }

    private func generic(_ name: String) {
        if let wrapper = LaTeXSymbols.wrappers[name] {
            if name == "makebox" || name == "framebox" {
                _ = optional()
                _ = optional()
            }
            appendHTML(wrapper.open + inline(argument() ?? "") + wrapper.close)
        } else if let declaration = LaTeXSymbols.declarations[name] {
            if !declaration.open.isEmpty {
                appendHTML(declaration.open, last: lastCharacter)
                openDeclarations.append(declaration.close)
            }
        } else if let size = LaTeXSymbols.sizes[name] {
            appendHTML("<span style=\"font-size: \(String(format: "%g", size))em\">", last: lastCharacter)
            openDeclarations.append("</span>")
        } else if let text = LaTeXSymbols.text[name] {
            if !text.isEmpty { appendText(text) }
        } else if let count = LaTeXSymbols.ignored[name] {
            _ = star()
            dropArguments(count)
        }
        // Any other command is dropped; the groups after it are read as text, so its words stay on the paper.
    }

    private func expand(_ macro: LaTeXDocument.Macro) {
        document.expansions += 1
        var arguments: [String] = []
        if let defaultArgument = macro.defaultArgument, macro.parameters > 0 {
            arguments.append(optional() ?? defaultArgument)
        }
        while arguments.count < macro.parameters { arguments.append(argument() ?? "") }
        // One pass over the body records where each argument goes; an argument is never searched again, so its own
        // `#1` stays text. The size is counted during the pass and checked before anything is built.
        let template = Array(macro.body)
        let values = arguments.map { Array($0) }
        let limit = min(100_000, 2_000_000 - document.expandedCharacters)
        var pieces: [MacroPiece] = []
        var size = 0
        var position = 0
        while position < template.count {
            var piece = MacroPiece.text(template[position])
            var length = 1
            if template[position] == "#", position + 1 < template.count {
                let next = template[position + 1]
                if next == "#" {
                    position += 1
                } else if let number = next.wholeNumberValue, number >= 1, number <= values.count {
                    piece = .argument(number - 1)
                    length = values[number - 1].count
                    position += 1
                }
            }
            position += 1
            size += length
            guard size <= limit else {
                document.stopsExpanding = true
                return
            }
            pieces.append(piece)
        }
        let remaining = characters.count - index
        guard document.expansionWork + remaining + size <= 50_000_000 else {
            document.stopsExpanding = true
            return
        }
        document.expandedCharacters += size
        document.expansionWork += remaining + size
        var expansion: [Character] = []
        expansion.reserveCapacity(size)
        for piece in pieces {
            switch piece {
            case .text(let character): expansion.append(character)
            case .argument(let offset): expansion += values[offset]
            }
        }
        characters.insert(contentsOf: expansion, at: index)
    }

    private enum MacroPiece {
        case text(Character)
        case argument(Int)
    }

    // MARK: - Definitions

    func readPreamble() {
        while let character = peek() {
            if character == "%" {
                skipComment()
                continue
            }
            guard character == "\\" else {
                index += 1
                continue
            }
            index += 1
            let name = String(controlTokenName())
            skipSpacesAfterControlWord()
            switch name {
            case "documentclass":
                _ = optional()
                document.documentClass = argument()?.trimmingCharacters(in: .whitespaces) ?? "article"
                let chapterClasses = [
                    "report", "book", "jreport", "jbook", "jsbook", "ltjsbook", "ltjsreport", "bxjsbook",
                    "bxjsreport", "memoir", "scrbook", "scrreprt", "ujreport", "ujbook",
                ]
                if chapterClasses.contains(document.documentClass) { document.hasChapters = true }
            case "title": document.title = argument()
            case "author": document.authors = argument()
            case "date": document.date = argument() ?? ""
            case "newcommand", "renewcommand", "providecommand": define(name)
            case "def": defineTeXMacro()
            case "DeclareMathOperator": declareOperator()
            case "definecolor": defineColor()
            case "graphicspath": document.graphicsPaths = graphicsPaths(argument() ?? "")
            default: break
            }
        }
    }

    private func controlTokenName() -> Substring {
        let start = index
        while let character = peek(), character.isASCII, character.isLetter { index += 1 }
        if index == start, peek() != nil { index += 1 }
        return Substring(String(characters[start..<index]))
    }

    private func define(_ command: String) {
        _ = star()
        skipSpaces()
        let name: String
        if peek() == "{" {
            index += 1
            name = balanced().trimmingCharacters(in: .whitespaces)
        } else {
            name = controlToken()
        }
        guard name.hasPrefix("\\"), name.count > 1 else { return }
        let count = optional().map { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let defaultArgument = (count ?? 0) > 0 ? optional() : nil
        let body = argument() ?? ""
        // TeX allows nine parameters; anything else is not a definition to follow.
        guard let parameters = count, (0...9).contains(parameters) else { return }
        let key = String(name.dropFirst())
        if command == "providecommand", document.macros[key] != nil { return }
        document.macros[key] = .init(parameters: parameters, defaultArgument: defaultArgument, body: body)
        let math =
            defaultArgument.map { "\\newcommand{\(name)}[\(parameters)][\($0)]{\(body)}" }
            ?? "\\def\(name)" + (0..<parameters).map { "#\($0 + 1)" }.joined() + "{\(body)}"
        addMathDefinition(math)
    }

    private func defineTeXMacro() {
        let name = controlToken()
        guard name.count > 1 else { return }
        var parameters = 0
        while let character = peek(), character != "{" {
            if character == "#" { parameters += 1 }
            index += 1
        }
        let body = argument() ?? ""
        guard parameters <= 9 else { return }
        document.macros[String(name.dropFirst())] = .init(parameters: parameters, defaultArgument: nil, body: body)
        addMathDefinition("\\def\(name)" + (0..<parameters).map { "#\($0 + 1)" }.joined() + "{\(body)}")
    }

    private func declareOperator() {
        let limits = star()
        guard let name = argument()?.trimmingCharacters(in: .whitespaces), name.hasPrefix("\\") else { return }
        let text = argument() ?? ""
        addMathDefinition("\\def\(name){\\operatorname\(limits ? "*" : ""){\(text)}}")
    }

    /// A definition every formula starts with; one SwaTex cannot read is left out, so it cannot break the others.
    private func addMathDefinition(_ definition: String) {
        guard MathRenderer.html("x", display: false, macros: document.mathDefinitions + definition) != nil else {
            return
        }
        document.mathDefinitions += definition
    }

    /// `\graphicspath{{figures/}{images/}}`: folders, relative to the document, where images are looked up.
    private func graphicsPaths(_ argument: String) -> [String] {
        argument.split(separator: "}").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "{ \n\t")) }
            .filter { !$0.isEmpty }
    }

    private func defineColor() {
        guard let name = argument()?.trimmingCharacters(in: .whitespaces), let model = argument(),
            let spec = argument(),
            let rgb = LaTeXSymbols.rgb(
                spec, model: model.trimmingCharacters(in: .whitespaces), defined: document.colors)
        else { return }
        document.colors[name] = rgb
    }

    // MARK: - Structure

    private func section(_ name: String) {
        let starred = star()
        _ = optional()
        let title = inline(argument() ?? "")
        if name == "part" {
            document.partCounter += 1
            let numeral = LaTeXSymbols.format(document.partCounter, as: "Roman")
            let label = document.isJapanese ? "第\(numeral)部" : "Part \(numeral)"
            let id = "part-\(document.partCounter)"
            document.labelTarget = (numeral, id)
            appendBlock(
                "<h2 class=\"latex-part\" id=\"\(id)\">\(starred ? "" : "<span class=\"secnum\">\(label)</span>")\(title)</h2>\n"
            )
            return
        }
        let levels = ["chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph"]
        let level = levels.firstIndex(of: name) ?? 1
        let first = document.hasChapters ? 0 : 1
        let deepestNumbered = document.hasChapters ? 2 : 3
        var number: String?
        var display: String?
        if !starred, level <= deepestNumbered, level >= first {
            document.sectionCounters[level] += 1
            for deeper in (level + 1)..<document.sectionCounters.count { document.sectionCounters[deeper] = 0 }
            let parts = (first...level).map { position -> String in
                let value = document.sectionCounters[position]
                return document.isAppendix && position == first ? LaTeXSymbols.format(value, as: "Alph") : String(value)
            }
            number = parts.joined(separator: ".")
            if level == 0, let chapter = number {
                display =
                    document.isAppendix
                    ? (document.isJapanese ? "付録\(chapter)" : "Appendix \(chapter)")
                    : (document.isJapanese ? "第\(chapter)章" : "Chapter \(chapter)")
            } else {
                display = number
            }
        }
        let id =
            number.map { "sec-" + $0.replacingOccurrences(of: ".", with: "-") }
            ?? "sec-u\(document.headings.count + 1)"
        let tag = min(level - first + 2, 6)
        document.headings.append(.init(level: level, number: number, id: id, title: title))
        if let number { document.labelTarget = (number, id) }
        let numberHTML = display.map { "<span class=\"secnum\">\(HTML.escape($0))</span>" } ?? ""
        appendBlock("<h\(tag) id=\"\(id)\">\(numberHTML)\(title)</h\(tag)>\n")
    }

    private func titleBlock() -> String {
        var html = "<header class=\"latex-title-block\">\n"
        if let title = document.title {
            let titleHTML = inline(title)
            document.titleHTML = titleHTML
            html += "<h1 class=\"latex-title\">\(titleHTML)</h1>\n"
        }
        if let authors = document.authors?.trimmingCharacters(in: .whitespacesAndNewlines), !authors.isEmpty {
            let names = authors.components(separatedBy: "\\and").map {
                "<span class=\"latex-author-name\">\(inline($0))</span>"
            }
            html += "<p class=\"latex-author\">\(names.joined())</p>\n"
        }
        let date = document.date.map { inline($0) } ?? HTML.escape(document.today())
        if !date.isEmpty { html += "<p class=\"latex-date\">\(date)</p>\n" }
        return html + "</header>\n"
    }

    private func label() {
        let key = argument()?.trimmingCharacters(in: .whitespaces) ?? ""
        if let target = document.labelTarget, !key.isEmpty { document.labels[key] = target }
    }

    private func footnote() {
        _ = optional()
        let text = argument() ?? ""
        document.footnotes.append("")
        let number = document.footnotes.count
        // Reserved first, so a note inside the note numbers after it.
        document.footnotes[number - 1] = blocks(text)
        appendHTML(
            "<sup class=\"footnote-ref\"><a href=\"#fn-\(number)\" id=\"fnref-\(number)\">\(number)</a></sup>")
    }

    private func unsupported(_ message: String) -> String {
        "<div class=\"latex-unsupported\">\(HTML.escape(message))</div>\n"
    }

    // MARK: - Links and colors

    private func unescapedURL(_ url: String) -> String {
        var result = ""
        var escaped = false
        for character in url.trimmingCharacters(in: .whitespacesAndNewlines) {
            if escaped || character != "\\" {
                result.append(character)
                escaped = false
            } else {
                escaped = true
            }
        }
        return result
    }

    private func link() {
        let url = unescapedURL(argument(comments: false) ?? "")
        let text = inline(argument() ?? "")
        appendHTML("<a href=\"\(HTML.escape(url))\">\(text)</a>")
    }

    private func color() -> String? {
        let model = optional()?.trimmingCharacters(in: .whitespaces)
        guard let spec = argument() else { return nil }
        return LaTeXSymbols.cssColor(spec, model: model, defined: document.colors)
    }

    private func coloredText() {
        let css = color()
        let text = inline(argument() ?? "")
        appendHTML(css.map { "<span style=\"color: \($0)\">\(text)</span>" } ?? text)
    }

    private func colorDeclaration() {
        guard let css = color() else { return }
        appendHTML("<span style=\"color: \(css)\">", last: lastCharacter)
        openDeclarations.append("</span>")
    }

    private func colorBox(framed: Bool) {
        let frame = framed ? color() : nil
        let background = color()
        let text = inline(argument() ?? "")
        var style = background.map { "background: \($0); " } ?? ""
        if let frame { style += "border: 0.5pt solid \(frame); " }
        appendHTML(
            "<span class=\"latex-colorbox\" style=\"\(style)\">\(text)</span>")
    }

    // MARK: - Verbatim and code

    private func verbatimInline() {
        _ = star()
        guard let delimiter = peek() else { return }
        index += 1
        var text = ""
        while let character = peek(), character != delimiter, character != "\n" {
            text.append(character)
            index += 1
        }
        if peek() == delimiter { index += 1 }
        appendHTML("<code>\(HTML.escape(text))</code>")
    }

    /// The source up to `\end{name}`, as written: verbatim environments do not nest.
    private func verbatimBody(_ name: String) -> String {
        let end = Array("\\end{\(name)}")
        let start = index
        while index < characters.count {
            if characters[index] == "\\", index + end.count <= characters.count,
                Array(characters[index..<(index + end.count)]) == end
            {
                let body = String(characters[start..<index])
                index += end.count
                return body
            }
            index += 1
        }
        return String(characters[start...])
    }

    private func codeBlock(_ code: String, language: String?) -> String {
        var lines = code
        if lines.hasPrefix("\n") { lines.removeFirst() }
        while lines.hasSuffix("\n") || lines.hasSuffix(" ") { lines.removeLast() }
        let name = language?.lowercased()
        let highlighted = name.flatMap { SyntaxHighlighter.highlight(lines, language: $0) }
        let attribute =
            name.map { " class=\"language-\(HTML.escape($0))\(highlighted == nil ? "" : " hl")\"" } ?? ""
        return "<pre><code\(attribute)>\(highlighted ?? HTML.escape(lines))</code></pre>\n"
    }

    /// A key's value in a `key=value` list such as listings' and graphicx's options.
    private func option(_ key: String, in options: String?) -> String? {
        guard let options else { return nil }
        var depth = 0
        var current = ""
        var parts: [String] = []
        for character in options {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == "," && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == key {
                var value = pair[1]
                if value.hasPrefix("{"), value.hasSuffix("}") { value = String(value.dropFirst().dropLast()) }
                return value
            }
        }
        return nil
    }

    // MARK: - Math

    private func dollarMath() {
        index += 1
        if peek() == "$" {
            index += 1
            displayMath(closing: "$$")
        } else {
            inlineMath(closing: "$")
        }
    }

    /// The math source up to the closing delimiter; comments are dropped and escapes kept.
    private func mathSource(closing: String) -> String {
        let closer = Array(closing)
        var text = ""
        while index < characters.count {
            if index + closer.count <= characters.count, Array(characters[index..<(index + closer.count)]) == closer {
                index += closer.count
                return text
            }
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                text += String(characters[index...(index + 1)])
                index += 2
                continue
            }
            if character == "%" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            text.append(character)
            index += 1
        }
        return text
    }

    private func formula(_ latex: String, display: Bool, source: String) -> String {
        MathRenderer.html(latex, display: display, macros: document.mathDefinitions)
            ?? MathRenderer.fallback(source, display: display)
    }

    private func inlineMath(closing: String) {
        let opening = closing == "$" ? "$" : "\\("
        let latex = mathSource(closing: closing)
        appendHTML(formula(latex, display: false, source: opening + latex + closing))
    }

    private func displayMath(closing: String) {
        let opening = closing == "$$" ? "$$" : "\\["
        let latex = mathSource(closing: closing)
        appendBlock(
            "<div class=\"math-block\">\(formula(latex, display: true, source: opening + latex + closing))</div>\n")
    }

    private static let mathEnvironments: [String: (String, String)?] = [
        "equation": nil, "displaymath": nil, "multline": ("\\begin{gathered}", "\\end{gathered}"),
        "align": ("\\begin{aligned}", "\\end{aligned}"), "flalign": ("\\begin{aligned}", "\\end{aligned}"),
        "alignat": ("\\begin{aligned}", "\\end{aligned}"), "gather": ("\\begin{gathered}", "\\end{gathered}"),
        "eqnarray": ("\\begin{aligned}", "\\end{aligned}"),
    ]

    /// Environments whose every row is numbered, as amsmath numbers align and gather.
    private static let numberedRows: Set<String> = ["align", "flalign", "alignat", "gather", "eqnarray"]

    private static let labelPattern = try? NSRegularExpression(pattern: #"\\label\s*\{([^}]*)\}"#)
    private static let tagPattern = try? NSRegularExpression(pattern: #"\\tag\*?\s*\{([^}]*)\}"#)

    /// The text of a formula's own `\tag{…}`, which its `\label` then names.
    private static func explicitTag(_ latex: String) -> String? {
        let nsLatex = latex as NSString
        guard let match = tagPattern?.firstMatch(in: latex, range: NSRange(location: 0, length: nsLatex.length)) else {
            return nil
        }
        return nsLatex.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }

    /// An anchor for a formula with its own tag, and its labels pointing at the tag.
    private func registerTag(_ tag: String, labels: [String]) -> String {
        document.taggedCount += 1
        let id = "eq-t\(document.taggedCount)"
        for key in labels where !key.isEmpty { document.labels[key] = (tag, id) }
        document.labelTarget = (tag, id)
        return id
    }

    /// A display environment of amsmath. An unstarred equation or multline gets the next equation number at the
    /// right; an unstarred align or gather numbers each row (SwaTex draws `\tag` beside the row), skipping rows with
    /// `\notag` and keeping a row's own `\tag`. A `\label` names the number of its row.
    private func mathEnvironment(_ name: String, body: String) {
        let starred = name.hasSuffix("*")
        let base = starred ? String(name.dropLast()) : name
        var latex = Self.withoutComments(body)
        // alignat's column count is not part of the formula.
        if base == "alignat", latex.drop(while: \.isWhitespace).first == "{", let close = latex.firstIndex(of: "}") {
            latex = String(latex[latex.index(after: close)...])
        }
        let wrapper = Self.mathEnvironments[base] ?? nil
        let source = "\\begin{\(name)}\(body)\\end{\(name)}"
        func render(_ formula: String) -> String {
            self.formula(wrapper.map { $0.0 + formula + $0.1 } ?? formula, display: true, source: source)
        }
        if Self.numberedRows.contains(base) {
            var anchors = ""
            var rows = Self.rows(of: latex)
            for position in rows.indices {
                var (row, labels) = Self.removingLabels(rows[position])
                // eqnarray's three columns read as align's two: `a & = & b` becomes `a &= b`.
                if base == "eqnarray", let first = row.firstIndex(of: "&"),
                    let second = row[row.index(after: first)...].firstIndex(of: "&")
                {
                    row.remove(at: second)
                }
                let skipped = row.contains("\\notag") || row.contains("\\nonumber")
                row = row.replacingOccurrences(of: "\\nonumber", with: "").replacingOccurrences(of: "\\notag", with: "")
                let isEmpty = row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if let tag = Self.explicitTag(row) {
                    anchors += "<span id=\"\(registerTag(tag, labels: labels))\"></span>"
                } else if !starred, !skipped, !isEmpty {
                    document.equationCount += 1
                    let number = String(document.equationCount)
                    let id = "eq-\(number)"
                    row += "\\tag{\(number)}"
                    anchors += "<span id=\"\(id)\"></span>"
                    for key in labels where !key.isEmpty { document.labels[key] = (number, id) }
                    document.labelTarget = (number, id)
                }
                rows[position] = row
            }
            appendBlock("<div class=\"math-block\">\(anchors)\(render(rows.joined(separator: "\\\\")))</div>\n")
            return
        }
        let (formula, labels) = Self.removingLabels(
            latex.replacingOccurrences(of: "\\nonumber", with: "").replacingOccurrences(of: "\\notag", with: ""))
        let rendered = render(formula)
        if let tag = Self.explicitTag(formula) {
            appendBlock("<div class=\"math-block\" id=\"\(registerTag(tag, labels: labels))\">\(rendered)</div>\n")
            return
        }
        guard !starred, base != "displaymath" else {
            appendBlock("<div class=\"math-block\">\(rendered)</div>\n")
            return
        }
        document.equationCount += 1
        let number = String(document.equationCount)
        let id = "eq-\(number)"
        for key in labels where !key.isEmpty { document.labels[key] = (number, id) }
        document.labelTarget = (number, id)
        appendBlock(
            "<div class=\"math-block latex-equation\" id=\"\(id)\">\(rendered)<span class=\"eqno\">(\(number))</span></div>\n"
        )
    }

    /// Each line without its comment; an escaped percent sign stays.
    private static func withoutComments(_ latex: String) -> String {
        latex.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var result = ""
            var escaped = false
            for character in line {
                if character == "%" && !escaped { break }
                escaped = character == "\\" && !escaped
                result.append(character)
            }
            return result
        }.joined(separator: "\n")
    }

    private static func removingLabels(_ latex: String) -> (String, [String]) {
        guard let labelPattern else { return (latex, []) }
        let nsLatex = latex as NSString
        let range = NSRange(location: 0, length: nsLatex.length)
        let labels = labelPattern.matches(in: latex, range: range).map {
            nsLatex.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
        return (labelPattern.stringByReplacingMatches(in: latex, range: range, withTemplate: ""), labels)
    }

    /// The rows of an alignment, split at `\\\\` outside braces; a spacing such as `\\\\[2pt]` stays with its row.
    private static func rows(of latex: String) -> [String] {
        let characters = Array(latex)
        var rows: [String] = []
        var current = ""
        var depth = 0
        var environments = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                // A matrix or cases inside the alignment keeps its own rows.
                if let word = LaTeXLexer.word(characters, at: index + 1) {
                    if word == "begin" { environments += 1 }
                    if word == "end" { environments -= 1 }
                }
                if characters[index + 1] == "\\" && depth == 0 && environments == 0 {
                    rows.append(current)
                    current = ""
                    index += 2
                    if index < characters.count, characters[index] == "[",
                        let close = characters[index...].firstIndex(of: "]")
                    {
                        index = close + 1
                    }
                    continue
                }
                current += String(characters[index...(index + 1)])
                index += 2
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            current.append(character)
            index += 1
        }
        rows.append(current)
        return rows
    }

    // MARK: - Environments

    private func environment() {
        guard let name = argument()?.trimmingCharacters(in: .whitespaces) else { return }
        switch name {
        case "verbatim", "verbatim*", "Verbatim", "alltt":
            if name == "Verbatim" { _ = optionalOnLine() }
            appendBlock(codeBlock(verbatimBody(name), language: nil))
        case "lstlisting":
            let options = optionalOnLine()
            appendBlock(codeBlock(verbatimBody(name), language: option("language", in: options)))
        case "minted":
            _ = optional()
            let language = argument()
            appendBlock(codeBlock(verbatimBody(name), language: language))
        case "comment":
            _ = verbatimBody(name)
        default:
            let body = environmentBody(name)
            environment(name, body: body)
        }
    }

    /// An optional argument only on the line that opens an environment, so a body starting with `[` stays text.
    private func optionalOnLine() -> String? {
        var lookahead = index
        while lookahead < characters.count, characters[lookahead] == " " || characters[lookahead] == "\t" {
            lookahead += 1
        }
        guard lookahead < characters.count, characters[lookahead] == "[" else { return nil }
        index = lookahead
        return optional()
    }

    /// The source up to the `\end` that matches the environment just opened.
    private func environmentBody(_ name: String) -> String {
        let begin = Array("\\begin{\(name)}")
        let end = Array("\\end{\(name)}")
        var depth = 1
        let start = index
        while index < characters.count {
            let character = characters[index]
            if let opaque = LaTeXLexer.opaqueEnd(characters, at: index) {
                index = max(opaque, index + 1)
                continue
            }
            if character == "\\" {
                if index + end.count <= characters.count, Array(characters[index..<(index + end.count)]) == end {
                    depth -= 1
                    if depth == 0 {
                        let body = String(characters[start..<index])
                        index += end.count
                        return body
                    }
                    index += end.count
                    continue
                }
                if index + begin.count <= characters.count,
                    Array(characters[index..<(index + begin.count)]) == begin
                {
                    depth += 1
                    index += begin.count
                    continue
                }
                index += 2
                continue
            }
            index += 1
        }
        return String(characters[start...])
    }

    private static let unsupportedEnvironments: Set<String> = [
        "tikzpicture", "pgfpicture", "axis", "semilogxaxis", "semilogyaxis", "loglogaxis", "polaraxis",
        "circuitikz", "forest", "tikzcd", "pspicture", "picture",
    ]

    private func environment(_ name: String, body: String) {
        let base = name.hasSuffix("*") ? String(name.dropLast()) : name
        if Self.mathEnvironments.keys.contains(base) || base == "alignat" {
            mathEnvironment(name, body: body)
            return
        }
        switch base {
        case "math":
            appendHTML(formula(body, display: false, source: "\\begin{math}\(body)\\end{math}"))
        case "itemize", "enumerate", "description":
            let reader = LaTeXReader(body, document: document, isBlock: false)
            let options = reader.optionalOnLine()
            appendBlock(list(base, options: options, body: reader.rest))
        case "quote", "quotation":
            appendBlock("<blockquote>\n\(blocks(body))</blockquote>\n")
        case "verse":
            appendBlock("<blockquote class=\"latex-verse\">\n\(blocks(body))</blockquote>\n")
        case "center", "flushleft", "flushright":
            appendBlock("<div class=\"latex-\(base)\">\n\(blocks(body))</div>\n")
        case "abstract":
            let heading = document.isJapanese ? "概要" : "Abstract"
            appendBlock(
                "<div class=\"abstract\">\n<p class=\"abstract-title\">\(heading)</p>\n\(blocks(body))</div>\n")
        case "figure", "table", "wrapfigure", "wraptable", "SCfigure":
            float(base == "table" || base == "wraptable" ? "table" : "figure", body: body)
        case "tabular", "tabularx", "tabulary", "longtable", "tabu":
            appendBlock(tabular(base, body: body))
        case "minipage":
            let reader = LaTeXReader(body, document: document, isBlock: false)
            _ = reader.optional()
            _ = reader.argument()
            appendBlock("<div class=\"latex-minipage\">\n\(blocks(reader.rest))</div>\n")
        default:
            if Self.unsupportedEnvironments.contains(base) {
                appendBlock(
                    unsupported(
                        document.isJapanese ? "TikZ などの図（Surimono では描けません）" : "TikZ picture (Surimono cannot draw it)"))
            } else {
                appendBlock(blocks(body))
            }
        }
    }

    // MARK: - Lists

    private func list(_ kind: String, options: String?, body: String) -> String {
        let items = Self.items(of: body)
        switch kind {
        case "itemize":
            let html = items.map { label, content -> String in
                let text = compact(blocks(content))
                guard let label else { return "<li>\(text)</li>\n" }
                return
                    "<li class=\"latex-custom-label\">\(labeled(inline(label), text))</li>\n"
            }
            return "<ul>\n\(html.joined())</ul>\n"
        case "description":
            let html = items.map { label, content in
                "<dt>\(inline(label ?? ""))</dt>\n<dd>\(compact(blocks(content)))</dd>\n"
            }
            return "<dl class=\"latex-description\">\n\(html.joined())</dl>\n"
        default:
            document.enumerateDepth += 1
            defer { document.enumerateDepth -= 1 }
            let (template, style, start) = enumerateStyle(options)
            var value = start - 1
            let html = items.map { label, content -> String in
                value += 1
                let number = LaTeXSymbols.format(value, as: style)
                document.itemCount += 1
                let id = "item-\(document.itemCount)"
                document.labelTarget = (number, id)
                let marker =
                    label.map { inline($0) } ?? inline(template.replacingOccurrences(of: "\u{E000}", with: number))
                return "<li id=\"\(id)\">\(labeled(marker, compact(blocks(content))))</li>\n"
            }
            return "<ol class=\"latex-enumerate\">\n\(html.joined())</ol>\n"
        }
    }

    /// An item's label in front of its text: inside its first paragraph, so the two stay on one line.
    private func labeled(_ marker: String, _ content: String) -> String {
        let label = "<span class=\"item-label\">\(marker)</span>"
        return content.hasPrefix("<p>") ? "<p>" + label + content.dropFirst(3) : label + content
    }

    /// The label template (with U+E000 where the number goes), the counter style and the first number, from
    /// enumitem's `label=` and `start=` or from the enumerate package's `[(a)]`.
    private func enumerateStyle(_ options: String?) -> (String, String, Int) {
        let defaults = [("\u{E000}.", "arabic"), ("(\u{E000})", "alph"), ("\u{E000}.", "roman"), ("\u{E000}.", "Alph")]
        var (template, style) = defaults[min(max(document.enumerateDepth - 1, 0), 3)]
        let start = min(max(option("start", in: options).flatMap { Int($0) } ?? 1, -1_000_000), 1_000_000)
        let counters = [
            "\\arabic*": "arabic", "\\alph*": "alph", "\\Alph*": "Alph", "\\roman*": "roman", "\\Roman*": "Roman",
        ]
        if let label = option("label", in: options) {
            for (command, name) in counters where label.contains(command) {
                template = label.replacingOccurrences(of: command, with: "\u{E000}")
                style = name
            }
        } else if let options, !options.contains("="), !options.trimmingCharacters(in: .whitespaces).isEmpty {
            let letters: [(Character, String)] = [
                ("1", "arabic"), ("a", "alph"), ("A", "Alph"), ("i", "roman"), ("I", "Roman"),
            ]
            if let position = options.firstIndex(where: { character in letters.contains { $0.0 == character } }),
                let match = letters.first(where: { $0.0 == options[position] })
            {
                template = options.replacingCharacters(in: position...position, with: "\u{E000}")
                style = match.1
            }
        }
        return (template, style, start)
    }

    /// The items of a list body, split at each `\item` outside nested groups and environments, with the label
    /// written in brackets after it.
    private static func items(of body: String) -> [(label: String?, content: String)] {
        let characters = Array(body)
        var items: [(String?, String)] = []
        var current: [Character]?
        var braces = 0
        var environments = 0
        var index = 0
        func matches(_ word: String, at position: Int) -> Bool {
            let word = Array(word)
            return position + word.count <= characters.count
                && Array(characters[position..<(position + word.count)]) == word
        }
        while index < characters.count {
            let character = characters[index]
            if let opaque = LaTeXLexer.opaqueEnd(characters, at: index) {
                let end = max(opaque, index + 1)
                current?.append(contentsOf: characters[index..<end])
                index = end
                continue
            }
            if character == "\\" {
                if matches("\\begin{", at: index) {
                    environments += 1
                } else if matches("\\end{", at: index) {
                    environments -= 1
                } else if braces == 0, environments == 0, matches("\\item", at: index),
                    !(index + 5 < characters.count && characters[index + 5].isASCII && characters[index + 5].isLetter)
                {
                    if let current { items.append((nil, String(current))) }
                    current = []
                    index += 5
                    continue
                }
                current?.append(character)
                if index + 1 < characters.count { current?.append(characters[index + 1]) }
                index += 2
                continue
            }
            if character == "{" { braces += 1 }
            if character == "}" { braces -= 1 }
            current?.append(character)
            index += 1
        }
        if let current { items.append((nil, String(current))) }
        return items.map { _, content in
            let reader = LaTeXReader(content, document: LaTeXDocument(), isBlock: false)
            let label = reader.optional()
            return (label, reader.rest)
        }
    }

    // MARK: - Floats, images and tables

    private func float(_ kind: String, body: String) {
        let reader = LaTeXReader(body, document: document, isBlock: true)
        _ = reader.optionalOnLine()
        reader.floatKind = kind
        let inside = reader.read()
        appendBlock("<figure class=\"latex-\(kind)\">\n\(inside)</figure>\n")
    }

    private func caption() {
        _ = optional()
        let text = inline(argument() ?? "")
        let kind = floatKind ?? "figure"
        let number: Int
        if kind == "table" {
            document.tableCount += 1
            number = document.tableCount
        } else {
            document.figureCount += 1
            number = document.figureCount
        }
        let id = "\(kind == "table" ? "tab" : "fig")-\(number)"
        document.labelTarget = (String(number), id)
        let name = kind == "table" ? (document.isJapanese ? "表" : "Table") : (document.isJapanese ? "図" : "Figure")
        let separator = document.isJapanese ? "　" : ": "
        appendBlock(
            "<figcaption id=\"\(id)\"><span class=\"latex-caption-label\">\(name) \(number)</span>\(separator)\(text)</figcaption>\n"
        )
    }

    private func image() -> String {
        let options = optional()
        let file = argument()?.trimmingCharacters(in: .whitespaces) ?? ""
        var style: [String] = []
        if let width = option("width", in: options).flatMap(LaTeXSymbols.cssLength) { style.append("width: \(width)") }
        if let height = option("height", in: options).flatMap(LaTeXSymbols.cssLength) {
            style.append("height: \(height)")
        }
        if let scale = option("scale", in: options).flatMap(Double.init), scale.isFinite, scale > 0, scale <= 100 {
            style.append("zoom: \(String(format: "%g", scale))")
        }
        let source = document.imageSource(file)
        let attributes = style.isEmpty ? "" : " style=\"\(style.joined(separator: "; "))\""
        return "<img class=\"latex-graphic\" src=\"\(HTML.escape(source))\" alt=\"\"\(attributes)>"
    }

    private func tabular(_ name: String, body: String) -> String {
        let reader = LaTeXReader(body, document: document, isBlock: false)
        if name == "tabularx" || name == "tabulary" || name == "tabu" { _ = reader.argument() }
        _ = reader.optional()
        let spec = reader.argument() ?? ""
        let rest = reader.rest
        return LaTeXTable(spec: spec, body: rest).html { [self] in inline($0) }
    }
}

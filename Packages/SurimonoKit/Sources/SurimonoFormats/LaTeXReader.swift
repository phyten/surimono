import Foundation

/// Reads LaTeX source into HTML. A block reader makes paragraphs and blocks; an inline reader makes the text of one
/// argument or group. Readers for nested groups and environments share the document's state.
final class LaTeXReader {
    private enum Space {
        case space
        case newline
    }

    let document: LaTeXDocument
    var characters: [Character]
    var index = 0
    // Distances from the end remain valid when a replacement is inserted before its caller returns.
    var macroFrameEnds: [Int] = []
    // Like macro frames, input boundaries follow the unchanged tail when more tokens are inserted.
    var fileFrames: [(tail: Int, chainDepth: Int)] = []
    let isBlock: Bool
    private var output = ""
    private var boxes = ""
    private var boxFill = false
    private var pendingFill = false
    private var paragraph = ""
    private var newlines = 0
    private var pendingSpace: Space?
    /// Block HTML can interrupt a TeX paragraph without ending it. A blank line or explicit paragraph
    /// break cancels the continuation; otherwise the next HTML paragraph starts flush with the text.
    private var noParagraphIndent = false
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

    var inPreamble = false

    func read() -> String {
        document.depth += 1
        defer { document.depth -= 1 }
        // Every group and environment is read by a reader of its own. Source nested deeper than any real document
        // would exhaust the stack, so past the limit it prints as text.
        guard document.depth <= LaTeXDocument.maximumDepth else {
            document.stopsExpanding = true
            let text = HTML.escape(String(characters))
            return isBlock ? "<p>\(text)</p>\n" : text
        }
        let startingChain = document.inputChain
        defer { document.inputChain = startingChain }
        while !document.endedDocument, let character = peek() { step(character) }
        if isBlock {
            flush()
            return output
        }
        finishBoxes()
        closeDeclarations()
        return paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Characters

    func peek(_ offset: Int = 0) -> Character? {
        index + offset < characters.count ? characters[index + offset] : nil
    }

    func step(_ character: Character) {
        retireFileFrames()
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
    func skipComment() {
        while let character = peek(), character != "\n" { index += 1 }
        if peek() == "\n" { index += 1 }
        while peek() == " " || peek() == "\t" { index += 1 }
    }

    /// The source not read yet.
    var rest: String { index < characters.count ? String(characters[index...]) : "" }

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

    /// Keep neighboring boxes in one line box. Justification stretches only the spaces inserted by hfill,
    /// so their own paragraphs retain their normal type and alignment without a paginated flex container.
    func appendLayoutBox(_ html: String) {
        if boxes.isEmpty && isBlock { flush() }
        if pendingFill && !boxes.isEmpty {
            boxes += " "
            boxFill = true
        }
        boxes += html
        pendingFill = false
        newlines = 0
        pendingSpace = nil
    }

    private func finishBoxes() {
        guard !boxes.isEmpty else { return }
        let fill = boxFill ? " latex-box-fill" : ""
        let html = "<div class=\"latex-box-row\(fill)\">\(boxes)</div>\n"
        if isBlock {
            output += html
            noParagraphIndent = true
        } else {
            paragraph += html
        }
        boxes = ""
        boxFill = false
        pendingFill = false
    }

    private func startContent() {
        finishBoxes()
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

    func appendText(_ text: String) {
        let text = document.uppercase.map { $0 ? text.uppercased() : text.lowercased() } ?? text
        guard let first = text.first else { return }
        startContent()
        paragraph += pendingSeparator(before: first) + HTML.escape(text)
        lastCharacter = text.last
    }

    func appendHTML(_ html: String, last: Character? = "x") {
        guard !html.isEmpty else { return }
        startContent()
        paragraph += pendingSeparator(before: html.first) + html
        lastCharacter = last
    }

    func appendBlock(_ html: String, continuesParagraph: Bool = false) {
        startContent()
        if isBlock {
            flush()
            output += html
            noParagraphIndent = continuesParagraph
        } else {
            paragraph += html
        }
        pendingSpace = nil
    }

    func paragraphBreak() {
        if isBlock {
            flush()
        } else if pendingSpace == nil {
            pendingSpace = .space
        }
    }

    /// An environment is a TeX group even when it contributes only part of the surrounding paragraph.
    func readEnvironmentGroup(_ source: String) {
        let previous = (
            document.macros, document.environments, document.mathDefinitions, document.highlightColor,
            document.referenceNames
        )
        let outer = openDeclarations.count
        let printed = output.utf8.count
        readExpansionBody(source)
        (
            document.macros, document.environments, document.mathDefinitions, document.highlightColor,
            document.referenceNames
        ) = previous
        // A block within the environment may already have closed the outer paragraph and all its declarations.
        let retain = printed == output.utf8.count ? min(outer, openDeclarations.count) : 0
        paragraph += openDeclarations[retain...].reversed().joined()
        openDeclarations.removeLast(openDeclarations.count - retain)
    }

    private func closeDeclarations() {
        paragraph += openDeclarations.reversed().joined()
        openDeclarations = []
    }

    private func flush() {
        finishBoxes()
        closeDeclarations()
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let attribute = noParagraphIndent ? " class=\"latex-noindent\"" : ""
            output += "<p\(attribute)>\(text)</p>\n"
        }
        noParagraphIndent = false
        paragraph = ""
        pendingSpace = nil
        lastCharacter = nil
        newlines = 0
    }

    func inline(_ text: String) -> String {
        let reader = LaTeXReader(text, document: document, isBlock: false)
        reader.floatKind = floatKind
        return reader.read()
    }

    /// A styled group may end with actual interword glue. Inspect what the reader consumed,
    /// not the last source character: a comment and its newline do not contribute a space.
    private func styledInline(_ source: String) -> String {
        let reader = LaTeXReader(source, document: document, isBlock: false)
        reader.floatKind = floatKind
        let html = reader.read()
        let trailing = reader.pendingSpace != nil || reader.paragraph.last?.isWhitespace == true
        return trailing && !html.isEmpty ? html + " " : html
    }

    func blocks(_ text: String) -> String {
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

    func skipSpaces() {
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
    func balanced(open: Character = "{", close: Character = "}", comments: Bool = true) -> String {
        var depth = 1
        var text: [Character] = []
        while let character = peek() {
            if comments, character == "\\", let end = LaTeXLexer.opaqueEnd(characters, at: index) {
                text.append(contentsOf: characters[index..<end])
                index = end
                continue
            }
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
    func argument(comments: Bool = true) -> String? {
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

    func optional() -> String? {
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

    func star() -> Bool {
        guard peek() == "*" else { return false }
        index += 1
        return true
    }

    func controlToken() -> String {
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
        retireMacroFrames()
        index += 1
        guard let next = peek() else { return }
        guard next.isASCII, next.isLetter else {
            index += 1
            if document.macros[String(next)] != nil {
                _ = handleMacro(String(next))
            } else {
                controlSymbol(next)
            }
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
    func skipSpacesAfterControlWord() {
        while peek() == " " || peek() == "\t" { index += 1 }
        guard peek() == "\n" else { return }
        var lookahead = index + 1
        while lookahead < characters.count, characters[lookahead] == " " || characters[lookahead] == "\t" {
            lookahead += 1
        }
        if lookahead < characters.count, characters[lookahead] == "\n" { return }
        index = lookahead
    }

    func controlSymbol(_ symbol: Character) {
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
                document.recordUnknown("\\" + String(symbol))
                appendText(String(symbol))
                readUnknownArguments()
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

    func dispatch(_ name: String) {
        if handleMacro(name) { return }
        dispatchBuiltin(name)
    }

    func dispatchBuiltin(_ name: String) {
        if handleFileCommand(name) { return }
        if handleControl(name) || handleCounter(name) || handleText(name) || handleReference(name) { return }
        switch name {
        case "begin": environment()
        case "documentclass": readDocumentClass()
        case "end":
            if argument() == "document", document.startedDocument { document.endedDocument = true }
        case "part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph":
            section(name)
        case "maketitle":
            guard !document.makingTitle else { break }
            document.makingTitle = true
            appendBlock(titleBlock())
            document.makingTitle = false
        case "tableofcontents": appendBlock(document.placeholder("T", 0))
        case "title": document.title = argument()
        case "author": document.authors = argument()
        case "date": document.date = argument() ?? ""
        case "today": appendText(document.today())
        case "label": label()
        case "cite", "citep", "citet", "parencite", "textcite", "autocite", "citeauthor", "citeyear": cite(name)
        case "bibliography", "printbibliography", "addbibresource", "bibliographystyle", "setcitestyle", "nocite":
            externalBibliography(name)
        case "usepackage", "RequirePackage": readPackage()
        case "qed", "qedsymbol": appendText("□")
        case "qedhere": break
        case "num":
            _ = optional()
            appendHTML(LaTeXUnits.numberHTML(argument() ?? ""))
        case "qty", "SI":
            _ = optional()
            let value = argument() ?? ""
            let before = name == "SI" ? optional() : nil
            let unit = argument() ?? ""
            appendHTML(
                (before.map { LaTeXUnits.unitHTML($0) + "\u{202F}" } ?? "") + LaTeXUnits.numberHTML(value)
                    + "\u{202F}" + LaTeXUnits.unitHTML(unit))
        case "unit", "si":
            _ = optional()
            appendHTML(LaTeXUnits.unitHTML(argument() ?? ""))
        case "ang":
            _ = optional()
            appendHTML(LaTeXUnits.angleHTML(argument() ?? ""))
        case "href": link()
        case "url", "nolinkurl":
            let url = unescapedURL(argument(comments: false) ?? "")
            appendHTML("<a class=\"latex-url\" href=\"\(HTML.escape(url))\">\(HTML.escape(url))</a>")
        case "path":
            appendHTML("<code>\(HTML.escape(unescapedURL(argument(comments: false) ?? "")))</code>")
        case "verb":
            _ = star()
            appendHTML(listingInline(delimitedCode(), language: nil))
        case "lstset", "lstdefinestyle": configureListings(name)
        case "lstinputlisting", "inputminted": readListingFile(name)
        case "lstinline", "mintinline":
            readInlineListing(name)
        case "textcolor": coloredText()
        case "color": colorDeclaration()
        case "colorbox", "fcolorbox": colorBox(framed: name == "fcolorbox")
        case "newline", "linebreak":
            _ = optional()
            appendHTML("<br>")
        case "newpage", "clearpage", "cleardoublepage", "pagebreak":
            _ = optional()
            appendBlock("<div class=\"latex-pagebreak\"></div>\n")
        case "noindent":
            if paragraph.isEmpty { noParagraphIndent = true }
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
        case "graphicspath": document.graphicsPaths = graphicsPaths(argument() ?? "")
        case "appendix":
            document.isAppendix = true
            document.counters[document.hasChapters ? "chapter" : "section"] = 0

        case "DeclareMathOperator": declareOperator()
        case "definecolor": defineColor()
        case "parbox": layoutBox(from: self, environment: false)
        case "hfill":
            if boxes.isEmpty { appendText(" ") } else { pendingFill = true }
        case "subcaption": caption(sub: true)
        case "subfloat", "subfigure", "subcaptionbox": subfigureCommand(name)
        case "tcbox": inlineColorBox()
        case "makecell":
            _ = optional()
            appendHTML(inline(argument() ?? ""))
        case "includegraphics": appendHTML(image())
        case "caption": caption()
        case "c", "k", "d", "b", "r", "t", "u", "v", "H":
            if let mark = LaTeXSymbols.accents[Character(name)] { accent(mark) }
        default: generic(name)
        }
    }

    private func generic(_ name: String) {
        if handleLayoutSetting(name) { return }
        if let wrapper = LaTeXSymbols.wrappers[name] {
            if let count = wrapper.setup {
                _ = star()
                while optional() != nil {}
                for _ in 0..<count { _ = argument() }
                while optional() != nil {}
            }
            appendHTML(wrapper.open + styledInline(argument() ?? "") + wrapper.close)
        } else if let declaration = LaTeXSymbols.declarations[name] {
            if !declaration.open.isEmpty {
                appendHTML(declaration.open, last: lastCharacter)
                openDeclarations.append(declaration.close)
            }
        } else if let size = LaTeXSymbols.sizes[name] {
            appendHTML("<span style=\"font-size: \(String(format: "%g", size))em\">", last: lastCharacter)
            openDeclarations.append("</span>")
        } else if let logo = LaTeXSymbols.logoHTML(name) {
            appendHTML(logo, last: LaTeXSymbols.text[name]?.last)
        } else if let text = LaTeXSymbols.text[name] {
            if !text.isEmpty { appendText(text) }
        } else if let count = LaTeXSymbols.ignored[name] {
            _ = star()
            dropArguments(count)
        } else {
            // Report any other command by name. Drop its options and keep mandatory groups for the prose they may hold.
            document.recordUnknown("\\" + name)
            readUnknownArguments()
        }
    }

    // MARK: - Definitions

    func readPreamble(stoppingAfterClass: Bool = false) {
        let previous = inPreamble
        inPreamble = true
        defer { inPreamble = previous }
        while !document.startedDocument, let character = peek() {
            retireFileFrames()
            if let end = LaTeXLexer.opaqueEnd(characters, at: index) {
                index = end
                continue
            }
            if character == "{" {
                index += 1
                _ = balanced()
                continue
            }
            guard character == "\\" else {
                index += 1
                continue
            }
            retireMacroFrames()
            index += 1
            let name = String(controlTokenName())
            skipSpacesAfterControlWord()
            if handleMacro(name) || handleFileCommand(name) { continue }
            if handleControl(name) || handleCounter(name) || handleReference(name)
                || name == "sethlcolor" && handleText(name)
            {
                continue
            }
            switch name {
            case "begin":
                if argument() == "document" {
                    document.startedDocument = true
                    flush()
                    output = ""
                }
            case "documentclass":
                readDocumentClass()
                if stoppingAfterClass { return }
            case "title": document.title = argument()
            case "author": document.authors = argument()
            case "date": document.date = argument() ?? ""
            case "DeclareMathOperator": declareOperator()
            case "definecolor": defineColor()
            case "lstset", "lstdefinestyle": configureListings(name)
            case "graphicspath": document.graphicsPaths = graphicsPaths(argument() ?? "")
            case "usepackage", "RequirePackage": readPackage()
            case "addbibresource", "bibliographystyle", "setcitestyle", "nocite": externalBibliography(name)
            default: generic(name)
            }
        }
    }

    private func readDocumentClass() {
        let options = optional()
        let name = argument()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "article"
        document.classInfo = LaTeXDocumentClassInfo(name: name, options: options)
        if document.classInfo.hasChapters { document.hasChapters = true }
    }

    private func controlTokenName() -> Substring {
        let start = index
        while let character = peek(), character.isASCII, character.isLetter { index += 1 }
        if index == start, peek() != nil { index += 1 }
        return Substring(String(characters[start..<index]))
    }

    private func declareOperator() {
        let limits = star()
        guard let name = argument()?.trimmingCharacters(in: .whitespaces), name.hasPrefix("\\") else { return }
        let text = argument() ?? ""
        addMathDefinition("\\def\(name){\\operatorname\(limits ? "*" : ""){\(text)}}")
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
        // A chapter in skipped code cannot change the numbering of an article.
        if name == "chapter" { document.hasChapters = true }
        let starred = star()
        _ = optional()
        let source = argument() ?? ""
        if name == "part" {
            let numeral = starred ? "" : stepCounter("part")
            let label = document.isJapanese ? "第\(numeral)部" : "Part \(numeral)"
            let id = document.counters.anchor("part", suffix: starred ? "u" : String(document.counters["part"]))
            document.labelTarget = (numeral, id)
            let title = inline(source)
            document.describeTarget(id, kind: "part", title: title)
            appendBlock(
                "<h2 class=\"latex-part\" id=\"\(id)\">\(starred ? "" : "<span class=\"secnum\">\(HTML.escape(label))</span>")\(title)</h2>\n"
            )
            return
        }
        let level = LaTeXCounters.levels.firstIndex(of: name) ?? 1
        let first = document.hasChapters ? 0 : 1
        let deepestNumbered = document.hasChapters ? 2 : 3
        var number: String?
        var display: String?
        if !starred, level <= deepestNumbered, level >= first {
            number = stepCounter(name)
            if level == 0, let chapter = number {
                display =
                    document.isAppendix
                    ? (document.isJapanese ? "付録\(chapter)" : "Appendix \(chapter)")
                    : (document.isJapanese ? "第\(chapter)章" : "Chapter \(chapter)")
            } else {
                display = number
            }
        }
        let suffix = number?.replacingOccurrences(of: ".", with: "-") ?? "u\(document.headings.count + 1)"
        let id = document.counters.anchor("sec", suffix: suffix)
        let tag = min(level - first + 2, 6)
        document.labelTarget = (number ?? "", id)
        let title = inline(source)
        document.describeTarget(id, kind: document.isAppendix && level == first ? "appendix" : name, title: title)
        document.headings.append(.init(level: level, number: number, id: id, title: title))
        let numberHTML = display.map { "<span class=\"secnum\">\(HTML.escape($0))</span>" } ?? ""
        let runIn = name == "paragraph" || name == "subparagraph"
        let kind = runIn ? " class=\"latex-runin-\(name)\"" : ""
        // An HTML newline becomes an extra word space when the theme puts the heading and paragraph on one line.
        appendBlock("<h\(tag)\(kind) id=\"\(id)\">\(numberHTML)\(title)</h\(tag)>" + (runIn ? "" : "\n"))
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

    func unsupported(_ message: String) -> String {
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

    func color() -> String? {
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

    func delimitedCode() -> String {
        guard let delimiter = peek() else { return "" }
        index += 1
        let start = index
        while let character = peek(), character != delimiter, character != "\n" { index += 1 }
        let text = String(characters[start..<index])
        if peek() == delimiter { index += 1 }
        return text
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

    /// A key's value in a `key=value` list such as listings' and graphicx's options.
    func option(_ key: String, in options: String?) -> String? {
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
        // Package key lists apply assignments in order; a local option can override a box style's default.
        for part in parts.reversed() {
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

    func formula(_ latex: String, display: Bool, source: String, expanded: Bool = false, numbers: [String?] = [])
        -> String
    {
        // amsthm's `\qedhere` only moves the end-of-proof box, which SwaTex does not know.
        let (clean, labels) = Self.removingLabels(expanded ? latex : expandMathCommands(latex))
        let anchor = mathAnchor(labels, tag: Self.explicitTag(clean))
        let units = LaTeXUnits.expandingInMath(clean.replacingOccurrences(of: "\\qedhere", with: ""))
        guard let math = mathWithLoopVariables(units) else { return anchor }
        if math.contains("\\ref") || math.contains("\\eqref") {
            document.deferredMath.append(
                .init(
                    latex: math, display: display, fallback: source, macros: document.mathDefinitions, numbers: numbers)
            )
            return anchor + document.placeholder("M", document.deferredMath.count - 1)
        }
        return anchor
            + document.mathHTML(
                math, display: display, macros: document.mathDefinitions, source: source, numbers: numbers)
    }

    private func inlineMath(closing: String) {
        let opening = closing == "$" ? "$" : "\\("
        let latex = mathSource(closing: closing)
        appendInlineFormula(latex, source: opening + latex + closing)
    }

    func appendInlineFormula(_ latex: String, source: String) {
        let html = formula(latex, display: false, source: source)
        // WebKit can break between an inline SVG and a closing mark. Keep only adjacent punctuation
        // in the same line box; a space written by the author remains a possible line break.
        let start = index
        while let mark = peek(), ".,;:)".contains(mark) { index += 1 }
        guard start != index else {
            appendHTML(html)
            return
        }
        let marks = String(characters[start..<index])
        appendHTML("<span class=\"latex-nowrap\">\(html)\(marks)</span>", last: marks.last)
    }

    private func displayMath(closing: String) {
        let opening = closing == "$$" ? "$$" : "\\["
        let latex = mathSource(closing: closing)
        appendBlock(
            "<div class=\"math-block\">\(formula(latex, display: true, source: opening + latex + closing))</div>\n",
            continuesParagraph: true)
    }

    static let mathEnvironments: [String: (String, String)?] = [
        "equation": nil, "displaymath": nil, "multline": ("\\begin{gathered}", "\\end{gathered}"),
        "align": ("\\begin{aligned}", "\\end{aligned}"), "flalign": ("\\begin{aligned}", "\\end{aligned}"),
        "alignat": ("\\begin{aligned}", "\\end{aligned}"), "gather": ("\\begin{gathered}", "\\end{gathered}"),
        "eqnarray": ("\\begin{aligned}", "\\end{aligned}"),
    ]

    /// Environments whose every row is numbered, as amsmath numbers align and gather.
    static let numberedRows: Set<String> = ["align", "flalign", "alignat", "gather", "eqnarray"]

    private static let labelPattern = try? NSRegularExpression(pattern: #"\\label\s*\{([^}]*)\}"#)
    /// Removing a row tag moves the whole text-mode argument to the paper's edge. A brace in a
    /// nested command or an escaped brace cannot terminate that argument.
    private struct EquationTag {
        let value: String
        let starred: Bool
        let range: Range<String.Index>
    }

    private static func equationTag(in latex: String) -> EquationTag? {
        guard latex.contains("\\tag"),
            let opening = latex.range(of: #"\\tag\s*\*?\s*\{"#, options: .regularExpression)
        else { return nil }
        var depth = 1
        var cursor = opening.upperBound
        while cursor < latex.endIndex {
            let start = cursor
            let c = latex[cursor]
            latex.formIndex(after: &cursor)
            if c == "\\" {
                if cursor < latex.endIndex { latex.formIndex(after: &cursor) }
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    return EquationTag(
                        value: String(latex[opening.upperBound..<start]), starred: latex[opening].contains("*"),
                        range: opening.lowerBound..<cursor)
                }
            }
        }
        return nil
    }

    static func explicitTag(_ latex: String) -> String? {
        equationTag(in: latex)?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Most tags are a few letters. For styled tags, let the same math engine read their text-mode
    /// argument and draw its original glyphs, now in the margin instead of inside the centered grid.
    private func numberHTML(_ tag: EquationTag) -> String {
        let value = tag.value
        if value.contains(where: { "\\{}$".contains($0) }) {
            let source = "\\tag" + (tag.starred ? "*" : "") + "{" + value + "}"
            return document.mathHTML(
                source, display: false, macros: document.mathDefinitions, source: source, numbers: [])
        }
        return HTML.escape(tag.starred ? value : "(" + value + ")")
    }

    /// An anchor for a formula with its own tag, and its labels pointing at the tag.
    func registerTag(_ tag: String, labels: [String]) -> String {
        // References print the tag; a long one is cut here once rather than at each reference.
        let tag = tag.utf8.count > 300 ? String(tag.prefix(100)) + "…" : tag
        document.taggedCount += 1
        let id = document.counters.anchor("eq", suffix: "t\(document.taggedCount)")
        document.describeTarget(id, kind: "equation", title: "")
        for key in labels where !key.isEmpty { document.labels[key] = (tag, id) }
        document.labelTarget = (tag, id)
        return id
    }

    /// A display environment of amsmath. An unstarred equation or multline gets the next equation number at the
    /// right; an unstarred align or gather keeps its numbers outside the centered math grid, skipping rows with
    /// `\notag` and keeping a row's own `\tag`. A `\label` names the number of its row.
    private func mathEnvironment(_ name: String, body: String) {
        let starred = name.hasSuffix("*")
        let base = starred ? String(name.dropLast()) : name
        // Resolve macro arguments before collecting labels or splitting rows. Their counters still belong
        // to the row that will receive a number below.
        var latex = expandMathCommands(Self.withoutComments(body), includingCounters: false)
        // alignat's column count is not part of the formula.
        if base == "alignat", latex.drop(while: \.isWhitespace).first == "{", let close = latex.firstIndex(of: "}") {
            latex = String(latex[latex.index(after: close)...])
        }
        let wrapper = Self.mathEnvironments[base] ?? nil
        let source = "\\begin{\(name)}\(body)\\end{\(name)}"
        func render(_ formula: String, expanded: Bool = false, numbers: [String?] = []) -> String {
            self.formula(
                wrapper.map { $0.0 + formula + $0.1 } ?? formula, display: true, source: source, expanded: expanded,
                numbers: numbers)
        }
        if Self.numberedRows.contains(base) {
            var anchors = ""
            var rows = Self.rows(of: latex)
            var numbers = [String?](repeating: nil, count: rows.count)
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
                if let tag = Self.equationTag(in: row) {
                    anchors += "<span id=\"\(registerTag(tag.value, labels: labels))\"></span>"
                    numbers[position] = numberHTML(tag)
                    row.removeSubrange(tag.range)
                } else if !starred, !skipped, !isEmpty {
                    let number = stepCounter("equation")
                    let id = document.counters.anchor("eq", suffix: number)
                    document.describeTarget(id, kind: "equation", title: "")
                    numbers[position] = "(" + HTML.escape(number) + ")"
                    anchors += "<span id=\"\(id)\"></span>"
                    for key in labels where !key.isEmpty { document.labels[key] = (number, id) }
                    document.labelTarget = (number, id)
                } else {
                    anchors += mathAnchor(labels, tag: nil)
                }
                // Freeze the row here: the next row advances the same equation counter before SwaTex draws either.
                let (frozen, generatedLabels) = Self.removingLabels(expandMathCommands(row))
                if !generatedLabels.isEmpty {
                    anchors += mathAnchor(generatedLabels, tag: Self.explicitTag(frozen))
                }
                rows[position] = frozen
            }
            appendBlock(
                "<div class=\"math-block\">\(anchors)\(render(rows.joined(separator: "\\\\"), expanded: true, numbers: numbers.contains(where: { $0 != nil }) ? numbers : []))</div>\n"
            )
            return
        }
        let (formula, labels) = Self.removingLabels(
            latex.replacingOccurrences(of: "\\nonumber", with: "").replacingOccurrences(of: "\\notag", with: ""))
        let id: String
        let printed: String
        var clean = formula
        if let tag = Self.equationTag(in: formula) {
            id = registerTag(tag.value, labels: labels)
            printed = numberHTML(tag)
            clean.removeSubrange(tag.range)
        } else if !starred && base != "displaymath" && !latex.contains("\\notag") && !latex.contains("\\nonumber") {
            let number = stepCounter("equation")
            id = document.counters.anchor("eq", suffix: number)
            document.describeTarget(id, kind: "equation", title: "")
            for key in labels where !key.isEmpty { document.labels[key] = (number, id) }
            document.labelTarget = (number, id)
            printed = "(" + HTML.escape(number) + ")"
        } else {
            appendBlock("<div class=\"math-block\">\(mathAnchor(labels, tag: nil))\(render(formula))</div>\n")
            return
        }
        let content: String
        if base == "multline" {
            // amsmath puts this one number on the final line, even if earlier lines are taller.
            let rows = Self.rows(of: clean)
            var numbers = [String?](repeating: nil, count: rows.count)
            if let last = rows.lastIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                numbers[last] = printed
            }
            content = render(clean, numbers: numbers)
        } else {
            content = render(clean) + "<span class=\"eqno\">\(printed)</span>"
        }
        appendBlock("<div class=\"math-block latex-equation\" id=\"\(id)\">\(content)</div>\n")
    }

    /// Each line without its comment; an escaped percent sign stays.
    static func withoutComments(_ latex: String) -> String {
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

    static func removingLabels(_ latex: String) -> (String, [String]) {
        guard let labelPattern else { return (latex, []) }
        let nsLatex = latex as NSString
        let range = NSRange(location: 0, length: nsLatex.length)
        let labels = labelPattern.matches(in: latex, range: range).map {
            nsLatex.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
        return (labelPattern.stringByReplacingMatches(in: latex, range: range, withTemplate: ""), labels)
    }

    /// The rows of an alignment, split at `\\\\` outside braces; a spacing such as `\\\\[2pt]` stays with its row.
    static func rows(of latex: String) -> [String] {
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
        if let environment = document.environments[name] {
            expandEnvironment(name, environment)
            return
        }
        // A block environment interrupts the HTML paragraph, even when the TeX paragraph continues.
        // Inline math, comments and empty environments have no printed block to continue after.
        let previousOutput = output.utf8.count
        defer {
            if isBlock && output.utf8.count > previousOutput && paragraph.isEmpty { noParagraphIndent = true }
        }
        switch name {
        case "document" where !document.inputChain.isEmpty && !document.startedDocument:
            // A thin main file may input the entire document, including the body boundary.
            document.startedDocument = true
        case "verbatim", "verbatim*", "Verbatim", "alltt":
            if name == "Verbatim" { _ = optionalOnLine() }
            appendListing(verbatimBody(name), settings: [:], environment: true, verbatim: true)
        case "lstlisting":
            let settings = listingSettings(optionalOnLine())
            appendListing(verbatimBody(name), settings: settings, environment: true)
        case "minted":
            var settings = listingSettings(optional(), minted: true)
            settings["language"] = argument()
            appendListing(verbatimBody(name), settings: settings, environment: true)
        case "comment":
            _ = verbatimBody(name)
        default:
            let body = environmentBody(name)
            environment(name, body: body)
        }
    }

    /// An optional argument only on the line that opens an environment, so a body starting with `[` stays text.
    func optionalOnLine() -> String? {
        var lookahead = index
        while lookahead < characters.count, characters[lookahead] == " " || characters[lookahead] == "\t" {
            lookahead += 1
        }
        guard lookahead < characters.count, characters[lookahead] == "[" else { return nil }
        index = lookahead
        return optional()
    }

    /// The source up to the `\end` that matches the environment just opened.
    func environmentBody(_ name: String) -> String {
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
                index = min(index + 2, characters.count)
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
            appendInlineFormula(body, source: "\\begin{math}\(body)\\end{math}")
        case "itemize", "enumerate", "description":
            let reader = LaTeXReader(body, document: document, isBlock: false)
            let options = reader.optionalOnLine()
            appendBlock(list(base, options: options, body: reader.rest))
        case "quote", "quotation":
            let attribute = base == "quotation" ? " class=\"latex-quotation\"" : ""
            appendBlock("<blockquote\(attribute)>\n\(blocks(body))</blockquote>\n")
        case "verse":
            appendBlock("<blockquote class=\"latex-verse\">\n\(blocks(body))</blockquote>\n")
        case "center", "flushleft", "flushright":
            appendBlock("<div class=\"latex-\(base)\">\n\(blocks(body))</div>\n")
        case "abstract":
            let heading = document.isJapanese ? "概要" : "Abstract"
            appendBlock(
                "<div class=\"abstract\">\n<p class=\"abstract-title\">\(heading)</p>\n\(blocks(body))</div>\n")
        case "figure", "table", "SCfigure":
            float(base == "table" ? "table" : "figure", body: body)
        case "listing": float("listing", body: body)
        case "wrapfigure", "wraptable":
            let reader = LaTeXReader(body, document: document, isBlock: false)
            _ = reader.optional()
            _ = reader.argument()
            _ = reader.optional()
            _ = reader.argument()
            float(base == "wraptable" ? "table" : "figure", body: reader.rest)
        case "tabular", "tabularx", "tabulary", "longtable", "supertabular", "xltabular", "tabu":
            appendBlock(tabular(name, body: body))
        case "minipage", "subfigure":
            let reader = LaTeXReader(body, document: document, isBlock: false)
            let previous = document.insideSubfigure
            document.insideSubfigure = base == "subfigure" || previous
            layoutBox(from: reader, environment: true)
            document.insideSubfigure = previous
        case "multicols":
            guard document.reserveExpansion(characters: body.count) else { return }
            let reader = LaTeXReader(body, document: document, isBlock: false)
            _ = reader.argument()
            let heading = reader.optional()
            _ = reader.optional()
            appendBlock((heading.map(blocks) ?? "") + blocks(reader.rest))
        case "tcolorbox", "mdframed", "framed", "shaded":
            let reader = LaTeXReader(body, document: document, isBlock: false)
            let options = reader.optional()
            appendBlock(callout(options: options, body: reader.rest))
        case "subequations": subequations(body)
        case "proof": proof(body)
        case "thebibliography": bibliography(body)
        default:
            if let theorem = document.theorems[name] ?? conventionalTheorem(name) {
                self.theorem(name, theorem, body: body)
            } else if Self.unsupportedEnvironments.contains(base) {
                appendBlock(externalPicture())
            } else {
                document.recordUnknown(name)
                let reader = LaTeXReader(body, document: document, isBlock: true)
                while reader.optional() != nil {}
                appendBlock(reader.read())
            }
        }
    }

    // MARK: - Lists

    private func list(_ kind: String, options: String?, body: String) -> String {
        var prefix = ""
        let items = Self.items(of: body) { prefix = $0 }
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
                // A term and its definition share the first line in class styles. Leave their gap to CSS.
                "<div><dt>\(inline(label ?? ""))</dt><dd>\(compact(blocks(content)))</dd></div>\n"
            }
            return "<dl class=\"latex-description\">\n\(html.joined())</dl>\n"
        default:
            document.enumerateDepth += 1
            defer { document.enumerateDepth -= 1 }
            let (template, style, start) = enumerateStyle(options)
            let counter = LaTeXCounters.listLevels[min(document.enumerateDepth - 1, 3)]
            document.counters[counter] = start - 1
            // Assignments between the opening environment and its first item affect that item.
            if !prefix.isEmpty { _ = inline(prefix) }
            let html = items.map { label, content -> String in
                document.counters.advance(counter)
                let number = LaTeXSymbols.format(document.counters[counter], as: style)
                document.itemCount += 1
                let id = "item-\(document.itemCount)"
                document.describeTarget(id, kind: "item", title: "")
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
                let match = letters.first(where: { $0.0 == options[position] }),
                options.indices.allSatisfy({
                    $0 == position || options[$0].isPunctuation || options[$0].isSymbol || options[$0].isWhitespace
                })
            {
                template = options.replacingCharacters(in: position...position, with: "\u{E000}")
                style = match.1
            }
        }
        return (template, style, start)
    }

    /// The items of a list body, split at each `\item` outside nested groups and environments, with the label
    /// written in brackets after it.
    private static func items(of body: String, command: String = "item", prefix: ((String) -> Void)? = nil)
        -> [(label: String?, content: String)]
    {
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
                } else if braces == 0, environments == 0, matches("\\" + command, at: index),
                    !(index + command.count + 1 < characters.count && characters[index + command.count + 1].isASCII
                        && characters[index + command.count + 1].isLetter)
                {
                    if let current {
                        items.append((nil, String(current)))
                    } else {
                        prefix?(String(characters[..<index]))
                    }
                    current = []
                    index += command.count + 1
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

    // MARK: - Theorems and the bibliography

    /// A theorem-like environment: its heading and number in front of the first paragraph. amsthm's plain style
    /// sets the body in italics; a Japanese document keeps it upright, as its fonts have no italics.
    private func theorem(_ name: String, _ theorem: LaTeXDocument.Theorem, body: String) {
        let reader = LaTeXReader(body, document: document, isBlock: false)
        var anchor = ""
        var numberHTML = ""
        var targetID: String?
        if let counter = theorem.counter {
            let number = stepCounter(counter)
            document.theoremCount += 1
            let id = "thm-\(document.theoremCount)"
            targetID = id
            document.labelTarget = (number, id)
            numberHTML = " " + HTML.escape(number)
            anchor = " id=\"\(id)\""
        }
        let note = reader.optionalOnLine().map { inline($0) }
        var head: String
        if let cached = document.theoremHeadings[name] {
            head = cached
        } else {
            let excerpt = HTML.escape(theorem.title.count > 1_000 ? theorem.title.prefix(1_000) + "…" : theorem.title)
            // Reserved first: inside its own heading the environment prints its source instead of reading it again.
            document.theoremHeadings[name] = excerpt
            head = inline(theorem.title)
            // A heading that opens other theorems could double at each step; a long one shows its source instead.
            if head.utf8.count > 20_000 { head = excerpt }
            document.theoremHeadings[name] = head
        }
        // Every heading printed draws on one budget, so printing a long heading many times cannot multiply it; past
        // the budget a heading is the environment's name, which its source already holds.
        if head.utf8.count <= document.headingBudget {
            document.headingBudget -= head.utf8.count
        } else {
            head = HTML.escape(name)
        }
        if let targetID { document.describeTarget(targetID, kind: name, title: note ?? head) }
        head += numberHTML
        let noteHTML = note.map { document.isJapanese ? "（\($0)）" : " (\($0))" } ?? ""
        head =
            document.usesAMSTheorem
            ? head + (noteHTML.isEmpty ? "" : "<span class=\"theorem-note\">\(noteHTML)</span>") + "."
            : head + noteHTML
        let style = theorem.style == "plain" && document.isJapanese ? "definition" : theorem.style
        let content = blocks(reader.rest)
        appendBlock(
            "<div class=\"latex-theorem latex-theorem-\(style)\"\(anchor)>\n"
                + leading("<span class=\"theorem-head\">\(head)</span> ", content) + "</div>\n")
    }

    /// amsthm's proof: its heading in italics and the end-of-proof box at the right of the last line.
    private func proof(_ body: String) {
        let reader = LaTeXReader(body, document: document, isBlock: false)
        // A redefined `\proofname` is read as a macro, within the limits on expansion.
        let title =
            reader.optionalOnLine().map { inline($0) }
            ?? (document.macros["proofname"] != nil ? inline("\\proofname") : (document.isJapanese ? "証明" : "Proof"))
        var content = blocks(reader.rest).trimmingCharacters(in: .whitespacesAndNewlines)
        let box = "<span class=\"qed\">□</span>"
        if content.hasSuffix("</p>") {
            content = content.dropLast(4) + box + "</p>"
        } else {
            content += "\n<p class=\"qed-line\">\(box)</p>"
        }
        appendBlock(
            "<div class=\"latex-proof\">\n" + leading("<span class=\"proof-head\">\(title).</span> ", content)
                + "\n</div>\n")
    }

    /// Markup in front of the first paragraph, or in a paragraph of its own when the body starts with something else.
    private func leading(_ head: String, _ content: String) -> String {
        content.hasPrefix("<p>") ? "<p>" + head + content.dropFirst(3) : "<p>\(head)</p>\n" + content
    }

    /// `thebibliography`: a heading and the entries, numbered in order or labeled by `\bibitem[label]`. `\cite`
    /// finds them by key when the document is read to the end.
    private func bibliography(_ body: String) {
        let reader = LaTeXReader(body, document: document, isBlock: false)
        // The widest label; without it the first `\bibitem` would be taken for it.
        if reader.rest.drop(while: \.isWhitespace).first == "{" { _ = reader.argument() }
        let nameMacro = document.hasChapters ? "bibname" : "refname"
        let heading =
            document.macros[nameMacro] != nil
            ? inline("\\" + nameMacro)
            : (document.isJapanese ? "参考文献" : document.hasChapters ? "Bibliography" : "References")
        document.bibliographyCount += 1
        let headingID = "bibliography-\(document.bibliographyCount)"
        document.headings.append(.init(level: document.hasChapters ? 0 : 1, number: nil, id: headingID, title: heading))
        var entries = ""
        var number = 0
        for (position, item) in Self.items(of: reader.rest, command: "bibitem").enumerated() {
            let itemReader = LaTeXReader(item.content, document: document, isBlock: false)
            let key = itemReader.argument()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // As in LaTeX, an entry with its own label does not advance the numbers.
            let label: String
            if let own = item.label {
                label = inline(own)
            } else {
                number += 1
                label = String(number)
            }
            let id = "bib-\(document.bibliographyCount)-\(position + 1)"
            if !key.isEmpty { document.bibliography[key] = (label, id) }
            let text = compact(blocks(itemReader.rest))
            let marker = "<span class=\"bib-label\">[\(label)]</span>"
            entries +=
                "<li id=\"\(id)\">\(text.hasPrefix("<p>") ? "<p>" + marker + text.dropFirst(3) : marker + text)</li>\n"
        }
        appendBlock(
            "<h2 class=\"latex-bibliography-heading\" id=\"\(headingID)\">\(heading)</h2>\n"
                + "<ol class=\"latex-bibliography\">\n\(entries)</ol>\n")
    }

    /// `\cite[after]{keys}` and natbib's `\citep[before][after]{keys}`. The numbers are filled in at the end, as
    /// the bibliography usually comes last.
    private func cite(_ command: String) {
        _ = star()
        let first = optional()
        let second = optional()
        let keys = (argument() ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let (before, after) = second == nil ? (nil, first) : (first, second)
        appendHTML(
            document.citation(
                .init(command: command, keys: keys, before: before.map { inline($0) }, after: after.map { inline($0) }))
        )
    }

    // MARK: - Floats, images and tables

    private func float(_ kind: String, body: String) {
        let reader = LaTeXReader(body, document: document, isBlock: true)
        _ = reader.optionalOnLine()
        reader.floatKind = kind
        let previous = document.figureCaptions
        if kind == "figure" { document.figureCaptions = LaTeXFigureCaptions() }
        defer { document.figureCaptions = previous }
        let inside = reader.read()
        appendBlock("<figure class=\"latex-\(kind)\">\n\(inside)</figure>\n")
    }

    private func caption(sub: Bool = false) {
        let unnumbered = star()
        _ = optional()
        let source = argument() ?? ""
        if unnumbered {
            appendBlock("<figcaption>\(inline(source))</figcaption>\n")
            return
        }
        if sub || document.insideSubfigure {
            let target = subfigureTarget()
            appendBlock(subcaptionHTML(source, target: target))
            return
        }
        let kind = floatKind ?? "figure"
        let number: String
        if kind == "figure", let figure = document.figureCaptions {
            number = figure.mainCaptionPrinted ? stepCounter(kind) : figure.number ?? stepCounter(kind)
            if figure.mainCaptionPrinted { figure.children = 0 }
            figure.number = number
            figure.mainCaptionPrinted = true
        } else {
            number = stepCounter(kind)
        }
        let prefix: String
        let name: String
        switch kind {
        case "table": (prefix, name) = ("tab", document.isJapanese ? "表" : "Table")
        case "listing": (prefix, name) = ("listing", document.isJapanese ? "リスト" : "Listing")
        default: (prefix, name) = ("fig", document.isJapanese ? "図" : "Figure")
        }
        let id = document.counters.anchor(prefix, suffix: number)
        document.labelTarget = (number, id)
        let text = inline(source)
        document.describeTarget(id, kind: kind, title: text)
        let separator = document.isJapanese ? "　" : ": "
        appendBlock(
            "<figcaption id=\"\(id)\"><span class=\"latex-caption-label\">\(name) \(HTML.escape(number))</span>\(separator)\(text)</figcaption>\n"
        )
    }

    private func image() -> String {
        _ = star()
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
        if let angle = option("angle", in: options).flatMap(Double.init), angle.isFinite {
            // graphicx uses positive counterclockwise angles; CSS rotates clockwise.
            style.append("transform: rotate(\(String(format: "%g", -angle))deg)")
        }
        let preserveAspectRatio =
            option("keepaspectratio", in: options).map { $0 == "true" }
            ?? (options?.split(separator: ",").contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == "keepaspectratio"
            } == true)
        if preserveAspectRatio {
            style.append("object-fit: contain")
        }
        let source = document.imageSource(file)
        let attributes = style.isEmpty ? "" : " style=\"\(style.joined(separator: "; "))\""
        return "<img class=\"latex-graphic\" src=\"\(HTML.escape(source))\" alt=\"\"\(attributes)>"
    }

    private func tabular(_ name: String, body: String) -> String {
        let reader = LaTeXReader(body, document: document, isBlock: false)
        if name == "xltabular" { _ = reader.optional() }
        if ["tabular*", "tabularx", "tabulary", "xltabular", "supertabular*", "tabu"].contains(name) {
            _ = reader.argument()
        }
        _ = reader.optional()
        let spec = reader.argument() ?? ""
        let rest = reader.rest
        let isLong = ["longtable", "xltabular", "supertabular", "supertabular*"].contains(name)
        guard document.reserveExpansion(characters: rest.count) else { return "" }
        reader.floatKind = isLong ? "table" : floatKind
        return LaTeXTable(spec: spec, body: rest, isLongtable: isLong).html(
            color: { LaTeXSymbols.cssColor($0, model: $1, defined: document.colors) },
            inline: reader.inline)
    }
}

import Foundation

/// Reads LaTeX source into HTML. A block reader makes paragraphs and blocks; an inline reader makes
/// the text of an argument. Argument and environment readers share the document's state.
final class LaTeXReader {
    // A thin kern at the edge of a font argument still separates it from the following unit.
    private static let paragraphWhitespace = CharacterSet.whitespacesAndNewlines.subtracting(
        CharacterSet(charactersIn: "\u{2009}\u{202F}"))

    private enum Space {
        case space
        case newline
    }

    let document: LaTeXDocument
    private var buffer: [Character]
    private var unreadSource: Substring?

    // Index-based scans and splices need the real tail (including its length for expansion budgets).
    // Sequential class inspection usually reaches the body using only the first buffer.
    var characters: [Character] {
        _read {
            completeBuffer()
            yield buffer
        }
        _modify {
            completeBuffer()
            yield &buffer
        }
    }
    var index = 0
    // Distances from the end remain valid when a replacement is inserted before its caller returns.
    var macroFrameEnds: [Int] = []
    var mathBudget: ReaderMathBudget?
    // Like macro frames, input boundaries follow the unchanged tail when more tokens are inserted.
    var fileFrames: [(tail: Int, chainDepth: Int)] = []
    let isBlock: Bool
    private var output = ""
    private var boxes = ""
    private var boxFill = false
    private var pendingFill = false
    private var paragraph = ""
    private var pendingDestinations = ""
    private var closesRunInParagraph = false
    private var newlines = 0
    private var pendingSpace: Space?
    /// Block HTML can interrupt a TeX paragraph without ending it. A blank line or explicit paragraph
    /// break cancels the continuation; otherwise the next HTML paragraph starts flush with the text.
    private var noParagraphIndent = false
    private var lastCharacter: Character?
    /// Markup for declarations such as `\bfseries`, which last to the end of their group.
    private var declarations: [(open: String, close: String, size: String?)] = []
    private var opened = 0
    private var typewriter = false
    private var centered = false
    private var groups: [(LaTeXReader) -> Void] = []
    // Alternate heads can contain another caption for the same alignment and counter.
    private final class LongtableCaption {
        var number: String?
    }
    private var longtableCaption: LongtableCaption?
    private var floatKind: String?

    init(_ text: String, document: LaTeXDocument, isBlock: Bool) {
        self.document = document
        buffer = Array(text)
        self.isBlock = isBlock
    }

    init(classifying text: String, document: LaTeXDocument) {
        self.document = document
        isBlock = false
        buffer = []
        unreadSource = text[...]
    }

    private func completeBuffer() {
        if let unreadSource {
            buffer.append(contentsOf: TextDecoding.normalizeNewlines(String(unreadSource)))
            self.unreadSource = nil
        }
    }

    private func fillBuffer(through position: Int) {
        while position >= buffer.count, let unreadSource {
            // Split on Character boundaries: in particular, CRLF stays together when normalized.
            let chunk = unreadSource.prefix(1024)
            buffer.append(contentsOf: TextDecoding.normalizeNewlines(String(chunk)))
            self.unreadSource = chunk.endIndex == unreadSource.endIndex ? nil : unreadSource[chunk.endIndex...]
        }
    }

    private func opaqueEnd() -> Int? {
        while true {
            var needsMore = false
            let end = LaTeXLexer.opaqueEnd(buffer, at: index) { needsMore = true }
            guard unreadSource != nil, needsMore || end == buffer.count else { return end }
            // Double the span of an unfinished token so even a long comment costs linear work.
            fillBuffer(through: buffer.count + (buffer.count - index))
        }
    }

    private var precedingUnnumberedHeading: String?
    private var hasLanguageWrapper = false
    private var scopedLanguage = false
    private var inlineLanguage: String?
    var pictureExpansion: PictureExpansion?
    var examList: LaTeXExam.List?
    var examItemIndex = 0
    var inPreamble = false

    func switchTextLanguage(_ tag: String) {
        if !isBlock || scopedLanguage {
            openDeclaration("<span \(LaTeXLanguage.attributes(tag))>", "</span>")
        } else if paragraph.isEmpty {
            openLanguageSection(tag)
        } else {
            // A language change within a sentence must not create a paragraph break.
            closeDeclarations()
            if inlineLanguage != nil { paragraph += "</span>" }
            paragraph += pendingSeparator(before: nil) + "<span \(LaTeXLanguage.attributes(tag))>"
            inlineLanguage = tag
        }
        document.language = tag
    }

    private func openLanguageSection(_ tag: String) {
        if hasLanguageWrapper { output += "</div>\n" }
        output += "<div \(LaTeXLanguage.attributes(tag))>\n"
        hasLanguageWrapper = true
    }

    func closeFrenchQuote() {
        pendingSpace = nil
        appendText("\u{00A0}»")
    }

    func read() -> String {
        document.depth += 1
        defer { document.depth -= 1 }
        // Nested environments and arguments create readers. Beyond the shared nesting
        // limit, or when the thread's stack runs short first, their text still prints, including the unexpanded braces.
        guard document.depth <= LaTeXDocument.maximumDepth, StackSpace.hasRoom else {
            document.stopsExpanding = true
            let text = HTML.escape(String(characters))
            return isBlock ? "<p>\(text)</p>\n" : text
        }
        let startingChain = document.inputChain
        defer { document.inputChain = startingChain }
        let language = document.language
        let initialLinkColors = document.hyperref
        defer { if document.depth > 1 { document.hyperref = initialLinkColors } }
        defer { if document.depth > 1 || hasLanguageWrapper { document.language = language } }
        readSteps()
        if isBlock {
            flush()
            output += takeDestinations()
            return hasLanguageWrapper ? output + "</div>\n" : output
        }
        finishBoxes()
        closeDeclarations()
        return paragraph.trimmingCharacters(in: Self.paragraphWhitespace)
    }

    // MARK: - Characters

    func readSteps() {
        // An unterminated group in an expansion cannot consume a brace from its caller.
        if let pictureExpansion {
            expandPictureTokens(into: pictureExpansion)
            return
        }
        let outer = groups
        groups = []
        let preview = PreviewConversion.isActive
        while !document.endedDocument, let character = peek() {
            if preview, PreviewConversion.expired { break }
            step(character)
        }
        while !groups.isEmpty { endGroup() }
        groups = outer
    }

    private func endGroup() {
        if let restore = groups.popLast() {
            restore(self)
            document.depth -= 1
        }
    }

    func peek(_ offset: Int = 0) -> Character? {
        let position = index + offset
        if position >= buffer.count, unreadSource != nil { fillBuffer(through: position) }
        return position < buffer.count ? buffer[position] : nil
    }

    func step(_ character: Character) {
        retireFileFrames()
        switch character {
        case "\\": command()
        case "%":
            skipComment()
            // The comment consumed its own endline. An empty following source line
            // still starts TeX in new-line state and emits a paragraph token.
            if peek() == "\n" { paragraphBreak() }
        case "{":
            index += 1
            if document.depth < LaTeXDocument.maximumDepth {
                groups.append(groupRestorer())
                document.depth += 1
            } else {
                document.stopsExpanding = true
                appendHTML(HTML.escape(balanced()), last: lastCharacter)
            }
        case "}":
            index += 1
            endGroup()
        case "$": dollarMath()
        case "\n": newline()
        case " ", "\t":
            index += 1
            if pendingSpace == nil { pendingSpace = .space }
        case "~":
            index += 1
            appendHTML("&nbsp;")
        case "\"" where !typewriter && document.language == "de":
            index += 1
            let marks: [Character: String] = [
                "a": "ä", "o": "ö", "u": "ü", "s": "ß", "A": "Ä", "O": "Ö", "U": "Ü", "`": "„", "'": "“",
            ]
            if let next = peek(), let mark = marks[next] {
                index += 1
                appendText(mark)
            } else {
                appendText("\"")
            }
        case ";", ":", "!", "?":
            index += 1
            if !typewriter, document.language == "fr", lastCharacter != nil, lastCharacter?.isWhitespace != true {
                pendingSpace = nil
                appendText("\u{202F}")
            }
            appendText(String(character))
        case "-":
            if typewriter {
                index += 1
                appendText("-")
                return
            }
            var count = 0
            while peek() == "-" && count < 3 {
                index += 1
                count += 1
            }
            appendText(count == 3 ? "—" : count == 2 ? "–" : "-")
        case "`", "'":
            index += 1
            if typewriter {
                appendText(String(character))
                return
            }
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
        precedingUnnumberedHeading = nil
        if boxes.isEmpty && isBlock { flush() }
        if pendingFill && !boxes.isEmpty {
            boxes += " "
            boxFill = true
        }
        boxes += takeDestinations() + html
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
        precedingUnnumberedHeading = nil
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
        paragraph += pendingSeparator(before: first)
        reopenDeclarations()
        paragraph += HTML.escape(text)
        lastCharacter = text.last
    }

    func trimPunctuationBeforeNote() {
        guard pendingSpace == nil, let last = paragraph.last, "。、）」』".contains(last) else { return }
        paragraph.removeLast()
        paragraph += "<span class=\"latex-jfm-close\">\(last)</span>"
    }

    func appendHTML(_ html: String, last: Character? = "x") {
        guard !html.isEmpty else { return }
        startContent()
        paragraph += pendingSeparator(before: html.first)
        reopenDeclarations()
        paragraph += html
        lastCharacter = last
    }

    func appendBlock(_ html: String, continuesParagraph: Bool = false) {
        startContent()
        if isBlock {
            flush()
            output += takeDestinations() + html
            noParagraphIndent = continuesParagraph
        } else {
            paragraph += html
        }
        pendingSpace = nil
    }

    /// A counter destination in vertical mode must not start an empty paragraph or consume the
    /// first flush-left line after a heading. Keep it with the next piece of printable content.
    func appendDestination(_ html: String) {
        if isBlock && paragraph.isEmpty && boxes.isEmpty {
            pendingDestinations += html
        } else {
            appendHTML(html)
        }
    }

    private func takeDestinations() -> String {
        defer { pendingDestinations = "" }
        return pendingDestinations
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
        let restore = groupRestorer()
        readExpansionBody(source)
        restore(self)
    }

    private func groupRestorer() -> (LaTeXReader) -> Void {
        let previous = (
            document.macros, document.environments, document.mathDefinitions, document.highlightColor,
            document.referenceNames
        )
        document.mathDefinitions.preview?.insideGroup = true
        document.mathDefinitions.app.insideGroup = true
        let outer = declarations.count
        let previousRowHeight = document.pageSettings.extraRowHeight
        let tableRegisters = document.pageSettings.tableSpacing
        let previousSkin = document.pageSettings.boxDefaults
        let previousLinkColors = document.hyperref
        let previousFace = typewriter
        let previousCentered = centered
        let previousLanguage = document.language
        let pictureSettings = (document.pictureStyles, document.plotDefaults, document.colors)
        let previousCounts = document.countRegisters
        let previousCaptions = document.localizedCaptions
        let numberedBeamerCaptions = document.numberedBeamerCaptions
        let previousScope = scopedLanguage
        scopedLanguage = true
        return { reader in
            (
                reader.document.macros, reader.document.environments, reader.document.mathDefinitions,
                reader.document.highlightColor, reader.document.referenceNames
            ) = previous
            reader.closeDeclarations(keeping: outer)
            reader.declarations.removeLast(reader.declarations.count - outer)
            reader.document.pageSettings.extraRowHeight = previousRowHeight
            reader.document.pageSettings.tableSpacing = tableRegisters
            reader.document.pageSettings.boxDefaults = previousSkin
            reader.document.hyperref = previousLinkColors
            reader.typewriter = previousFace
            reader.centered = previousCentered
            reader.scopedLanguage = previousScope
            (reader.document.pictureStyles, reader.document.plotDefaults, reader.document.colors) = pictureSettings
            reader.document.countRegisters = previousCounts
            reader.document.language = previousLanguage
            reader.document.localizedCaptions = previousCaptions
            reader.document.numberedBeamerCaptions = numberedBeamerCaptions
        }
    }

    private func openDeclaration(_ open: String, _ close: String, size: String? = nil) {
        guard declarations.last?.open != open,
            document.reserveExpansion(characters: open.utf8.count + close.utf8.count)
        else { return }
        if paragraph.isEmpty {
            declarations.append((open, close, size))
            return
        }
        reopenDeclarations()
        guard opened == declarations.count else { return }
        appendHTML(open, last: lastCharacter)
        declarations.append((open, close, size))
        opened += 1
    }

    // HTML inline tags end with their paragraph. A TeX declaration ends with its group,
    // so reopen it only when the next paragraph actually has content.
    private func reopenDeclarations() {
        guard opened < declarations.count, !document.stopsExpanding else { return }
        let remaining = declarations.dropFirst(opened)
        guard
            document.reserveExpansion(characters: remaining.reduce(0) { $0 + $1.open.utf8.count + $1.close.utf8.count })
        else { return }
        for declaration in remaining { paragraph += declaration.open }
        opened = declarations.count
    }

    private func closeDeclarations(keeping count: Int = 0) {
        while opened > count {
            opened -= 1
            paragraph += declarations[opened].close
        }
    }

    private func flush() {
        finishBoxes()
        closeDeclarations()
        if inlineLanguage != nil { paragraph += "</span>" }
        let text = paragraph.trimmingCharacters(in: Self.paragraphWhitespace)
        if !text.isEmpty {
            var attribute = noParagraphIndent ? " class=\"latex-noindent\"" : ""
            // Nested block readers may compact a plain paragraph into a list item or a note.
            // Only a paragraph in the main flow needs a per-paragraph override.
            if document.depth == 1, !centered, !closesRunInParagraph, floatKind == nil,
                document.classInfo.profile.body.composesLatinParagraphs,
                document.lineParameterAttribute != document.classInfo.initialLineParameters
            {
                attribute += document.lineParameterAttribute
            }
            // A solitary rule starts the float at its natural height, even when shorter than a text line.
            if floatKind == "figure",
                document.classInfo.profile.body.naturalRuleHeight || document.classInfo.resolvedStyle != nil,
                text.hasPrefix("<span class=\"latex-rule\" "), text.range(of: "</span>")?.upperBound == text.endIndex,
                !text.contains("vertical-align:")
            {
                attribute += " data-latex-rule-line"
            }
            var styles = centered ? ["text-align: center", "text-indent: 0"] : []
            if document.classInfo.profile.typography.selectsParagraphPitch || document.classInfo.resolvedStyle != nil,
                let size = declarations.last(where: { $0.size != nil })?.size,
                let pitch = LaTeXLabelMetrics(document.classInfo).baseline(for: size)
            {
                // TeX selects the paragraph's baseline skip from the size active at its end.
                styles.append(
                    "line-height: calc(\(LaTeXPageSettings.number(pitch)) * var(--tex-pt) * var(--latex-stretch, 1))")
            }
            if !styles.isEmpty { attribute += " style=\"\(styles.joined(separator: "; "))\"" }
            output += "<p\(attribute)>\(takeDestinations())\(text)</p>\n"
        }
        if closesRunInParagraph {
            output += "</div>\n"
            closesRunInParagraph = false
        }
        if let language = inlineLanguage {
            inlineLanguage = nil
            openLanguageSection(language)
        }
        noParagraphIndent = false
        paragraph = ""
        pendingSpace = nil
        lastCharacter = nil
        newlines = 0
    }

    func inline(_ text: String) -> String {
        let reader = LaTeXReader(text, document: document, isBlock: false)
        reader.longtableCaption = longtableCaption
        reader.floatKind = floatKind
        reader.typewriter = typewriter
        return reader.read()
    }

    /// A styled group may end with actual interword glue. Inspect what the reader consumed,
    /// not the last source character: a comment and its newline do not contribute a space.
    private func styledInline(_ source: String, typewriter: Bool? = nil) -> String {
        let reader = LaTeXReader(source, document: document, isBlock: false)
        reader.longtableCaption = longtableCaption
        reader.floatKind = floatKind
        reader.typewriter = typewriter ?? self.typewriter
        let html = reader.read()
        let endsInSpace = reader.paragraph.unicodeScalars.last.map(Self.paragraphWhitespace.contains) == true
        let trailing = reader.pendingSpace != nil || endsInSpace
        return trailing && !html.isEmpty ? html + " " : html
    }

    func blocks(_ text: String) -> String {
        let reader = LaTeXReader(text, document: document, isBlock: true)
        reader.longtableCaption = longtableCaption
        reader.floatKind = floatKind
        reader.typewriter = typewriter
        return reader.read()
    }

    /// An item's or a note's HTML: a single paragraph without its `<p>`.
    private func compact(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<p>"), let end = trimmed.range(of: "</p>"), end.upperBound == trimmed.endIndex {
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
            if comments, character == "\\", let end = opaqueEnd() {
                text.append(contentsOf: buffer[index..<end])
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
        if let name = kernelLoopName() {
            skipSpacesAfterControlWord()
            readLoop(name)
            return
        }
        if !next.isASCII, let name = societyDateControlWord() {
            skipSpacesAfterControlWord()
            dispatch(name)
            return
        }
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
        var offset = 1
        while peek(offset) == " " || peek(offset) == "\t" { offset += 1 }
        if peek(offset) == "\n" { return }
        index += offset
    }

    private func verticalGlue(_ value: String) -> String? {
        guard let length = LaTeXSymbols.printLength(value) else { return nil }
        let property = value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") ? "margin-bottom" : "height"
        return "\(property): \(length)"
    }

    func verticalSpace(_ value: String, keep: Bool = false) {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if source == "\\fill", document.insideTitlePage {
            appendBlock("<div class=\"latex-vfill\"></div>\n")
            return
        }
        var natural = source
        var mark = keep ? " data-latex-keep-space" : ""
        if document.classInfo.resolvedStyle != nil {
            // An infinite skip keeps its natural dimension while its highest order alone absorbs surplus height.
            let specification = source == "\\fill" ? "0 plus 1fill" : source
            if let glue = specification.wholeMatch(
                of: /(.+?)\s*plus\s*([+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+))\s*(fil{1,3})(?:\s*minus\s*.+)?/),
                let coefficient = Double(glue.2), coefficient.isFinite
            {
                natural = String(glue.1)
                if coefficient > 0 {
                    mark += " data-latex-fil=\"\(LaTeXPageSettings.number(coefficient))\""
                    let order = glue.3.count - 2
                    if order > 1 { mark += " data-latex-fil-order=\"\(order)\"" }
                }
            }
        }
        guard let glue = verticalGlue(natural) else { return }
        appendBlock("<div class=\"latex-vspace\"\(mark) style=\"\(glue)\"></div>\n")
    }

    private func thinSpace() {
        // Keep the original text character for native layout and extraction. A composed line
        // uses the explicit TeX kern even when the font gives that character a different width.
        let conference = document.classInfo.resolvedStyle != nil
        if !typewriter && document.composesEnglishParagraphs {
            let text = conference ? "&#8239;" : "\u{2009}"
            appendHTML("<span data-latex-thin-space>\(text)</span>", last: conference ? "x" : "\u{2009}")
        } else if conference {
            appendHTML("&#8239;")
        } else {
            appendText("\u{2009}")
        }
    }

    func controlSymbol(_ symbol: Character) {
        switch symbol {
        case "\\":
            _ = star()
            let skip = optional()
            appendHTML("<br>")
            if let skip, let glue = verticalGlue(skip) {
                // A block inside the paragraph separates the two line boxes without a second parskip.
                appendHTML("<span class=\"latex-vspace\" style=\"display: block; \(glue)\"></span>")
            }
        case ",": thinSpace()
        case ":" where document.classInfo.resolvedStyle != nil, ";" where document.classInfo.resolvedStyle != nil:
            appendHTML("&nbsp;")
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
        if handleCorrespondence(name) || handleExamCommand(name) { return }
        if handleFileCommand(name) || handleLanguage(name) || handleBeamerCommand(name) || handleFrontMatter(name) {
            return
        }
        if handleControl(name) || handleCounter(name) || handleText(name) || handleReference(name) { return }
        switch name {
        case "begin": environment()
        case "documentclass": readDocumentClass()
        case "end":
            if argument() == "document", document.startedDocument { document.endedDocument = true }
        default: typesettingCommand(name)
        }
    }

    // Reading a nested environment must not keep the temporaries for unrelated commands on the stack.
    private func typesettingCommand(_ name: String) {
        switch name {
        case "part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph":
            section(name)
        case "frontmatter", "mainmatter", "backmatter":
            bookMatter(name)
        case "maketitle": makeTitle()
        case "minisec" where document.classInfo.profile.classCommands.contains(name):
            appendBlock("<h6\(bookHeadingAttributes(name))>\(inline(argument() ?? ""))</h6>\n")
        case "addchap", "addsec":
            section(name == "addchap" ? "chapter" : "section", numbered: false, listed: !star())
        case "epigraph":
            let quotation = blocks(argument() ?? "")
            let attribution = inline(argument() ?? "")
            appendBlock(
                "<blockquote class=\"latex-epigraph\">\(quotation)<footer>\(attribution)</footer></blockquote>\n")
        case "tableofcontents", "listoffigures", "listoftables": appendContentsList(name)
        case "addcontentsline":
            let list = argument()
            let unit = argument() ?? ""
            let source = argument() ?? ""
            if list == "toc", let level = LaTeXCounters.levels.firstIndex(of: unit) {
                let id: String
                if let precedingUnnumberedHeading {
                    id = precedingUnnumberedHeading
                } else {
                    id = document.counters.anchor("toc-entry", suffix: String(document.headings.count + 1))
                    let anchor = "<span id=\"\(id)\"></span>"
                    appendDestination(anchor)
                }
                document.headings.append(.init(level: level, number: "", id: id, title: inline(source)))
            }
        case "addtocontents":
            _ = argument()
            _ = argument()

        case "newblock"
        where document.readsBibliographyEntry && document.composesEnglishParagraphs:
            if document.opensBibliographyBlocks {
                paragraphBreak()
            } else {
                appendHTML("<span data-latex-newblock> </span>", last: " ")
            }
        case "newblock" where document.bibDatabase.natbib: appendText(" ")
        case "today": appendText(document.today())
        case "label": label()
        case "citealp" where document.bibDatabase.natbib: cite(name)
        case "cite", "citep", "citet", "parencite", "textcite", "autocite", "citeauthor", "citeyear": cite(name)
        case "bibliography", "printbibliography", "addbibresource", "bibliographystyle", "setcitestyle", "nocite":
            externalBibliography(name)
        case "hypersetup": readHyperrefOptions(argument() ?? "")
        case "usepackage", "RequirePackage": readPackage(command: name)
        case "qed", "qedsymbol": appendText("□")
        case "qedhere": break
        case "vfil" where document.classInfo.resolvedStyle != nil: verticalSpace("0pt plus 1fil")
        case "vfill": verticalSpace("\\fill")
        case "thinspace": thinSpace()
        case "nobreakspace": appendHTML("&nbsp;")
        case "centering": centered = true
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
            let hyphens =
                document.breaksURLsAfterHyphens && document.composesEnglishParagraphs ? " data-latex-url-hyphens" : ""
            let href = name == "url" ? " href=\"\(HTML.escape(url))\"" : ""
            appendHTML(styledLinks("<a class=\"latex-url\"\(href)\(hyphens)>\(breakableURL(url))</a>"))
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
        case "fbox": appendBox(cssClass: "latex-fbox", style: "")
        case "newline", "linebreak":
            _ = optional()
            appendHTML("<br>")
        case "twocolumn", "onecolumn":
            if name == "twocolumn" { document.hasAuthoredColumns = true }
            appendBlock(document.columnMarker(name == "twocolumn" ? 2 : 1))
            if name == "twocolumn", let title = optional() {
                if document.classInfo.resolvedStyle?.usesAffiliationList == true {
                    document.readingConferenceTitle = true
                    _ = blocks(title)
                    document.readingConferenceTitle = false
                    makeTitle()
                } else {
                    appendBlock("<div data-latex-wide>\(blocks(title))</div>\n")
                }
            }
        case "newpage", "clearpage", "cleardoublepage", "pagebreak", "columnbreak":
            _ = optional()
            let kind = name.hasPrefix("clear") ? "clear" : "column"
            let legacy = name == "columnbreak" ? "" : " class=\"latex-pagebreak\""
            appendBlock("<div\(legacy) data-latex-break=\"\(kind)\"></div>\n")
        case "noindent":
            if paragraph.isEmpty { noParagraphIndent = true }
        case "par": paragraphBreak()
        case "bigskip": verticalSpace("12pt")
        case "medskip": verticalSpace("6pt")
        case "smallskip": verticalSpace("3pt")
        case "vspace":
            let keep = star()
            if let value = argument() { verticalSpace(value, keep: keep) }
        case "hspace":
            _ = star()
            if let length = argument().flatMap(LaTeXSymbols.printLength) {
                appendHTML("<span class=\"latex-hspace\" style=\"width: \(length)\"></span>")
            }
        case "item": appendText("• ")
        case "graphicspath": document.graphicsPaths = graphicsPaths(argument() ?? "")
        case "appendix":
            document.isAppendix = true
            document.counters[document.hasChapters ? "section" : "subsection"] = 0
            let counter = document.hasChapters ? "chapter" : "section"
            document.counters[counter] = 0
            document.macros.removeValue(forKey: "the" + counter)

        case "DeclareMathOperator": declareOperator()
        case "definecolor": defineColor()
        case "colorlet", "tikzset", "pgfplotsset", "usetikzlibrary": configurePicture(name)
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
        case "scalebox", "resizebox": scaledBox(name)
        case "rule": appendRule()
        case "caption": caption()
        case "c", "k", "d", "b", "r", "t", "u", "v", "H":
            if let mark = LaTeXSymbols.accents[Character(name)] { accent(mark) }
        default: generic(name)
        }
    }

    private func appendContentsList(_ name: String) {
        let (list, key): (LaTeXDocument.ContentsList, String)
        switch name {
        case "listoffigures": (list, key) = (.figures, "listfigurename")
        case "listoftables": (list, key) = (.tables, "listtablename")
        default:
            let depth = min(5, max(-2, document.counters["tocdepth"]))
            // Each heading records whether it is in the appendix, which selects one of these two formats.
            // Both use the names in force here: renaming \appendixname after the contents does not reach them.
            let formats =
                document.classInfo.profile.structure.formatsContentsChapterNames && document.language == "ja"
            let number = document.placeholder("N", 0)
            (list, key) = (
                .headings(
                    depth: depth, chapterFormat: formats ? numberedHeading("chapter", number: number) : nil,
                    appendixFormat: formats ? numberedHeading("appendix", number: number) : nil),
                "contentsname"
            )
        }
        let opening = document.classInfo.hasChapters ? " data-latex-chapter-opening" : ""
        let pageStyle = document.bodyPageStyles ?? document.classInfo.pageNumbers
        let mark =
            document.classInfo.profile.structure.contents == .chapterMarks && pageStyle.writesContentsMark
            ? " data-latex-contents-mark" : ""
        let caption = captionName(key)
        let title =
            document.classInfo.profile.structure.contents == .sectionTitle
            ? "<h2 class=\"latex-contents-title\" data-latex-heading=\"section\">\(caption)</h2>"
            : "<p class=\"latex-contents-title\">\(caption)</p>"
        let bookMark =
            document.classInfo.profile.structure.bookOpening == nil
            ? "" : " data-latex-book-mark=\"\(HTML.escape(DocumentOutline.plainText(ofHTML: caption)))\""
        let measure = document.classInfo.profile.structure.contentsMeasure.attributes
        let nav =
            "<nav class=\"toc\"\(opening)\(mark)\(bookMark)\(measure)>\(title)"
            + document.contentsPlaceholder(list) + "</nav>\n"
        let kind: ReaderContentsKind =
            switch list {
            case .figures: .figures
            case .tables: .tables
            case .headings: .contents
            }
        appendBlock(styledLinks(kind.mark(nav), block: true))
    }

    private func ruleLength(_ source: String) -> String? {
        if let size = document.classInfo.beamerPageSize,
            let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
                .wholeMatch(of: /(-?[0-9]*\.?[0-9]*)\s*\\paper(width|height)/)
        {
            let factor = value.1.isEmpty ? 1 : Double(value.1)
            guard let factor, factor.isFinite else { return nil }
            return LaTeXPageSettings.number(factor * (value.2 == "width" ? size.width : size.height)) + "pt"
        }
        return LaTeXSymbols.printLength(source)
    }

    private func appendRule() {
        let raise = optional().flatMap(ruleLength)
        let width = argument().flatMap(ruleLength)
        let rawHeight = argument() ?? ""
        let height = ruleLength(rawHeight)
        if let width, let height {
            let lift = raise.map { "; vertical-align: \($0)" } ?? ""
            // A subpixel fill can disappear when WebKit snaps its paint bounds. Paint a taller rectangle
            // and scale its ink back into the actual TeX box.
            let hairline =
                LaTeXPageSettings.millimetres(rawHeight).map { $0 > 0 && $0 < 0.5 * 25.4 / 72.27 } ?? false
            let style =
                "display: inline-block; width: \(width); height: \(height)\(lift)"
                + (hairline ? "; position: relative" : "; background: currentColor")
                + "; -webkit-print-color-adjust: exact"
            let ink =
                hairline
                ? #"<i aria-hidden="true" style="position: absolute; inset-inline: 0; top: 0; height: 1000%; background: currentColor; transform-origin: top; transform: scaleY(.1)"></i>"#
                : ""
            appendHTML("<span class=\"latex-rule\" style=\"\(style)\">\(ink)</span>")
        }
    }

    func pageAction(_ action: String, _ value: String) {
        if inPreamble {
            document.preamblePageActions.append((action, value))
            document.classInfo.pageNumbers.apply(action, value: value)
        } else {
            if action == "pagestyle" || action == "fancyStyle" {
                if document.bodyPageStyles == nil { document.bodyPageStyles = document.classInfo.pageNumbers }
                document.bodyPageStyles?.apply(action, value: value)
            }
            // A declaration between blocks must not introduce a paragraph (or split an existing one).
            let marker =
                "<span data-latex-page-action=\"\(HTML.escape(action))\" data-value=\"\(HTML.escape(value))\"></span>"
            if paragraph.isEmpty && isBlock { output += marker } else { paragraph += marker }
        }
    }

    private func readFancyFields(_ name: String, apply: (String, String) -> Void) -> Bool {
        switch name {
        case "fancyhead", "fancyfoot", "fancyhf", "lhead", "chead", "rhead", "lfoot", "cfoot", "rfoot":
            let option = optional()
            let value = argument() ?? ""
            let row = name.hasSuffix("head") ? "H" : name.hasSuffix("foot") ? "F" : ""
            if name.hasPrefix("fancy") {
                let selectors = (option ?? "").uppercased().components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines) + row
                }.joined(separator: ",")
                apply(selectors, value)
            } else {
                let slot = name.prefix(1).uppercased() + row
                if let option {
                    apply("E" + slot, option)
                    apply("O" + slot, value)
                } else {
                    apply(slot, value)
                }
            }
            return true
        default: return false
        }
    }

    func readFancyRule(_ name: String, value: String) {
        if ["headrulewidth", "footrulewidth"].contains(name), LaTeXPageSettings.millimetres(value) != nil {
            pageAction(name, value)
        }
    }

    func defineFancyPageStyle() {
        let snapshot = star()
        let name = (argument() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = optional()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reader = LaTeXReader(argument() ?? "", document: document, isBlock: false)
        guard !name.isEmpty else { return }
        var definition = LaTeXPageNumbers.Definition(name: name, base: base, snapshotsFields: snapshot)
        // The replacement is stored now and selected at shipout. Parse only top-level field
        // assignments, so rule declarations and macros inside the replacement never run as prose.
        while let character = reader.peek() {
            if character == "\\" {
                let command = reader.controlToken()
                if [#"\renewcommand"#, #"\def"#].contains(command) {
                    if command == #"\renewcommand"# { _ = reader.star() }
                    let register = reader.argument() ?? ""
                    let value = reader.argument() ?? ""
                    if [#"\headrulewidth"#, #"\footrulewidth"#].contains(register),
                        LaTeXPageSettings.millimetres(value) != nil
                    {
                        definition.fields[String(register.dropFirst())] = value
                    }
                    continue
                }
                _ = reader.readFancyFields(String(command.dropFirst())) {
                    LaTeXPageNumbers.setFields($0[...], value: $1, in: &definition.fields)
                }
            } else if character == "{" {
                _ = reader.argument()
            } else {
                reader.index += 1
            }
        }
        if inPreamble {
            document.classInfo.pageNumbers.define(definition)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let encoded = try? encoder.encode(definition) {
            pageAction("fancyStyle", String(decoding: encoded, as: UTF8.self))
        }
    }

    private func generic(_ name: String) {
        if readFancyFields(name, apply: { pageAction("fancy:" + $0, $1) }) { return }
        switch name {
        case "pagestyle", "thispagestyle":
            let style = argument() ?? ""
            pageAction(name, style.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        case "pagenumbering":
            let format = argument() ?? ""
            if ["roman", "Roman", "alph", "Alph", "arabic"].contains(format) { pageAction(name, format) }
            return
        case "markboth", "markright":
            if name == "markboth" { pageAction("leftmark", LaTeXPageNumbers.text(argument() ?? "")) }
            pageAction("rightmark", LaTeXPageNumbers.text(argument() ?? ""))
            return
        default: break
        }

        if readBookClassSetting(name) || readPageSetting(name) || handleLayoutSetting(name) { return }
        if let family = document.pageSettings.fonts.selectors[name] {
            openDeclaration(
                "<span class=\"latex-font-family\" style=\"--latex-local-font: \(HTML.escape(family))\">", "</span>")
            return
        }
        if let wrapper = LaTeXSymbols.wrappers[name] {
            if let count = wrapper.setup {
                _ = star()
                while optional() != nil {}
                for _ in 0..<count { _ = argument() }
                while optional() != nil {}
            }
            let face = name == "texttt" ? true : ["textrm", "textsf", "textnormal"].contains(name) ? false : nil
            appendHTML(wrapper.open + styledInline(argument() ?? "", typewriter: face) + wrapper.close)
        } else if let declaration = LaTeXSymbols.declarations[name] {
            if ["tt", "ttfamily"].contains(name) { typewriter = true }
            if ["rm", "rmfamily", "sf", "sffamily", "normalfont"].contains(name) { typewriter = false }
            if !declaration.open.isEmpty {
                openDeclaration(declaration.open, declaration.close)
            }
        } else if let size = LaTeXSymbols.sizes[name] {
            openDeclaration(sizeOpening(name, relativeSize: size), "</span>", size: name)
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

    func readPreamble() {
        let previous = inPreamble
        inPreamble = true
        defer { inPreamble = previous }
        while !document.startedDocument, let character = peek() {
            if PreviewConversion.expired { return }
            retireFileFrames()
            if let end = opaqueEnd() {
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
            if handleMacro(name) || handleCorrespondence(name) || handleExamCommand(name) || handleFileCommand(name)
                || handleLanguage(name) || handleFrontMatter(name)
                || handleBeamerCommand(name)
            {
                continue
            }
            if handleControl(name) || handleCounter(name) || handleReference(name)
                || name == "sethlcolor" && handleText(name)
            {
                continue
            }
            switch name {
            case "begin":
                let environment = argument() ?? ""
                if let section = societyAbstract(environment) {
                    readSocietyAbstract(section, body: environmentBody(environment))
                } else if ["abstract", "CCSXML", "keyword", "keywords", "IEEEkeywords"].contains(environment) {
                    readFrontEnvironment(environment, body: environmentBody(environment))
                } else if environment == "document" {
                    document.resolveStylePackage()
                    document.classInfo.initialLineParameters = document.lineParameterAttribute
                    document.startedDocument = true
                    document.landscapeBody = onlyLandscapeBody()
                    flush()
                    output = ""
                }
            case "PassOptionsToPackage":
                let options = Self.packageOptions(argument() ?? "")
                if let name = argument()?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    document.passedPackageOptions[name, default: []] += options
                }
            case "iclrfinalcopy": document.finalCopy = true
            case "workshoptitle": document.workshopTitle = LaTeXPageNumbers.text(argument() ?? "")
            case "documentclass":
                readDocumentClass()

            case "DeclareMathOperator": declareOperator()
            case "definecolor": defineColor()
            case "colorlet", "tikzset", "pgfplotsset", "usetikzlibrary": configurePicture(name)
            case "lstset", "lstdefinestyle": configureListings(name)
            case "graphicspath": document.graphicsPaths = graphicsPaths(argument() ?? "")
            case "hypersetup": readHyperrefOptions(argument() ?? "")
            case "usepackage", "RequirePackage": readPackage(command: name)
            case "addbibresource", "bibliographystyle", "setcitestyle", "nocite": externalBibliography(name)
            default: generic(name)
            }
        }
    }

    // The renderer can orient a whole job before it measures the first strip. Only a
    // complete landscape body establishes that orientation for every logical page.
    private func onlyLandscapeBody() -> Bool {
        let saved = index
        defer { index = saved }
        skipSpaces()
        var found = false
        while peek() == "\\" {
            let token = controlToken()
            if token == "\\end" { return found && argument() == "document" }
            if ["\\pagestyle", "\\thispagestyle", "\\pagenumbering"].contains(token) {
                guard argument() != nil else { return false }
                skipSpaces()
                continue
            }
            guard token == "\\begin", argument() == "landscape" else { return false }
            guard environmentBodyRange("landscape").closed else { return false }
            found = true
            skipSpaces()
        }
        return false
    }

    func declaration(_ command: String, argumentsFrom start: Int) -> String {
        // Dispatch has already consumed whitespace after the control word.
        var first = start
        while first > 0, buffer[first - 1].isWhitespace { first -= 1 }
        let text = "\\" + command + String(buffer[first..<index])
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func readDocumentClass() {
        let start = index
        var options = optional()
        let name = argument()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? LaTeXClassID.article.rawValue
        document.classInfo = LaTeXDocumentClassInfo(name: name, options: options)
        document.classOffersComposition =
            document.classInfo.profile.structure.offersCompositionChoice
            && document.classInfo.columns == 1 && !Self.packageOptions(options ?? "").contains("twocolumn")
        if document.classOffersComposition && document.requestedComposition == .twoColumn {
            options = [options, "twocolumn"].compactMap { $0 }.joined(separator: ",")
            document.classInfo = LaTeXDocumentClassInfo(name: name, options: options)
        }
        document.classInfo.classDeclaration = declaration("documentclass", argumentsFrom: start)
        if document.classInfo.profile.body.usesSloppyLineBreaking { document.lineParameters.setSloppy(true) }
        document.classInfo.journalStyle?.defineCounters(in: document)
        if let depth = document.classInfo.profile.headings.numberingDepth { document.counters["secnumdepth"] = depth }
        document.pageSettings.readClassOptions(options ?? "", info: document.classInfo)
        document.classLanguageOptions = (options ?? "").components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if document.classInfo.profile.body.readsQuestions {
            document.booleans["printanswers"] = document.classLanguageOptions.contains("answers")
        }
        document.language = document.classInfo.mainLanguage
        document.nativeCaptionLanguage = document.language == "en" ? nil : document.language
        if document.classInfo.hasChapters { document.hasChapters = true }
        if let depth = document.classInfo.profile.structure.contentsDepth { document.counters["tocdepth"] = depth }
        if !inPreamble && isBlock && document.classInfo.columns > 1 {
            appendBlock(document.columnMarker(document.classInfo.columns))
        }
    }

    private func controlTokenName() -> Substring {
        if let name = kernelLoopName() { return name[...] }
        if let next = peek(), !next.isASCII, let name = societyDateControlWord() { return name[...] }
        let start = index
        while let character = peek(), character.isASCII, character.isLetter { index += 1 }
        if index == start, peek() != nil { index += 1 }
        return Substring(String(buffer[start..<index]))
    }

    private func declareOperator() {
        let limits = star()
        guard let name = argument()?.trimmingCharacters(in: .whitespaces), name.hasPrefix("\\") else { return }
        let text = argument() ?? ""
        if document.mathDefinitions.preview != nil {
            addMathDefinition("\\DeclareMathOperator\(limits ? "*" : ""){\(name)}{\\mathrm{\(text)}}")
            return
        }
        // SwaTex uses a separate operator-base layout for display limits. That path does not
        // give bare letters the roman font of the standalone operator-name layout.
        addMathDefinition("\\def\(name){\\operatorname\(limits ? "*" : ""){\\mathrm{\(text)}}}")
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

    private func bookMatter(_ name: String) {
        guard let opening = document.classInfo.profile.structure.bookOpening else {
            generic(name)
            return
        }
        // Front and main matter start an odd numbered sequence even in an openany book.
        let structure = document.classInfo.profile.structure
        let side: LaTeXClassProfile.OpeningSide
        if name == "backmatter" {
            side = structure.backMatterOpensRight ? .right : opening
        } else {
            side = document.classInfo.profile.pageStyle.twoSidedNumbers ? .right : .any
        }
        appendBlock("<template data-latex-break=\"\(side.rawValue)\"></template>")
        document.numbersChapters = name == "mainmatter"
        let options = structure.readsMatterOptions
        let starred = options && star()
        let format =
            (options ? optional() : nil) ?? (name == "frontmatter" ? "roman" : name == "mainmatter" ? "arabic" : "")
        if !starred, !format.isEmpty { pageAction("pagenumbering", format) }
    }

    func section(_ name: String, numbered: Bool = true, listed: Bool = true) {
        // A chapter in skipped code cannot change the numbering of an article.
        if name == "chapter" { document.hasChapters = true }
        let starred = star()
        let short = optional()
        let source = argument() ?? ""
        let headings = document.classInfo.profile.headings
        if name == "part" {
            if let opening = document.classInfo.profile.structure.bookOpening {
                appendBlock("<template data-latex-break=\"\(opening.rawValue)\"></template>")
            }
            let hasNumber = numbered && !starred && document.counters["secnumdepth"] >= (document.hasChapters ? -1 : 0)
            let numeral = hasNumber ? stepCounter("part") : ""
            if !numeral.isEmpty, numeral.contains(where: \.isLetter) { document.hasNonArabicHeading = true }
            let label = numberedHeading("part", number: numeral) + document.headingEndDot
            let id = document.counters.anchor("part", suffix: hasNumber ? String(document.counters["part"]) : "u")
            document.labelTarget = (numeral, id)
            let title = inline(source)
            document.describeTarget(id, kind: "part", title: title)
            if !starred && listed {
                document.headings.append(
                    .init(
                        chapterLabelHTML: document.classInfo.profile.structure.contents == .chapterMarks
                            && document.language == "ja" ? label : nil, level: -1,
                        number: hasNumber ? numeral + document.headingEndDot : "", id: id,
                        title: short.map(inline) ?? title))
            }
            let partTitle =
                headings.wrapsChapterTitle
                ? "<span class=\"latex-chapter-title\">\(title)</span>" : title
            let pageStyle =
                headings.emptyPartPage
                ? " data-latex-page-action=\"thispagestyle\" data-value=\"empty\"" : ""
            appendBlock(
                "<h2 class=\"latex-part\"\(pageStyle) id=\"\(id)\">\(!hasNumber ? "" : "<span class=\"secnum\">\(label)</span>")\(partTitle)</h2>\n"
            )
            if let opening = document.classInfo.profile.structure.bookOpening {
                appendBlock("<template data-latex-break=\"\(opening.rawValue)\"></template>")
            }
            return
        }
        let level = LaTeXCounters.levels.firstIndex(of: name) ?? 1
        let first = document.hasChapters ? 0 : 1
        let deepestNumbered = document.counters["secnumdepth"]
        var number: String?
        var display: String?
        let numberingLevel = headings.groupsParagraphsAtThirdLevel ? min(level, 3) : level
        if numbered, !starred, level != 0 || document.numbersChapters, numberingLevel <= deepestNumbered, level >= first
        {
            number = stepCounter(name)
            if level == 0, let chapter = number {
                display =
                    headings.chapterLabel == .bareNumber || document.classInfo.bookStyle.chapterStyle != "default"
                    ? HTML.escape(chapter)
                    : numberedHeading(document.isAppendix ? "appendix" : "chapter", number: chapter)
            } else if level == first, document.isAppendix, document.classInfo.isVertical, let section = number {
                display = appendixNumber(section)
            } else {
                display = number.map {
                    HTML.escape(
                        document.classInfo.journalStyle?.headingNumber(
                            $0, command: name, counter: document.counters[name]) ?? $0)
                }
            }
        }
        if let number, number.contains(where: \.isLetter) { document.hasNonArabicHeading = true }
        let endDot = document.classInfo.resolvedStyle?.headingDot == true ? "." : document.headingEndDot
        display = display.map {
            headings.sectionDot && name == "section" && !$0.hasSuffix(".") ? $0 + "." : $0 + endDot
        }
        let suffix = number?.replacingOccurrences(of: ".", with: "-") ?? "u\(document.headings.count + 1)"
        let id = document.counters.anchor("sec", suffix: suffix)
        let tag = min(level - first + 2, 6)
        document.labelTarget = (number ?? "", id)
        let title = inline(source)
        document.describeTarget(id, kind: document.isAppendix && level == first ? "appendix" : name, title: title)
        // Spanish babel punctuates section headings and their contents entries, but not references.
        let dot =
            document.language == "es" && document.classicBabelLanguages.contains("es") && document.spanishSectionDots
        if dot, level > 0 { display = display.map { $0.hasSuffix(".") ? $0 : $0 + "." } }
        let tocSuffix = dot ? "." : document.headingEndDot
        let tocNumber = listed && !starred ? number.map { $0 + tocSuffix } ?? "" : nil
        // The contents prefer this label to the number, so it keeps the suffix outside the upright letters.
        let chapterLabel =
            name == "chapter" && document.classInfo.profile.structure.contents == .chapterMarks
                && document.language == "ja"
            ? display
            : level == first && document.isAppendix && document.classInfo.isVertical
                ? number.map { appendixNumber($0) + HTML.escape(tocSuffix) } : nil
        let shortTitle = short.map(inline) ?? title
        document.headings.append(
            .init(
                chapterLabelHTML: chapterLabel, level: level, number: tocNumber, id: id,
                title: shortTitle, appendix: document.isAppendix))
        if headings.navigationOnlySections, name == "section" || name == "subsection" || name == "subsubsection" {
            // Navigation and explicit contents pages still need the section destination.
            beamerSection(name, title: title, id: id, listed: !starred && listed)
            precedingUnnumberedHeading = starred || !numbered ? id : nil
            return
        }
        let numberHTML = display.map { "<span class=\"secnum\">\($0)</span>" } ?? ""
        let amsRunIn = document.classInfo.journalStyle == .ams && ["subsection", "subsubsection"].contains(name)
        let runIn =
            (!headings.displayParagraphs && (name == "paragraph" || name == "subparagraph")) || amsRunIn
            || name == "subsubsection" && document.classInfo.resolvedStyle?.runInSubsubsection == true
        let kind = runIn ? " class=\"latex-runin-\(name)\"" : ""
        // An HTML newline becomes an extra word space when the theme puts the heading and paragraph on one line.
        let mark =
            name == "paragraph" && headings.readsParagraphMark ? captionName("jsParagraphMark") : ""
        if name == "chapter" {
            let opening = document.classInfo.profile.structure.bookOpening?.rawValue ?? "page"
            appendBlock("<template data-latex-break=\"\(opening)\"></template>")
        }
        var grid = headings.marksHeadingLevel ? " data-latex-heading=\"\(name)\"" : ""
        if name == "chapter", display != nil, document.isAppendix, document.classInfo.usesTraditionalJapaneseNames {
            grid += " data-latex-appendix"
        }
        let sectionTitle =
            (headings.smallCapsSections && name == "section")
                || (document.classInfo.resolvedStyle?.displayFace == .smallCaps
                    && ["section", "subsection", "subsubsection", "subparagraph"].contains(name))
            ? LaTeXJournalStyle.smallCaps(title, in: document) : title
        let headTitle =
            name == "chapter" && headings.wrapsChapterTitle
            ? "<span class=\"latex-chapter-title\">\(title)</span>" : shortHeadingBox(sectionTitle)
        let bookMark: String
        if document.classInfo.profile.structure.bookOpening != nil, !starred, listed, level == 0 || level == 1 {
            let japanese =
                name == "chapter" && document.language == "ja"
                && (headings.chapterLabel == .spacedJapaneseNumber
                    || headings.chapterLabel == .traditionalJapaneseNumber)
            let prefix =
                display.map {
                    let number = DocumentOutline.plainText(ofHTML: $0)
                    return japanese
                        ? number.replacingOccurrences(of: " ", with: "\u{2005}") + "　"
                        : number + headings.runningNumberSeparator
                } ?? ""
            let text = prefix + DocumentOutline.plainText(ofHTML: shortTitle)
            bookMark = " data-latex-book-mark=\"\(HTML.escape(text))\""
        } else {
            bookMark = ""
        }
        let heading =
            "<h\(tag)\(kind)\(grid)\(bookHeadingAttributes(name))\(bookMark) id=\"\(id)\">\(numberHTML)\(mark)\(amsRunIn ? LaTeXFrontMatter.period(headTitle) : headTitle)</h\(tag)>"
        if runIn && isBlock {
            appendBlock("<div class=\"latex-runin\">" + heading)
            closesRunInParagraph = true
        } else {
            appendBlock(heading + "\n")
        }
        precedingUnnumberedHeading = starred || !numbered ? id : nil
    }

    /// The width is evaluated after font selection, since a mixed title need not be an integral number of cells.
    func shortHeadingBox(_ html: String) -> String {
        guard document.classInfo.profile.headings.distributesShortTitles else { return html }
        return "<span class=\"latex-heading-measure\">\(html)</span>"
    }

    /// LaTeX selects a size from the class table even inside a larger title or author line.
    func sizeOpening(_ name: String, relativeSize: Double) -> String {
        let factor = String(format: "%g", relativeSize)
        if let pitch = LaTeXLabelMetrics(document.classInfo).baseline(for: name),
            document.classInfo.profile.typography.selectsParagraphPitch || document.classInfo.resolvedStyle != nil
        {
            return
                "<span data-latex-text-size=\"\(name)\" style=\"font-size: var(--latex-size-\(name), \(factor)em); --latex-selected-pitch: calc(\(LaTeXPageSettings.number(pitch)) * var(--tex-pt) * var(--latex-stretch, 1))\">"
        }
        guard document.makingTitle else { return "<span style=\"font-size: \(factor)em\">" }
        return "<span style=\"font-size: var(--latex-size-\(name), \(factor)rem)\">"
    }

    private func label() {
        let key = argument()?.trimmingCharacters(in: .whitespaces) ?? ""
        if let target = document.labelTarget, !key.isEmpty { document.labels[key] = target }
    }

    func unsupported(_ message: String, picture: Bool = false) -> String {
        let role = picture ? " data-latex-picture" : ""
        return "<div class=\"latex-unsupported\"\(role)>\(HTML.escape(message))</div>\n"
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
        appendHTML(styledLinks("<a href=\"\(HTML.escape(url))\">\(text)</a>"))
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
        openDeclaration("<span style=\"color: \(css)\">", "</span>")
    }

    private func colorBox(framed: Bool) {
        let frame = framed ? color() : nil
        let background = color()
        var style = background.map { "background: \($0); " } ?? ""
        if let frame { style += "border: 0.5pt solid \(frame); " }
        appendBox(cssClass: "latex-colorbox", style: style)
    }

    private func appendBox(cssClass: String, style: String) {
        let source = argument() ?? ""
        if appendDecoratedLayoutBox(source, cssClass: cssClass, style: style) { return }
        let content = blocks(source)
        let attribute = style.isEmpty ? "" : " style=\"\(style)\""
        let inlineContent = compact(content)
        if content.isEmpty || inlineContent != content.trimmingCharacters(in: .whitespacesAndNewlines) {
            let html = "<span class=\"\(cssClass)\"\(attribute)>\(inlineContent)</span>"
            let after = index
            skipSpaces()
            let followedByFill = peek() == "\\" && LaTeXLexer.word(characters, at: index + 1) == "hfill"
            index = after
            if !boxes.isEmpty || paragraph.isEmpty && followedByFill {
                appendLayoutBox(html)
            } else {
                appendHTML(html)
            }
        } else {
            appendBlock("<div class=\"\(cssClass)\"\(attribute)>\(content)</div>\n")
        }
    }

    private func breakableURL(_ url: String) -> String {
        // Keep the scheme and both slashes together. Unbreakable runs also protect
        // percent escapes and query values from a theme's general long-token wrapping.
        var rest = url[...]
        var run = ""
        if let scheme = url.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) {
            run = String(url[..<scheme.upperBound])
            rest = url[scheme.upperBound...]
        }
        let separators = "/.-?&="
        let count = rest.reduce(0) { $0 + (separators.contains($1) ? 1 : 0) }
        // A pathological run of slashes must not allocate one element per source byte.
        guard document.reserveExpansion(characters: 13 + count * 18) else { return "<span>\(HTML.escape(url))</span>" }
        var html = ""
        func finishRun() {
            if !html.isEmpty { html += "<wbr>" }
            html += "<span>\(HTML.escape(run))</span>"
            run = ""
        }
        for character in rest {
            run.append(character)
            if separators.contains(character) { finishRun() }
        }
        if !run.isEmpty { finishRun() }
        return html
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
    private func mathSource(closing: String) -> (latex: String, original: String) {
        let start = index
        let closer = Array(closing)
        var text = ""
        while index < characters.count {
            if index + closer.count <= characters.count, Array(characters[index..<(index + closer.count)]) == closer {
                let original = String(characters[start..<index])
                index += closer.count
                return (text, original)
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
        return (text, String(characters[start..<index]))
    }

    func formula(
        _ latex: String, display: Bool, source: String, expanded: Bool = false, numbers: [String?] = [],
        budget: ReaderMathBudget? = nil
    )
        -> String
    {
        // amsthm's `\qedhere` only moves the end-of-proof box, which SwaTex does not know.
        guard let resolved = expanded ? latex : expandMathCommands(latex, budget: budget) else {
            return MathRenderer.fallback(source, display: display)
        }
        let (clean, labels) = Self.removingLabels(resolved)
        let anchor = mathAnchor(labels, tag: Self.explicitTag(clean))
        let units = LaTeXUnits.expandingInMath(clean.replacingOccurrences(of: "\\qedhere", with: ""))
        guard let math = mathWithLoopVariables(units) else { return anchor }
        if math.contains("\\ref") || math.contains("\\eqref") {
            document.deferredMath.append(
                .init(
                    latex: math, display: display, fallback: source,
                    macros: document.mathDefinitions.preamble(for: math),
                    numbers: numbers)
            )
            return anchor + document.placeholder("M", document.deferredMath.count - 1)
        }
        return anchor
            + document.mathHTML(
                math, display: display, macros: document.mathDefinitions.preamble(for: math), source: source,
                numbers: numbers)
    }

    private func inlineMath(closing: String) {
        let opening = closing == "$" ? "$" : "\\("
        let (latex, original) = mathSource(closing: closing)
        appendInlineFormula(latex, source: opening + original + closing)
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
        // This wrapper binds punctuation to the line. An explicit mbox using
        // the same nowrap style must keep all of its internal material rigid.
        let joined = html.contains(" data-math-glue=\"") ? " data-math-punctuation" : ""
        appendHTML("<span class=\"latex-nowrap\"\(joined)>\(html)\(marks)</span>", last: marks.last)
    }

    private var singleDisplayAttribute: String {
        document.classInfo.profile.body.alignsDisplayRows ? " data-latex-single-display" : ""
    }

    private func displayMath(closing: String) {
        let opening = closing == "$$" ? "$$" : "\\["
        let (latex, original) = mathSource(closing: closing)
        appendBlock(
            "<div class=\"math-block\"\(singleDisplayAttribute)>\(formula(latex, display: true, source: opening + original + closing))</div>\n",
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
                source, display: false, macros: document.mathDefinitions.preamble(for: source), source: source,
                numbers: [])
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
        let source = "\\begin{\(name)}\(body)\\end{\(name)}"
        func fallback() {
            appendBlock(MathRenderer.fallback(source, display: true))
        }
        let budget = ReaderMathBudget()
        guard var latex = expandMathCommands(Self.withoutComments(body), includingCounters: false, budget: budget)
        else {
            fallback()
            return
        }
        // alignat's column count is not part of the formula.
        if base == "alignat", latex.drop(while: \.isWhitespace).first == "{", let close = latex.firstIndex(of: "}") {
            latex = String(latex[latex.index(after: close)...])
        }
        let wrapper = Self.mathEnvironments[base] ?? nil
        func render(_ formula: String, expanded: Bool = false, numbers: [String?] = []) -> String {
            self.formula(
                wrapper.map { $0.0 + formula + $0.1 } ?? formula, display: true, source: source, expanded: expanded,
                numbers: numbers, budget: budget)
        }
        if Self.numberedRows.contains(base) {
            var anchors = ""
            var rows = Self.rows(of: latex)
            var numbers = [String?](repeating: nil, count: rows.count)
            var totalBytes = max(0, rows.count - 1) * 2
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
                guard let resolved = expandMathCommands(row, budget: budget) else {
                    fallback()
                    return
                }
                let (frozen, generatedLabels) = Self.removingLabels(resolved)
                if !generatedLabels.isEmpty {
                    anchors += mathAnchor(generatedLabels, tag: Self.explicitTag(frozen))
                }
                totalBytes += frozen.utf8.count
                if budget.steps > 0, totalBytes > PreviewMathExpansion.maximumBytes {
                    document.mathExpansionLimitReached = true
                    fallback()
                    return
                }
                rows[position] = frozen
            }
            let keepGrid = document.classInfo.profile.body.alignsDisplayRows || numbers.contains { $0 != nil }
            appendBlock(
                "<div class=\"math-block\">\(anchors)\(render(rows.joined(separator: "\\\\"), expanded: true, numbers: keepGrid ? numbers : []))</div>\n"
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
        } else if base == "multline" {
            id = ""
            printed = ""
        } else {
            appendBlock(
                "<div class=\"math-block\"\(singleDisplayAttribute)>\(mathAnchor(labels, tag: nil))\(render(formula))</div>\n"
            )
            return
        }
        if base == "multline" {
            // The rows align to the text measure, which is not known inside one math SVG.
            // amsmath puts this one number on the final line, even if earlier lines are taller.
            let rows = Self.rows(of: clean).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var content = id.isEmpty ? mathAnchor(labels, tag: nil) : ""
            for (index, row) in rows.enumerated() {
                guard document.reserveExpansion() else { break }
                let last = index == rows.count - 1
                let align = rows.count == 1 ? "center" : index == 0 ? "left" : last ? "right" : "center"
                let expression = self.formula(row, display: true, source: row, budget: budget)
                if budget.refused {
                    fallback()
                    return
                }
                let numberClass = rows.count == 1 ? "eqno" : "latex-multline-number"
                let number = last && !printed.isEmpty ? "<span class=\"\(numberClass)\">\(printed)</span>" : ""
                let style = "display: flex; align-items: baseline; justify-content: \(align); column-gap: 1em"
                content += "<div class=\"latex-multline-row\" style=\"\(style)\">\(expression)\(number)</div>"
            }
            let anchor = id.isEmpty ? "" : " id=\"\(id)\""
            // Each row has its own SVG so it can align to the measure. On export the rows belong to one formula.
            let original = Data(source.utf8).base64EncodedString()
            appendBlock(
                "<div class=\"math-block latex-equation latex-multline\"\(anchor) data-formula-group=\"\(original)\">\(content)</div>\n"
            )
            return
        }
        let content = render(clean) + "<span class=\"eqno\">\(printed)</span>"
        appendBlock("<div class=\"math-block latex-equation\" id=\"\(id)\"\(singleDisplayAttribute)>\(content)</div>\n")
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
            document.resolveStylePackage()
            document.classInfo.initialLineParameters = document.lineParameterAttribute
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
            appendListing(verbatimBody(name), settings: settings, environment: true, minted: true)
        case "comment":
            _ = verbatimBody(name)
        default:
            let result = environmentBodyRange(name)
            let body = String(buffer[result.range])
            if Self.unsupportedEnvironments.contains(name), !result.closed {
                appendHTML(picture(environment: name, body: body, closed: false))
            } else {
                environment(name, body: body)
            }
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
        let result = environmentBodyRange(name)
        return String(buffer[result.range])
    }

    private func environmentBodyRange(_ name: String) -> (range: Range<Int>, closed: Bool) {
        let begin = Array("\\begin{\(name)}")
        let end = Array("\\end{\(name)}")
        var depth = 1
        let start = index
        while let character = peek() {
            if character == "\\" || character == "%", let opaque = opaqueEnd() {
                index = max(opaque, index + 1)
                continue
            }
            if character == "\\" {
                if peek(end.count - 1) != nil, buffer[index...].starts(with: end) {
                    depth -= 1
                    if depth == 0 {
                        let body = start..<index
                        index += end.count
                        return (body, true)
                    }
                    index += end.count
                    continue
                }
                if peek(begin.count - 1) != nil, buffer[index...].starts(with: begin) {
                    depth += 1
                    index += begin.count
                    continue
                }
                index += peek(1) == nil ? 1 : 2
                continue
            }
            index += 1
        }
        return (start..<index, false)
    }

    private static let unsupportedEnvironments: Set<String> = [
        "tikzpicture", "pgfpicture", "axis", "semilogxaxis", "semilogyaxis", "loglogaxis", "polaraxis",
        "circuitikz", "forest", "tikzcd", "pspicture", "picture",
    ]

    private func environment(_ name: String, body: String) {
        if let section = societyAbstract(name) {
            readSocietyAbstract(section, body: body)
            return
        }
        if handleExamEnvironment(name, body: body) { return }
        let base = name.hasSuffix("*") ? String(name.dropLast()) : name
        if Self.mathEnvironments.keys.contains(base) || base == "alignat" {
            mathEnvironment(name, body: body)
            return
        }
        if document.classInfo.profile.body.readsFrames, readBeamerEnvironment(base, body: body) { return }
        switch base {
        case "math":
            appendInlineFormula(body, source: "\\begin{math}\(body)\\end{math}")
        case "itemize", "enumerate", "description": appendList(base, body: body)
        case "quote", "quotation":
            let attribute = base == "quotation" ? " class=\"latex-quotation\"" : ""
            appendBlock(
                "<blockquote\(attribute)\(document.contextLineParameterAttribute)>\n\(blocks(body))</blockquote>\n")
        case "verse":
            appendBlock("<blockquote class=\"latex-verse\">\n\(blocks(body))</blockquote>\n")
        case "titlepage":
            let previous = document.insideTitlePage
            document.insideTitlePage = true
            defer { document.insideTitlePage = previous }
            appendBlock("<div class=\"latex-titlepage\">\n\(blocks(body))</div>\n")
        case "letter" where document.classInfo.profile.body.correspondence == .letter:
            readLetter(body)
        case "spacing", "singlespace", "onehalfspace", "doublespace": appendSpacedBlock(base, body: body)
        case "landscape":
            let boundary = "<template data-latex-break=\"clear\"></template>"
            let before = !document.landscapeBody || document.startedLandscape ? boundary : ""
            document.startedLandscape = true
            appendBlock(before + blocks(body) + (document.landscapeBody ? "" : boundary))
        case "center", "flushleft", "flushright":
            appendBlock("<div class=\"latex-\(base)\">\n\(blocks(body))</div>\n")
        case "otherlanguage":
            let reader = LaTeXReader(body, document: document, isBlock: false)
            let language = reader.argument() ?? ""
            appendBlock(localized(reader.rest, language: language, block: true))
        case "icmlauthorlist" where document.classInfo.resolvedStyle?.usesAffiliationList == true:
            _ = blocks(body)
        case "ack" where document.classInfo.resolvedStyle?.acknowledgementHeading != nil:
            if let heading = document.classInfo.resolvedStyle?.acknowledgementHeading, !heading.isEmpty {
                appendBlock("<h2>\(heading)</h2>\n" + blocks(body))
            }
        case "theindex":
            appendBlock("<h2 class=\"latex-index-heading\">\(captionName("indexname"))</h2>\n" + blocks(body))
        case "abstract", "frontmatter", "CCSXML", "IEEEkeywords", "keyword", "keywords":
            readFrontEnvironment(base, body: body)
        case "figure", "table", "SCfigure":
            float(base == "table" ? "table" : "figure", body: body, floats: true, wide: name.hasSuffix("*"))
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
        case "strip":
            appendBlock("<div data-latex-wide>\(blocks(body))</div>\n")
        case "multicols":
            document.hasAuthoredColumns = true
            appendColumns(name, body: body)
        case "tcolorbox", "mdframed", "framed", "shaded":
            let reader = LaTeXReader(body, document: document, isBlock: false)
            let options = reader.optional()
            appendBlock(
                base == "tcolorbox"
                    ? colorPanel(options: options, body: reader.rest) : callout(options: options, body: reader.rest))
        case "subequations": subequations(body)
        case "proof": proof(body)
        case "thebibliography": bibliography(body)
        default:
            if let theorem = document.theorems[name] ?? conventionalTheorem(name) {
                self.theorem(name, theorem, body: body)
            } else if Self.unsupportedEnvironments.contains(base) {
                appendHTML(picture(environment: name, body: body))
            } else {
                document.recordUnknown(name)
                let reader = LaTeXReader(body, document: document, isBlock: true)
                while reader.optional() != nil {}
                appendBlock(reader.read())
            }
        }
    }

    private func appendList(_ base: String, body: String) {
        let reader = LaTeXReader(body, document: document, isBlock: false)
        let options = reader.optionalOnLine()
        document.listStack.append(base)
        defer { document.listStack.removeLast() }
        var settings = document.pageSettings.listOptions(
            base, depth: document.listStack.count,
            kindDepth: document.listStack.filter { $0 == base }.count, options: options)
        let nextLine = settings.removeValue(forKey: "style") == "nextline"
        var html = list(base, options: options, body: reader.rest, nextLine: nextLine)
        let attribute =
            settings.isEmpty ? "" : " style=\"\(HTML.escape(LaTeXPageSettings.cssVariables(settings)))\""
        // Opening a Beamer sublist changes the size before it ends an open paragraph.
        // A blank line or explicit paragraph break has already fixed that paragraph's pitch.
        let closesParagraph =
            document.insideBeamerFrame && document.listStack.count > 1 && base != "description"
            && isBlock && !paragraph.isEmpty
        let attributes =
            attribute + document.contextLineParameterAttribute
            + (closesParagraph ? " data-beamer-closes-paragraph" : "")
        if !attributes.isEmpty, let end = html.firstIndex(of: ">") { html.insert(contentsOf: attributes, at: end) }
        appendBlock(html)
    }

    private func appendSpacedBlock(_ base: String, body: String) {
        let reader = LaTeXReader(body, document: document, isBlock: false)
        var spacing = document.pageSettings
        if base == "spacing" {
            spacing.setStretch(reader.argument() ?? "")
        } else {
            spacing.lineSpacing(
                String(base.dropLast(5)) + "spacing", pointSize: document.classInfo.spacingPointSize)
        }
        appendBlock(
            "<div class=\"latex-leading\" style=\"--latex-stretch: \(spacing.stretch)\">\n\(blocks(reader.rest))</div>\n"
        )
    }

    private func appendColumns(_ name: String, body: String) {
        guard document.reserveExpansion(characters: body.count) else { return }
        let reader = LaTeXReader(body, document: document, isBlock: false)
        let count = Int(reader.argument() ?? "") ?? 1
        let heading = reader.optional()
        _ = reader.optional()
        let intro = heading.map { "<div data-latex-wide>\(blocks($0))</div>\n" } ?? ""
        let columns = max(1, min(count, 2))
        let scope = document.classInfo.columns == 1 ? "page" : "column"
        let attributes = document.columnAttributes(columns) + " data-latex-footnotes=\"\(scope)\""
        let gap = document.pageSettings.columnGap
        let rule = document.pageSettings.columnRule
        defer {
            document.pageSettings.columnGap = gap
            document.pageSettings.columnRule = rule
        }
        appendBlock(
            intro
                + "<div \(attributes) data-latex-balance=\"\(!name.hasSuffix("*"))\">\(blocks(reader.rest))</div>\n"
        )
    }

    // MARK: - Lists

    private func list(_ kind: String, options: String?, body: String, nextLine: Bool) -> String {
        var prefix = ""
        let items = items(of: body) { prefix = $0 }
        func cover(_ content: String) -> String {
            document.insideBeamerFrame && content.drop(while: \.isWhitespace).hasPrefix(#"\surimonocovereditem{}"#)
                ? " data-beamer-covered" : ""
        }
        switch kind {
        case "itemize":
            let html = items.map { label, content -> String in
                let text = compact(blocks(content))
                if let label {
                    return "<li\(cover(content)) class=\"latex-custom-label\">\(labeled(inline(label), text))</li>\n"
                }
                // A real label stays in reading order and belongs only to the slice with its first baseline.
                let depth = document.listStack.filter { $0 == "itemize" }.count
                let bullet = document.insideBeamerFrame ? "▶" : ["•", "–", "∗", "·"][min(max(depth - 1, 0), 3)]
                let face =
                    depth == 1 && document.classInfo.profile.body.usesLatinModernBullet ? " data-latex-lm-bullet" : ""
                let mark = "<span class=\"latex-item-mark\"\(face)>\(bullet)</span>"
                let item = text.hasPrefix("<p>") ? "<p>" + mark + text.dropFirst(3) : mark + text
                return "<li\(cover(content))>\(item)</li>\n"
            }
            return "<ul>\n\(html.joined())</ul>\n"
        case "description":
            let html = items.map { label, content in
                // A term and its definition share the first line in class styles. Leave their gap to CSS.
                "<div\(cover(content))><dt>\(inline(label ?? ""))</dt><dd>\(compact(blocks(content)))</dd></div>\n"
            }
            let style = nextLine ? " latex-nextline" : ""
            return "<dl class=\"latex-description\(style)\">\n\(html.joined())</dl>\n"
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
                let marker: String
                if let label {
                    marker = inline(label)
                } else if document.insideBeamerFrame && options == nil {
                    marker =
                        LaTeXCounters.listLevels.prefix(document.enumerateDepth)
                        .map { String(document.counters[$0]) }.joined(separator: ".")
                        + (document.enumerateDepth == 1 ? "." : "")
                } else {
                    marker = inline(template.replacingOccurrences(of: "\u{E000}", with: number))
                }
                return "<li id=\"\(id)\"\(cover(content))>\(labeled(marker, compact(blocks(content))))</li>\n"
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
        let depth = min(max(document.enumerateDepth - 1, 0), 3)
        var (template, style) = defaults[depth]
        switch document.classInfo.profile.body.enumLabels {
        case .parentheses: template = "(\u{E000})"
        case .wideParentheses where depth < 2: template = "（\u{E000}）"
        case .periods: template = "\u{E000}."
        default: break
        }
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
    private func items(of body: String, command: String = "item", prefix: ((String) -> Void)? = nil)
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
            // Label scanning consumes only the child cursor and preserves the parent document state.
            let reader = LaTeXReader(content, document: document, isBlock: false)
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
        let noteHTML = note.map { document.isJapanese ? "（\($0)）" : " (\($0))" } ?? ""
        if document.insideBeamerFrame {
            let kind = theorem.style == "example" ? "example" : "theorem"
            let content = blocks(reader.rest)
            beamerBlock(kind, title: head + noteHTML, content: content, anchor: anchor)
            return
        }
        head += numberHTML
        head =
            document.usesAMSTheorem || document.classInfo.profile.body.proceedingsTheoremStyle
            ? head + (noteHTML.isEmpty ? "" : "<span class=\"theorem-note\">\(noteHTML)</span>") + "."
            : head + noteHTML
        let style = theorem.style == "plain" && document.isJapanese ? "definition" : theorem.style
        let content = blocks(reader.rest)
        appendBlock(
            "<div class=\"latex-theorem latex-theorem-\(style)\"\(anchor)\(document.contextLineParameterAttribute)>\n"
                + leading("<span class=\"theorem-head\">\(head)</span> ", content) + "</div>\n")
    }

    /// amsthm's proof: its heading in italics and the end-of-proof box at the right of the last line.
    private func proof(_ body: String) {
        let reader = LaTeXReader(body, document: document, isBlock: false)
        // A redefined `\proofname` is read as a macro, within the limits on expansion.
        let title =
            reader.optionalOnLine().map { inline($0) }
            ?? captionName("proofname")
        var content = blocks(reader.rest).trimmingCharacters(in: .whitespacesAndNewlines)
        let box =
            document.classInfo.profile.body.proceedingsTheoremStyle
            ? #"<span class="qed latex-qed-square" role="img" aria-label="□"></span>"# : #"<span class="qed">□</span>"#
        if content.hasSuffix("</p>") {
            content = content.dropLast(4) + box + "</p>"
        } else {
            content += "\n<p class=\"qed-line\">\(box)</p>"
        }
        if document.insideBeamerFrame {
            beamerBlock("proof", title: title + (title.hasSuffix(".") ? "" : "."), content: content)
            return
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
        let widest = reader.rest.drop(while: \.isWhitespace).first == "{" ? reader.argument() : nil
        let nameMacro = document.hasChapters ? "bibname" : "refname"
        let heading = captionName(nameMacro)
        document.bibliographyCount += 1
        let headingID = "bibliography-\(document.bibliographyCount)"
        var headingHTML = ""
        if document.classInfo.profile.headings.bibliography != .none {
            document.headings.append(
                .init(
                    level: document.hasChapters ? 0 : 1,
                    number: document.classInfo.profile.headings.bibliography == .chapter ? "" : nil,
                    id: headingID, title: heading))
            headingHTML = bibliographyHeading(heading, id: headingID)
        }
        var entries = ""
        var number = 0
        let initialMarker = document.insideBeamerFrame ? document.beamer.bibliographyMarker : nil
        defer { if let initialMarker { document.beamer.bibliographyMarker = initialMarker } }
        // Beamer measures the list gutter once, even when later entries change their marker.
        let sample = initialMarker == .text ? inline(widest ?? "") : nil
        let items = items(of: reader.rest, command: "bibitem") { prefix in
            if initialMarker != nil { _ = self.blocks(prefix) }
        }
        let labels = items.map { $0.label.flatMap(LaTeXBibliography.ManualLabel.init) }
        let database = document.bibDatabase
        database.hasManualBibliography = true
        if database.natbib && labels.contains(where: { $0 == nil }) { database.authorYearOption = false }
        let authorYear = database.natbib && database.authorYear
        let previousEntry = document.readsBibliographyEntry
        document.readsBibliographyEntry = true
        defer { document.readsBibliographyEntry = previousEntry }
        for (position, item) in items.enumerated() {
            let itemReader = LaTeXReader(item.content, document: document, isBlock: false)
            let key = itemReader.argument()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // As in LaTeX, an entry with its own label does not advance the numbers.
            let label: String
            if let parsed = labels[position] {
                let author = inline(parsed.author)
                let year = inline(parsed.year)
                if database.natbib {
                    database.citationLabels[key] = (author, year)
                    database.fullAuthors[key] = parsed.fullAuthor == parsed.author ? author : inline(parsed.fullAuthor)
                }
                number += 1
                label = authorYear ? author + database.authorYearSeparator + year : String(position + 1)
            } else if database.natbib {
                label = String(position + 1)
            } else if let own = item.label {
                label = inline(own)
            } else {
                number += 1
                label = String(number)
            }
            let id = "bib-\(document.bibliographyCount)-\(position + 1)"
            if !key.isEmpty { document.bibliography[key] = (label, id) }
            let entryMarker = document.insideBeamerFrame ? document.beamer.bibliographyMarker : nil
            var text: String
            if document.insideBeamerFrame && itemReader.rest.contains("\\newblock") {
                let fields = LaTeXLexer.split(itemReader.rest, at: ["\\newblock"], protectingEnvironments: true)
                text = fields.enumerated().map { index, field in
                    let content = compact(blocks(field))
                    guard index > 0 else { return content }
                    let role = index == 1 ? "title" : index == 2 ? "location" : "note"
                    return "<div class=\"beamer-bib-\(role)\">\(content)</div>"
                }.joined()
            } else {
                text = compact(blocks(itemReader.rest))
            }
            if document.language == "ja", document.classInfo.profile.body.usesJapanesePunctuationMetrics,
                text.contains("』。")
            {
                // JFM gives adjacent closing punctuation a half-width advance.
                text = HTMLScanner.tokens(text).map { token in
                    switch token {
                    case .text(let value):
                        value.replacingOccurrences(of: "』。", with: "<span class=\"latex-jfm-close\">』</span>。")
                    case .tag(let tag): tag.source
                    case .opaque(let source): source
                    }
                }.joined()
            }
            let printed = document.classInfo.journalStyle?.bibliographyLabel(label) ?? "[\(label)]"
            let marker: String
            switch entryMarker {
            case .article, .book:
                let icon = entryMarker == .book ? "beamer-book" : "beamer-article"
                marker = "<span class=\"beamer-bib-icon \(icon)\" aria-hidden=\"true\"></span>"
            case .triangle: marker = "<span class=\"beamer-bib-arrow\">▶</span>"
            case .text where sample == nil: marker = "<span class=\"beamer-bib-alt-label\">\(printed)</span>"
            case .text: marker = ""
            case nil: marker = authorYear ? "" : "<span class=\"bib-label\">\(printed)</span>"
            }
            let content = text.hasPrefix("<p>") ? "<p>" + marker + text.dropFirst(3) : marker + text
            let blockAttribute = document.opensBibliographyBlocks ? " data-latex-openbib" : ""
            if let sample {
                let label = entryMarker == .text ? printed : ""
                let gutter =
                    "<span class=\"beamer-bib-label\"><span aria-hidden=\"true\">[\(sample)]</span><span>\(label)</span></span>"
                entries += "<li id=\"\(id)\">\(gutter)<div>\(content)</div></li>\n"
            } else {
                entries += "<li id=\"\(id)\"\(blockAttribute)>\(content)</li>\n"
            }
        }
        let list: String
        if let initialMarker {
            list = "<ol class=\"latex-bibliography beamer-bibliography beamer-biblist-\(initialMarker.rawValue)\">"
        } else if authorYear {
            list = "<ol class=\"latex-bibliography latex-author-year\">"
        } else if database.natbib, document.composesEnglishParagraphs, let widest, !widest.isEmpty,
            widest.utf8.allSatisfy({ (48...57).contains($0) })
        {
            list = "<ol class=\"latex-bibliography\" data-latex-bib-sample=\"[\(widest)]\">"
        } else if document.language == "ja", document.classInfo.profile.body.usesJapanesePunctuationMetrics,
            let widest, !widest.isEmpty, widest.utf8.allSatisfy({ (48...57).contains($0) })
        {
            list = "<ol class=\"latex-bibliography latex-numbered\" style=\"--latex-label-digits: \(widest.count)ch\">"
        } else {
            list = "<ol class=\"latex-bibliography\">"
        }
        var opening = list
        if database.natbib, let size = declarations.last(where: { $0.size != nil })?.size,
            let pitch = LaTeXLabelMetrics(document.classInfo).baseline(for: size)
        {
            opening =
                String(list.dropLast())
                + " style=\"font-size: var(--latex-size-\(size)); line-height: calc(\(LaTeXPageSettings.number(pitch)) * var(--tex-pt))\">"
        }
        opening.insert(contentsOf: document.contextLineParameterAttribute, at: opening.index(before: opening.endIndex))
        appendBlock(headingHTML + opening + "\n\(entries)</ol>\n")
    }

    /// `\cite[after]{keys}` and natbib's `\citep[before][after]{keys}`. The numbers are filled in at the end, as
    /// the bibliography usually comes last.
    private func cite(_ command: String) {
        let full = star()
        let first = optional()
        let second = optional()
        let keys = (argument() ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let (before, after) = second == nil ? (nil, first) : (first, second)
        let citation = document.citation(
            .init(
                command: command, full: full, keys: keys, before: before.map { inline($0) },
                after: after.map { inline($0) }))
        appendHTML(styledLinks(citation))
    }

    // MARK: - Floats, images and tables

    private func float(_ kind: String, body: String, floats: Bool = false, wide: Bool = false) {
        let reader = LaTeXReader(body, document: document, isBlock: true)
        let spec = reader.optionalOnLine()?.filter { "htbp!H".contains($0) }
        reader.floatKind = kind
        let outerPictures = document.pictureCaptions
        let captions = LaTeXPictureCaptions()
        document.pictureCaptions = captions
        defer { document.pictureCaptions = outerPictures }
        let previous = document.figureCaptions
        if kind == "figure" { document.figureCaptions = LaTeXFigureCaptions() }
        defer { document.figureCaptions = previous }
        let inside = reader.read()
        captions.assign(captions.last, in: document)
        let placement = document.insideBeamerFrame ? "H" : spec.flatMap { $0.isEmpty ? nil : $0 } ?? "tbp"
        var attributes = floats ? " data-latex-float=\"\(kind)\" data-latex-placement=\"\(placement)\"" : ""
        if let size = document.classInfo.profile.page.fixedGrid?.floatSize {
            attributes += " data-latex-float-size=\"\(size.rawValue)\""
        }
        appendBlock(
            "<figure class=\"latex-\(kind)\"\(attributes)\(wide && !document.insideBeamerFrame ? " data-latex-wide" : "")>\n\(inside)</figure>\n"
        )
    }

    private func caption(sub: Bool = false) {
        let unnumbered = star()
        let short = optional()
        let source = argument() ?? ""
        let info = document.classInfo
        let kind = floatKind ?? "figure"
        let setup = document.pageSettings.captions.resolve(kind, info: info)
        let koma = info.bookStyle.fontAttribute(elements: ["caption", "captionlabel"], size: info.pointSize)
        // Both packages can set font variables; a tag accepts just one style attribute.
        let font: String
        if !koma.isEmpty, let split = setup.attributes.range(of: " style=\"") {
            font =
                String(setup.attributes[..<split.lowerBound]) + koma.dropLast() + "; "
                + setup.attributes[split.upperBound...]
        } else {
            font = koma + setup.attributes
        }
        if unnumbered {
            document.pictureCaptions?.assign(nil, in: document)
            appendBlock("<figcaption\(font)\(document.contextLineParameterAttribute)>\(inline(source))</figcaption>\n")
            return
        }
        if sub || document.insideSubfigure {
            let target = subfigureTarget()
            appendBlock(subcaptionHTML(source, target: target))
            return
        }
        let number: String
        if kind == "figure", let figure = document.figureCaptions {
            number = figure.mainCaptionPrinted ? stepCounter(kind) : figure.number ?? stepCounter(kind)
            if figure.mainCaptionPrinted { figure.children = 0 }
            figure.number = number
            figure.mainCaptionPrinted = true
        } else {
            number = longtableCaption?.number ?? stepCounter(kind)
            longtableCaption?.number = number
        }
        let prefix: String
        let name: String
        switch kind {
        case "table": (prefix, name) = ("tab", captionName("tablename"))
        case "listing": (prefix, name) = ("listing", captionName("lstlistingname"))
        default: (prefix, name) = ("fig", captionName("figurename"))
        }
        document.pictureCaptions?.assign(
            LaTeXPictureCaptions.heading(DocumentOutline.plainText(ofHTML: name), number), in: document)
        let id = document.counters.anchor(prefix, suffix: number)
        document.labelTarget = (number, id)
        let text = inline(source)
        document.describeTarget(id, kind: kind, title: text)
        if kind == "figure" || kind == "table", short != "" {
            let title = short.map(inline) ?? text
            let plain = title.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            document.lists[kind, default: []].append(
                .init(
                    chapter: info.profile.structure.contents == .chapterMarks ? document.counters["chapter"] : nil,
                    level: 1, number: number, id: id, title: plain))
        }
        let numbered = document.classInfo.profile.body.numbersCaptions || document.numberedBeamerCaptions
        // jsclasses joins the Japanese name and the Western counter with JFM glue (\nobreak).
        let japaneseBoundary =
            info.profile.usesGridFlow && document.language == "ja" && (kind == "figure" || kind == "table")
            && name.last.map { LaTeXSymbols.isCJK($0) } == true
        let numberGap = japaneseBoundary ? #"<span class="latex-xkanjiskip"> </span>"# : " "
        let label = numbered ? name + numberGap + HTML.escape(number) + document.headingEndDot : name
        let separator =
            setup.separator ?? info.resolvedStyle?.captionSeparator ?? document.classInfo.journalStyle?
            .captionSeparator(for: kind)
            ?? info.profile.body.captionSeparator
            ?? (longtableCaption != nil ? ": " : document.isJapanese ? "　" : document.language == "fr" ? " – " : ": ")
        let contents: String
        let hangs = setup.hangs || info.profile.body.hangsPlainCaptions && setup.attributes.isEmpty
        if hangs {
            // A manual break centres the individual lines. Keep the separator space when the grid becomes inline.
            let space: String
            if info.profile.body.alignsHangingCaptions, separator == ": ", text.contains("<br>") {
                space = #"<span class="latex-caption-colon-space">&nbsp;</span>"#
            } else {
                space = "&nbsp;"
            }
            let separator =
                text.contains("<br>") && separator.hasSuffix(" ") ? String(separator.dropLast()) + space : separator
            contents =
                "<span class=\"latex-caption-label\">\(label)\(separator)</span><span>\(shortHeadingBox(text))</span>"
        } else if document.insideBeamerFrame, separator == ": " {
            contents = "<span class=\"latex-caption-label\">\(label):</span> \(text)"
        } else if info.resolvedStyle?.captionSeparator != nil, separator == ". " {
            // The period belongs to the caption label and takes its font.
            contents = "<span class=\"latex-caption-label\">\(label).</span> \(text)"
        } else {
            contents = "<span class=\"latex-caption-label\">\(label)</span>\(separator)\(text)"
        }
        let hang = hangs ? " data-latex-caption-hang" : ""
        appendBlock(
            "<figcaption id=\"\(id)\"\(font)\(hang)\(document.contextLineParameterAttribute)>\(contents)</figcaption>\n"
        )
    }

    private func image() -> String {
        let clipped = star()
        let options = optional()
        let file = argument()?.trimmingCharacters(in: .whitespaces) ?? ""
        let (source, url) = document.imageSource(file)
        let keys = LaTeXPageSettings.options(options ?? "")
        if clipped || keys.contains(where: { $0.key == "clip" && $0.value != "false" }),
            let trim = keys.last(where: { $0.key == "trim" })?.value,
            let crop = Self.cropPoints(trim)
        {
            let ratio = keys.contains { $0.key == "keepaspectratio" && $0.value != "false" }
            let angle = option("angle", in: options).flatMap(Double.init) ?? 0
            let scale = option("scale", in: options).flatMap(Double.init) ?? 1
            let width = option("width", in: options).flatMap(LaTeXSymbols.printLength)
            let height = option("height", in: options).flatMap(LaTeXSymbols.printLength)
            let image = "<img class=\"latex-graphic\" src=\"\(HTML.escape(source))\" alt=\"\">"
            var attributes = " data-latex-crop=\"\(crop)\" data-keep-ratio=\"\(ratio)\""
            if let size = url.flatMap(document.imageSizeInPoints),
                size.width.isFinite, size.width > 0, size.height.isFinite, size.height > 0
            {
                let dimensions = [size.width, size.height].map(LaTeXPageSettings.number).joined(separator: " ")
                attributes += " data-latex-intrinsic=\"\(dimensions)\""
            }
            return Self.graphicBox(
                image, block: false, width: width, height: height, x: scale, y: scale,
                angle: -angle, attributes: attributes)
        }
        var style: [String] = []
        if let width = option("width", in: options).flatMap(LaTeXSymbols.printLength) {
            style.append("width: \(width)")
        }
        if let height = option("height", in: options).flatMap(LaTeXSymbols.printLength) {
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
        let attributes = style.isEmpty ? "" : " style=\"\(style.joined(separator: "; "))\""
        return "<img class=\"latex-graphic\" src=\"\(HTML.escape(source))\" alt=\"\"\(attributes)>"
    }

    private static func cropPoints(_ raw: String) -> String? {
        let edges = raw.split(whereSeparator: \.isWhitespace)
        guard edges.count == 4 else { return nil }
        let points = edges.compactMap { token -> Double? in
            if let number = Double(token), number.isFinite, abs(number) < 1_000_000 { return number }
            return LaTeXPageSettings.millimetres(String(token)).map { $0 * 72 / 25.4 }
        }
        return points.count == 4 ? points.map(LaTeXPageSettings.number).joined(separator: " ") : nil
    }

    private func scaledBox(_ name: String) {
        _ = star()
        let first = argument() ?? ""
        var width: String?
        var height: String?
        var x = 1.0
        var y = 1.0
        if name == "resizebox" {
            width = LaTeXSymbols.printLength(first)
            height = argument().flatMap(LaTeXSymbols.printLength)
        } else {
            x = Double(first) ?? 1
            y = optional().flatMap(Double.init) ?? x
        }
        let source = argument() ?? ""
        let body = blocks(source)
        let content = compact(body)
        let block = !body.isEmpty && content == body.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = Self.graphicBox(content, block: block, width: width, height: height, x: x, y: y)
        if block { appendBlock(html + "\n") } else { appendHTML(html) }
    }

    private static func graphicBox(
        _ content: String, block: Bool, width: String?, height: String?, x: Double, y: Double,
        angle: Double = 0, attributes: String = ""
    ) -> String {
        guard x.isFinite, y.isFinite, angle.isFinite else { return content }
        let tag = block ? "div" : "span"
        let style = [width.map { "--latex-target-width: \($0)" }, height.map { "--latex-target-height: \($0)" }]
            .compactMap { $0 }.joined(separator: "; ")
        let transform = [x, y, angle].map(LaTeXPageSettings.number).joined(separator: " ")
        return "<\(tag) class=\"latex-graphic-box\" data-latex-transform=\"\(transform)\""
            + "\(attributes) style=\"\(style)\">"
            + "<\(tag) class=\"latex-graphic-content\">\(content)</\(tag)></\(tag)>"
    }

    private func tabular(_ name: String, body: String) -> String {
        let reader = LaTeXReader(body, document: document, isBlock: false)
        var alignment = name == "xltabular" ? reader.optional() : nil
        var targetWidth: String?
        if ["tabular*", "tabularx", "tabulary", "xltabular", "supertabular*", "tabu"].contains(name) {
            let width = reader.argument()
            if name == "tabularx" || name == "xltabular" { targetWidth = width.flatMap(LaTeXSymbols.printLength) }
        }
        if let position = reader.optional() { alignment = position }
        let spec = reader.argument() ?? ""
        let rest = reader.rest
        let isLong = ["longtable", "xltabular", "supertabular", "supertabular*"].contains(name)
        guard document.reserveExpansion(characters: rest.count) else { return "" }
        reader.longtableCaption = isLong ? LongtableCaption() : nil
        reader.floatKind = isLong ? "table" : floatKind
        let stretch = document.macros["arraystretch"].flatMap {
            $0.specification.isEmpty ? Double($0.body.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        }
        var registers = document.pageSettings.tableSpacing
        if document.classInfo.profile.body.usesScaledTableMetrics, registers["tabcolsep"] == nil {
            registers["tabcolsep"] = "calc(6 * var(--js-pt))"
        }
        if isLong, let alignment, ["l", "r", "c"].contains(alignment) {
            registers["ltleft"] = alignment == "l" ? "0px" : "auto"
            registers["ltright"] = alignment == "r" ? "0px" : "auto"
        }
        return LaTeXTable(
            spec: spec, body: rest,
            basicBidi: document.basicBidiTables && DocumentLanguage(code: document.language).isRightToLeft,
            isLongtable: isLong, usesMeasuredRules: document.classInfo.usesPublicationGrid, targetWidth: targetWidth,
            columnTypes: document.pageSettings.columnTypes,
            spacing: registers, arrayStretch: stretch, extraRowHeight: document.pageSettings.extraRowHeight,
            japaneseSize: document.classInfo.profile.body.usesScaledTableMetrics
                ? declarations.last(where: { $0.size != nil })?.size : nil,
            japaneseMetrics: document.classInfo.profile.body.usesScaledTableMetrics
                ? LaTeXLabelMetrics(document.classInfo) : nil
        ).html(
            japanesePunctuation: document.language == "ja"
                && document.classInfo.profile.body.usesJapanesePunctuationMetrics,
            color: { LaTeXSymbols.cssColor($0, model: $1, defined: document.colors) },
            inline: reader.inline)
    }
}

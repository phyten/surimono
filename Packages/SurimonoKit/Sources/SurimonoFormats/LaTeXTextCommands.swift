import Foundation

extension LaTeXDocument {
    /// Keep the printed number separate from the link ID because explicit numbers can repeat.
    struct Footnote {
        let id: String
        let number: String
        // nil means the mark still awaits its text. An explicitly empty note is already paired.
        var html: String?
    }

    /// Pair \footnotetext with the oldest unfilled mark, restricting the search to that number when one is given.
    func pendingFootnote(_ explicit: String?) -> Int? {
        if let explicit {
            while let index = pendingByNumber[explicit]?.popFirst() {
                if footnotes[index].html == nil { return index }
            }
            return nil
        }
        while nextPendingNote < footnotes.count {
            let index = nextPendingNote
            nextPendingNote += 1
            if footnotes[index].html == nil { return index }
        }
        return nil
    }

    /// Keep the printed number on the list item as well as its anchor. The class styles can lift this
    /// exact mark into a superscript, including jumps, resets, and symbolic title acknowledgements.
    func footnoteSection() -> String {
        guard !footnotes.isEmpty else { return "" }
        let items = footnotes.map { note in
            let value = Int(note.number)
            let attribute = value.map { " value=\"\($0)\"" } ?? " style=\"list-style:none\""
            var content = note.html ?? ""
            if value == nil && !note.number.isEmpty {
                // A superscript before a block paragraph takes a line of its own. Put the mark on the
                // first text baseline, including when the note starts with an explicitly unindented paragraph.
                let mark = "<sup class=\"latex-symbolic-note\">\(HTML.escape(note.number))</sup>"
                if content.hasPrefix("<p>") || content.hasPrefix("<p "), let tagEnd = content.firstIndex(of: ">") {
                    content.insert(contentsOf: mark, at: content.index(after: tagEnd))
                } else {
                    content = mark + content
                }
            }
            return "<li id=\"\(note.id)\"\(attribute)>\(content)</li>\n"
        }.joined()
        return "<section class=\"footnotes\">\n<ol>\n\(items)</ol>\n</section>\n"
    }
}

extension LaTeXReader {
    /// Recover readable words from an unsupported command without printing its layout options.
    func readUnknownArguments() {
        _ = star()
        // Keep prose in mandatory arguments. Options are instructions to the unknown command.
        while true {
            if optional() != nil { continue }
            let before = index
            skipSpaces()
            guard peek() == "{" else {
                index = before
                return
            }
            let group = index
            if !inPreamble {
                index = before
                while index < group, let character = peek() { step(character) }
            }
            let source = argument() ?? ""
            if !inPreamble { appendHTML(inline(source)) }
        }
    }

    /// Apply emphasis and case while reading the argument so nested formatting keeps its scope and HTML stays intact.
    func handleText(_ name: String) -> Bool {
        switch name {
        case "emph":
            document.emphasisDepth += 1
            defer { document.emphasisDepth -= 1 }
            let text = inline(argument() ?? "")
            appendHTML(
                document.emphasisDepth.isMultiple(of: 2)
                    ? "<span style=\"font-style:normal\">\(text)</span>" : "<em>\(text)</em>")
        case "sethlcolor": document.highlightColor = color()
        case "hl":
            let style = document.highlightColor.map { " style=\"background-color:\($0)\"" } ?? ""
            appendHTML("<mark\(style)>\(inline(argument() ?? ""))</mark>")
        case "MakeUppercase", "MakeLowercase", "uppercase", "lowercase":
            let previous = document.uppercase
            document.uppercase = name.lowercased().contains("upper")
            defer { document.uppercase = previous }
            appendHTML(inline(argument() ?? ""))
        case "footnote", "thanks", "footnotemark", "footnotetext": note(name)
        case "endgraf": paragraphBreak()
        case "ensuremath":
            let source = argument() ?? ""
            appendInlineFormula(source, source: source)
        case "texorpdfstring":
            let tex = argument() ?? ""
            _ = argument()
            appendHTML(inline(tex))
        default: return false
        }
        return true
    }

    /// A combined note and a separate mark reserve their destinations in the same sequence.
    private func note(_ command: String) {
        let explicit = optional().flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.map(String.init)
        let text = command == "footnotemark" ? nil : argument() ?? ""
        let slot: Int
        if command == "footnotetext", let pending = document.pendingFootnote(explicit) {
            slot = pending
        } else {
            // Reserve the number before reading the note's own text so a note inside it numbers after the outer one.
            let number: String
            if command == "thanks" && document.makingTitle {
                // Title acknowledgements have their own symbolic series, independent of body footnotes.
                document.titleNoteCount += 1
                number = LaTeXSymbols.format(document.titleNoteCount, as: "fnsymbol")
            } else {
                number = explicit ?? stepCounter("footnote")
            }
            slot = document.footnotes.count
            let candidate = Int(number).map { "fn-\($0)" } ?? "fn-symbol-\(slot + 1)"
            let id = document.usedNoteIDs.insert(candidate).inserted ? candidate : "fn-repeat-\(slot + 1)"
            document.footnotes.append(.init(id: id, number: number, html: nil))
            if command == "footnotemark" { document.pendingByNumber[number, default: []].append(slot) }
        }
        let number = document.footnotes[slot].number
        let id = document.footnotes[slot].id
        document.labelTarget = (number, id)
        document.describeTarget(id, kind: "footnote", title: "")
        if let text {
            // Reserve the slot before reading the note so nested notes get their own destinations.
            document.footnotes[slot].html = ""
            let html = blocks(text)
            document.footnotes[slot].html = html
        }
        if command != "footnotetext" {
            let marker = "fnref-" + id.dropFirst(3)
            appendHTML(
                styledLinks(
                    "<sup class=\"footnote-ref\"><a href=\"#\(id)\" id=\"\(marker)\">\(HTML.escape(number))</a></sup>"))
        }
    }
}

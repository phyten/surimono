import Foundation

public struct BeamerSection: Sendable, Equatable {
    public let id: String
    public let title: String
    public let level: Int
    public let firstFrame: Int
}

struct BeamerDocumentState {
    enum BibliographyMarker: String { case article, book, text, triangle }
    var bibliographyMarker = BibliographyMarker.article

    struct Entry {
        let title, id: String
        let level, section: Int
        let appendix: Bool
    }

    var entries: [Entry] = []
    var contentsRequests: [(section: Int, current: Bool, hideSubs: Bool, appendix: Bool)] = []
    var section = 0
    var frame = 0
    var numberedFrame = 0
    var sectionHook = ""
    var titleGraphic = ""
    var title = ""
    var subtitle = ""
    var pendingAnchors = ""
    var runningHook = false

    func contents(_ index: Int) -> String {
        guard contentsRequests.indices.contains(index) else { return "" }
        let request = contentsRequests[index]
        var rows = ""
        for entry in entries where entry.appendix == request.appendix && (entry.level == 1 || !request.hideSubs) {
            let kind = entry.level == 1 ? "section" : "subsection"
            let shade = request.current && entry.section != request.section ? " data-shaded" : ""
            rows += "<div class=\"beamer-toc-\(kind)\"\(shade)><a href=\"#\(entry.id)\">\(entry.title)</a></div>\n"
        }
        return "<nav class=\"beamer-toc\">\n" + rows + "</nav>\n"
    }
}

extension LaTeXReader {
    func handleBeamerCommand(_ name: String) -> Bool {
        guard document.classInfo.profile.body.readsFrames else { return false }
        switch name {
        case "usetheme", "usecolortheme", "usefonttheme", "useinnertheme", "useoutertheme":
            let options = optional() ?? ""
            for theme in (argument() ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if name == "usefonttheme", theme == "serif" || theme == "professionalfonts" {
                    document.classInfo.beamerUsesSerifMath = true
                    if theme == "serif", !options.contains("onlymath") { document.classInfo.beamerUsesSerifText = true }
                } else if theme != "default", !theme.isEmpty, document.classInfo.unsupportedBeamerTheme == nil {
                    document.classInfo.unsupportedBeamerTheme = theme
                }
            }
        case "setbeamercolor", "setbeamerfont":
            _ = star()
            _ = argument()
            _ = argument()
        case "beamertemplatearticlebibitems": document.beamer.bibliographyMarker = .article
        case "beamertemplatebookbibitems": document.beamer.bibliographyMarker = .book
        case "beamertemplatetextbibitems": document.beamer.bibliographyMarker = .text
        case "beamertemplatearrowbibitems": document.beamer.bibliographyMarker = .triangle
        case "setbeamertemplate":
            let template = argument()
            let choice = optional()
            if choice == nil { _ = argument() }
            if template == "bibliography item", let choice {
                if choice == "default" {
                    document.beamer.bibliographyMarker = .article
                } else if let marker = BeamerDocumentState.BibliographyMarker(rawValue: choice) {
                    document.beamer.bibliographyMarker = marker
                }
            }
            if template == "caption", choice == "numbered" || choice == "default" {
                document.numberedBeamerCaptions = choice == "numbered"
            }
        case "AtBeginSection":
            _ = optional()
            document.beamer.sectionHook = argument() ?? ""
        case "titlegraphic": document.beamer.titleGraphic = argument() ?? ""
        case "mode":
            let mode = overlaySpec() ?? ""
            let active = BeamerMode(rawValue: mode)?.active(handout: document.classInfo.profile.page.handout) == true
            skipSpaces()
            if peek() == "{" {
                let body = argument() ?? ""
                if active {
                    if inPreamble {
                        LaTeXReader(body, document: document, isBlock: false).readPreamble()
                    } else {
                        appendBlock(blocks(body))
                    }
                }
            } else {
                // A declaration governs the following input up to the next mode command.
                if !active {
                    while index < characters.count {
                        if let end = LaTeXLexer.opaqueEnd(characters, at: index) {
                            index = end
                            continue
                        }
                        if peek() == "\\", let word = LaTeXLexer.word(characters, at: index + 1),
                            ["mode", "end"].contains(word)
                        {
                            if word == "mode" || characters[index...].starts(with: "\\end{document}") { break }
                        }
                        index += 1
                    }
                }
            }
        case "frame":
            let options = readFrameOptions()
            let body = argument() ?? ""
            readBeamerFrame(body, options: options)
        case "titlepage", "maketitle":
            if !document.insideBeamerFrame {
                readBeamerFrame("\\titlepage", options: FrameOptions())
            } else {
                beamerTitlePage()
            }
        case "frametitle", "framesubtitle":
            _ = overlaySpec()
            _ = optional()
            let text = inline(argument() ?? "")
            if name == "frametitle" { document.beamer.title = text } else { document.beamer.subtitle = text }
        case "appendix": document.isAppendix = true
        case "sectionpage", "subsectionpage":
            let level = name == "sectionpage" ? 1 : 2
            if let entry = document.beamer.entries.last(where: { $0.level == level }) {
                let label = level == 1 ? "Section" : "Subsection"
                let counter = level == 1 ? "section" : "subsection"
                appendBlock(
                    "<div class=\"beamer-sectionpage\"><p>\(label) \(document.counters[counter])</p><h2>\(entry.title)</h2></div>\n"
                )
            }
        case "tableofcontents":
            let options = optional()?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            let index = document.beamer.contentsRequests.count
            document.beamer.contentsRequests.append(
                (
                    document.beamer.section, options.contains("currentsection"), options.contains("hideallsubsections"),
                    document.isAppendix
                ))
            appendBlock(document.placeholder("BT", index))
        case "insertframenumber": appendHTML(String(document.beamer.numberedFrame))
        case "inserttotalframenumber": appendHTML(document.placeholder("BF", 0))
        case "insertsection", "insertsubsection", "insertsectionhead", "insertsubsectionhead":
            let level = name.contains("subsection") ? 2 : 1
            appendHTML(document.beamer.entries.last(where: { $0.level == level })?.title ?? "")
        case "framebreak" where document.insideBeamerFrame, "newpage" where document.insideBeamerFrame:
            appendBlock("<div class=\"beamer-break\"></div>")
        case "alert", "structure":
            appendHTML("<span class=\"beamer-\(name)\">\(inline(argument() ?? ""))</span>")
        case "surimonocovereditem": _ = argument()
        case "surimonocovered":
            let body = argument() ?? ""
            if isBlock && (body.contains("\\begin{") || body.contains("\\par") || body.contains("\n\n")) {
                appendBlock("<div style=\"visibility:hidden\">\(blocks(body))</div>")
            } else {
                appendHTML("<span style=\"visibility:hidden\">\(inline(body))</span>")
            }
        case "note", "againframe":
            _ = overlaySpec()
            _ = optional()
            _ = argument()
        case "includemedia":
            _ = optional()
            appendHTML(inline(argument() ?? ""))
            _ = argument()
        case "animategraphics":
            _ = optional()
            for _ in 0..<4 { _ = argument() }
        case "beamerbutton", "beamergotobutton", "beamerskipbutton", "beamerreturnbutton":
            appendHTML(inline(argument() ?? ""))
        case "hyperlink":
            _ = argument()
            appendHTML(inline(argument() ?? ""))
        default: return false
        }
        return true
    }

    func beamerSection(_ name: String, title: String, id: String, listed: Bool) {
        let level = name == "section" ? 1 : 2
        if level == 1 { document.beamer.section += 1 }
        if listed, name != "subsubsection" {
            document.beamer.entries.append(
                .init(
                    title: title, id: id, level: level, section: document.beamer.section, appendix: document.isAppendix)
            )
            let plain = DocumentOutline.plainText(ofHTML: title)
            document.classInfo.beamerSections.append(
                .init(id: id, title: plain, level: level, firstFrame: document.beamer.frame + 1))
        }
        document.beamer.pendingAnchors += "<span id=\"\(id)\"></span>"
        if listed, level == 1, !document.beamer.runningHook, !document.beamer.sectionHook.isEmpty {
            document.beamer.runningHook = true
            defer { document.beamer.runningHook = false }
            appendBlock(blocks(document.beamer.sectionHook))
        }
    }

    private struct FrameOptions {
        var values: [String] = []
        var itemSpecification: String?
        var specification: String?
    }

    private func readFrameOptions() -> FrameOptions {
        var options = FrameOptions()
        options.specification = overlaySpec()
        while let option = optional() {
            if option.hasPrefix("<"), option.hasSuffix(">") {
                options.itemSpecification = option
            } else {
                options.values += option.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return options
    }

    private func readBeamerFrame(_ source: String, options: FrameOptions) {
        guard !document.insideBeamerFrame else {
            appendBlock(blocks(source))
            return
        }
        document.beamer.frame += 1
        let ordinal = document.beamer.frame
        if !options.values.contains("noframenumbering") { document.beamer.numberedFrame += 1 }
        let reader = LaTeXReader(source, document: document, isBlock: true)
        reader.skipSpaces()
        let title = reader.peek() == "{" ? reader.argument() : nil
        reader.skipSpaces()
        let subtitle = title != nil && reader.peek() == "{" ? reader.argument() : nil
        let result = BeamerOverlay.evaluate(
            reader.rest, handout: document.classInfo.profile.page.handout,
            defaultSpecification: options.itemSpecification, frameSpecification: options.specification)
        if result.hasUnreadableSpecification { document.classInfo.unreadableBeamerFrames += 1 }
        let attributes = frameAttributes(options.values)
        let label = options.values.first { $0.hasPrefix("label=") }.map { String($0.dropFirst(6)) }
        let numberedCaptions = document.numberedBeamerCaptions
        let bibliographyMarker = document.beamer.bibliographyMarker
        document.insideBeamerFrame = true
        defer {
            document.insideBeamerFrame = false
            document.numberedBeamerCaptions = numberedCaptions
            document.beamer.bibliographyMarker = bibliographyMarker
        }
        // Printed counters reset on each overlay. Destination IDs remain unique in the combined document.
        let resets = ["equation", "footnote", "figure", "table", "theorem"]
        let counters = resets.map { document.counters[$0] }
        for (page, body) in result.pages.enumerated() {
            for (name, value) in zip(resets, counters) { document.counters[name] = value }
            document.numberedBeamerCaptions = numberedCaptions
            document.beamer.bibliographyMarker = bibliographyMarker
            let firstNote = document.footnotes.count
            document.beamer.title = title.map(inline) ?? ""
            document.beamer.subtitle = subtitle.map(inline) ?? ""
            let content = blocks(body)
            var heading = ""
            if !document.beamer.title.isEmpty {
                heading += "<h2 class=\"beamer-frame-title\">\(document.beamer.title)</h2>"
            }
            if !document.beamer.subtitle.isEmpty {
                heading += "<p class=\"beamer-frame-subtitle\">\(document.beamer.subtitle)</p>"
            }
            if !heading.isEmpty { heading = "<header class=\"beamer-frame-heading\">" + heading + "</header>" }
            let notes = document.footnoteSection(from: firstNote)
            let id = "beamer-frame-\(ordinal)-\(page + 1)"
            var anchors = document.beamer.pendingAnchors
            document.beamer.pendingAnchors = ""
            if page == 0, let label {
                document.labels[label] = (String(document.beamer.numberedFrame), id)
                anchors += "<span id=\"\(HTML.escape(label))\"></span>"
            }
            appendBlock(
                "<section class=\"beamer-frame\" data-frame=\"\(ordinal)\" id=\"\(id)\"\(attributes)>"
                    + anchors + heading + "<div class=\"beamer-frame-body\">" + content + "</div>"
                    + (notes.isEmpty ? "" : "<aside class=\"beamer-footnotes\">" + notes + "</aside>") + "</section>\n")
        }
    }

    private func frameAttributes(_ values: [String]) -> String {
        let align = values.last { ["t", "c", "b"].contains($0) } ?? document.classInfo.profile.page.slideAlignment
        var attributes = " data-align=\"\(align)\""
        for value in values {
            let pair = value.split(separator: "=", maxSplits: 1)
            if let key = pair.first,
                ["plain", "shrink", "squeeze", "allowframebreaks", "noframenumbering", "fragile"].contains(key)
            {
                attributes += " data-\(key)=\"\(pair.count == 2 ? HTML.escape(String(pair[1])) : "")\""
            }
        }
        return attributes
    }

    private func beamerTitlePage() {
        guard !document.makingTitle else { return }
        document.makingTitle = true
        defer { document.makingTitle = false }
        let front = document.frontMatter
        let title = front.title.map(inline) ?? ""
        document.titleHTML = title
        var html = "<div class=\"beamer-titlepage\"><h1 class=\"latex-front-title\">\(title)</h1>"
        let fields = [
            ("latex-front-subtitle", front.subtitle.map(inline) ?? ""),
            ("latex-front-authors", front.authors.map { inline($0.name) }.joined(separator: ", ")),
            ("beamer-institute", front.affiliations.flatMap(\.parts).map(inline).joined(separator: "<br>")),
            ("latex-front-date", inline(front.date ?? "\\today")),
            ("beamer-titlegraphic", inline(document.beamer.titleGraphic)),
        ]
        for (name, text) in fields where !text.isEmpty { html += "<div class=\"\(name)\">\(text)</div>" }
        appendBlock(html + "</div>\n")
    }

    func readBeamerEnvironment(_ name: String, body: String) -> Bool {
        let reader = LaTeXReader(body, document: document, isBlock: true)
        switch name {
        case "frame":
            let options = reader.readFrameOptions()
            readBeamerFrame(reader.rest, options: options)
        case "block", "alertblock", "exampleblock":
            let title = reader.argument().map(inline) ?? ""
            beamerBlock(name, title: title, content: reader.read())
        case "columns":
            let options = reader.optional() ?? ""
            let align = columnAlignment(options)
            let sections = LaTeXLexer.split(reader.rest, at: ["\\column"], protectingEnvironments: true)
            var html = blocks(sections.first ?? "")
            for part in sections.dropFirst() { html += beamerColumn(part, defaultAlignment: align) }
            let width = option("totalwidth", in: options).flatMap(LaTeXSymbols.printLength)
            let style = width.map { " style=\"width:\(HTML.escape($0))\"" } ?? ""
            let onlyText = options.contains("onlytextwidth") || width != nil ? " data-text-width" : ""
            appendBlock("<div class=\"beamer-columns\" data-align=\"\(align)\"\(style)\(onlyText)>\(html)</div>\n")
        case "column": appendBlock(beamerColumn(body, defaultAlignment: nil))
        case "overprint", "surimonooverprintpart", "surimonooverprintcovered":
            if name == "overprint" { _ = reader.optional() }
            let style =
                name == "overprint"
                ? "display:grid" : "grid-area:1/1" + (name == "surimonooverprintcovered" ? ";visibility:hidden" : "")
            appendBlock("<div class=\"beamer-overprint\" style=\"\(style)\">\(reader.read())</div>")
        case "theorem", "lemma", "corollary", "definition", "definitions", "example", "examples", "fact", "problem",
            "solution":
            // Beamer shares one counter across its built-in theorems even when the template hides the number.
            if document.theorems[name] == nil {
                let kind = ["example", "examples"].contains(name) ? "example" : "definition"
                document.theorems[name] = .init(title: name.capitalized, counter: "theorem", style: kind)
            }
            return false
        default: return false
        }
        return true
    }

    func beamerBlock(_ kind: String, title: String, content: String, anchor: String = "") {
        appendBlock(
            "<div class=\"beamer-block\" data-kind=\"\(kind)\"\(anchor)><div class=\"beamer-block-title\">\(title)</div><div class=\"beamer-block-body\">\(content)</div></div>\n"
        )
    }

    private func columnAlignment(_ options: String) -> String {
        options.split(separator: ",").map(String.init).last { ["t", "T", "b", "c"].contains($0) } ?? "c"
    }

    private func beamerColumn(_ body: String, defaultAlignment: String?) -> String {
        let reader = LaTeXReader(body, document: document, isBlock: true)
        let align = reader.optional().map(columnAlignment) ?? defaultAlignment
        let width = reader.argument().flatMap(LaTeXSymbols.printLength) ?? "auto"
        let attr = align.map { " data-align=\"\($0)\"" } ?? ""
        return "<div class=\"beamer-column\"\(attr) style=\"width:\(HTML.escape(width))\">\(reader.read())</div>\n"
    }

    private func overlaySpec() -> String? {
        skipSpaces()
        guard peek() == "<", let end = characters[index...].firstIndex(where: { $0 == ">" || $0 == "\n" }),
            characters[end] == ">"
        else { return nil }
        let spec = String(characters[(index + 1)..<end])
        index = end + 1
        return spec
    }
}

import Foundation

/// Metadata can arrive in the preamble, around \maketitle, or in an elsarticle frontmatter environment.
final class LaTeXFrontMatter {
    struct Author {
        var name: String
        var shortName: String?
        var affiliations: [String] = []
        var email: [String] = []
        var orcid: String?
        var notes: [String] = []
    }

    struct Affiliation {
        var key: String
        var explicitLabel: Bool
        var hasPrintedMark: Bool
        var parts: [String]
    }

    var title: String?
    var shortTitle: String?
    var subtitle: String?
    var authors: [Author] = []
    var declaredEmptyAuthor = false
    var affiliations: [Affiliation] = []
    private var affiliationLabels: Set<String> = []
    private var implicitAffiliations: [[String]: String] = [:]
    var publishers: String?
    var date: String?
    var titleNotes: [String] = []
    var namedNotes: [String: String] = [:]
    var noteOrder: [String] = []
    var printedNotes: [String: (id: String, mark: String)] = [:]
    var abstractHTML: String?
    var keywords: [String] = []
    var classifications: [String] = []
    var printed = false
    var reservedKeywords = false
    var insideEnvironment = false
    var readingAbstract = false

    func addAffiliation(label: String?, parts: [String], attach: Bool, hasPrintedMark: Bool = false) {
        guard !parts.isEmpty else { return }
        let key: String
        if let label, !label.isEmpty {
            key = label
        } else if let existing = implicitAffiliations[parts] {
            key = existing
        } else {
            key = "@affiliation-\(affiliations.count + 1)"
            implicitAffiliations[parts] = key
        }
        if affiliationLabels.insert(key).inserted {
            affiliations.append(
                .init(key: key, explicitLabel: label != nil, hasPrintedMark: hasPrintedMark, parts: parts))
        }
        if attach, !authors.isEmpty { authors[authors.count - 1].affiliations.append(key) }
    }

    func resolve(in html: String, document: LaTeXDocument) -> String {
        guard printed || abstractHTML != nil || reservedKeywords else { return html }
        let abstract = abstractHTML ?? ""
        let classification =
            classifications.isEmpty
            ? "" : "<p class=\"latex-front-classifications\">\(classifications.joined(separator: "; "))</p>\n"
        let separator = document.classInfo.name == "llncs" ? " · " : ", "
        let keywordGap = keywordLabel(document).hasSuffix("—") ? "" : " "
        let keywordLine =
            keywords.isEmpty
            ? ""
            : "<p class=\"latex-front-keywords\"><strong>\(keywordLabel(document))</strong>\(keywordGap)\(keywords.joined(separator: separator))</p>\n"
        let details = classification + keywordLine
        // amsbook prints the classification and keywords on the verso with the abstract.
        let verso = document.classInfo.name == "amsbook" && !details.isEmpty && !abstract.isEmpty
        let abstractPage =
            verso ? "<div class=\"latex-amsbook-verso\">\n" + details + abstract + "</div>\n" : abstract
        let endOfTitle = abstractPage + (verso ? "" : details)
        let spansColumns = document.classInfo.columns > 1 && document.classInfo.journalStyle?.hasWideAbstract == true
        let printedDetails =
            spansColumns && !endOfTitle.isEmpty ? "<div data-latex-wide>\n" + endOfTitle + "</div>\n" : endOfTitle
        return html.replacingOccurrences(of: document.placeholder("F", 0), with: printed ? "" : abstractPage)
            .replacingOccurrences(of: document.placeholder("F", 1), with: printed || verso ? "" : details)
            .replacingOccurrences(of: document.placeholder("F", 2), with: printedDetails)
    }

    private func keywordLabel(_ document: LaTeXDocument) -> String {
        switch document.classInfo.mainLanguage {
        case "ja": return "キーワード："
        case "zh-Hans": return "关键词："
        case "zh-Hant": return "關鍵詞："
        case "ko": return "주제어:"
        case "de": return "Schlüsselwörter:"
        case "fr": return "Mots-clés\u{202F}:"
        case "es": return "Palabras clave:"
        case "it": return "Parole chiave:"
        case "pt", "pt-PT", "pt-BR": return "Palavras-chave:"
        case "nl": return "Trefwoorden:"
        case "ru": return "Ключевые слова:"
        case "uk": return "Ключові слова:"
        case "pl": return "Słowa kluczowe:"
        case "cs": return "Klíčová slova:"
        case "sv": return "Nyckelord:"
        case "tr": return "Anahtar kelimeler:"
        case "el": return "Λέξεις-κλειδιά:"
        case "ar": return "الكلمات المفتاحية:"
        case "he": return "מילות מפתח:"
        default: return document.classInfo.name == "IEEEtran" ? "Index Terms—" : "Keywords:"
        }
    }
}

extension LaTeXDocumentClassInfo {
    /// Shared templates often supply a fallback only when the document class lacks its own command.
    func definesClassCommand(_ command: String) -> Bool {
        switch name {
        case "amsart", "amsbook": return ["address", "email", "keywords", "subjclass"].contains(command)
        case "IEEEtran":
            return [
                "IEEEauthorblockN", "IEEEauthorblockA", "IEEEauthorrefmark", "IEEEkeywords", "IEEEcompsocitemizethanks",
            ].contains(command)
        case "beamer":
            return ["institute", "subtitle", "frame", "titlepage", "frametitle", "framesubtitle", "setbeamertemplate"]
                .contains(command)
        case "llncs": return ["institute", "inst", "email", "orcidID", "keywords"].contains(command)
        case "acmart":
            return [
                "subtitle", "affiliation", "institution", "city", "country", "orcid", "email", "authornote",
                "authornotemark", "keywords", "ccsdesc",
            ].contains(command)
        case "elsarticle":
            return [
                "affiliation", "address", "ead", "corref", "cortext", "fnref", "fntext", "tnoteref", "tnotetext", "sep",
            ].contains(command)
        case "scrartcl", "scrreprt", "scrbook":
            return ["subtitle", "publishers", "addsec", "addchap", "setkomafont", "addtokomafont"].contains(command)
        case "memoir": return ["epigraph", "chapterstyle"].contains(command)
        case "exam":
            return [
                "questions", "parts", "subparts", "choices", "oneparchoices", "checkboxes",
                "solution", "solutionorbox", "solutionorlines", "solutionordottedlines",
                "addpoints", "printanswers", "noprintanswers", "numquestions", "numpoints", "gradetable",
                "pointtable", "fillin", "makeemptybox", "fillwithlines", "fillwithdottedlines",
                "linefillheight", "dottedlinefillheight", "linefillthickness",
                "header", "footer", "firstpageheader", "firstpagefooter", "runningheader", "runningfooter",
            ].contains(command)
        case "letter":
            return ["letter", "name", "address", "signature", "opening", "closing", "ps", "cc", "encl"]
                .contains(command)
        case "moderncv":
            return [
                "moderncvstyle", "moderncvcolor", "name", "address", "phone", "social", "email", "homepage",
                "extrainfo", "photo", "makecvtitle", "cventry", "cvitem", "cvitemwithcomment", "cvdoubleitem",
                "cvlistitem", "cvlistdoubleitem",
            ].contains(command)
        default:
            return name.hasPrefix("revtex") && ["affiliation", "altaffiliation", "email", "keywords"].contains(command)
        }
    }

    var journalFrontMatter: Bool {
        ["amsart", "amsbook", "IEEEtran", "llncs", "acmart", "elsarticle"].contains(name) || name.hasPrefix("revtex")
    }
}

extension LaTeXReader {
    func handleFrontMatter(_ command: String) -> Bool {
        let front = document.frontMatter
        switch command {
        case "title":
            front.shortTitle = optional()
            front.title = argument()
        case "subtitle":
            _ = optional()
            front.subtitle = argument()
        case "publishers": front.publishers = argument()
        case "date":
            _ = optional()
            front.date = argument() ?? ""
        case "author":
            let short = optional()
            let names = LaTeXLexer.split(argument() ?? "", at: ["\\and"])
            if !document.classInfo.journalFrontMatter {
                front.authors = []
                front.declaredEmptyAuthor = names.allSatisfy {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            for source in names {
                readFrontAuthor(source.trimmingCharacters(in: .whitespacesAndNewlines), short: short)
            }
        case "address", "affiliation":
            let option = optional()
            let label = document.classInfo.name == "elsarticle" ? option : nil
            let source = argument() ?? ""
            front.addAffiliation(label: label, parts: affiliationParts(source), attach: label == nil)
        case "institute":
            if document.classInfo.name == "beamer" { _ = optional() }
            let sources = LaTeXLexer.split(argument() ?? "", at: ["\\and"])
            let marked = front.authors.contains { !$0.affiliations.isEmpty }
            for (position, source) in sources.enumerated() {
                front.addAffiliation(label: marked ? String(position + 1) : nil, parts: [source], attach: false)
            }
        case "email", "ead", "orcid", "orcidID":
            let prefix = optional()
            let source = argument() ?? ""
            let orcid = command.hasPrefix("orcid")
            let value = (prefix == "url" ? "" : prefix ?? "") + source
            if document.makingTitle {
                appendHTML("<span class=\"latex-front-\(orcid ? "orcid" : "email")\">\(inline(value))</span>")
            } else if !front.authors.isEmpty {
                if orcid {
                    front.authors[front.authors.count - 1].orcid = value
                } else {
                    front.authors[front.authors.count - 1].email.append(value)
                }
            }
        case "thanks" where !document.makingTitle && (inPreamble || document.classInfo.journalFrontMatter):
            let prefix = optional() ?? ""
            let note = prefix + (argument() ?? "")
            if front.authors.isEmpty {
                front.titleNotes.append(note)
            } else {
                front.authors[front.authors.count - 1].notes.append(note)
            }
        case "authornote", "altaffiliation", "IEEEcompsocitemizethanks":
            let prefix = optional() ?? ""
            let note = prefix + (argument() ?? "")
            if document.makingTitle {
                appendHTML(inline("\\thanks{\(note)}"))
            } else if !front.authors.isEmpty {
                front.authors[front.authors.count - 1].notes.append(note)
            }
        case "authornotemark":
            let number = optional().flatMap(Int.init) ?? document.titleNoteCount
            let symbol = LaTeXSymbols.format(number, as: "fnsymbol")
            if document.makingTitle, let note = document.footnotes.first(where: { $0.number == symbol }) {
                appendHTML(
                    styledLinks("<sup class=\"footnote-ref\"><a href=\"#\(note.id)\">\(HTML.escape(symbol))</a></sup>"))
            } else if !document.makingTitle, !front.authors.isEmpty {
                front.authors[front.authors.count - 1].name += "\\authornotemark[\(number > 0 ? String(number) : "")]"
            }
        case "IEEEcompsocthanksitem":
            appendText("• ")
        case "cortext", "fntext", "tnotetext":
            let key = optional() ?? command
            if front.namedNotes[key] == nil { front.noteOrder.append(key) }
            front.namedNotes[key] = argument() ?? ""
        case "corref", "fnref", "tnoteref":
            let keys = argument() ?? ""
            for key in frontLabels(keys) {
                if let previous = front.printedNotes[key] {
                    appendHTML(
                        styledLinks(
                            "<sup class=\"footnote-ref\"><a href=\"#\(previous.id)\">\(HTML.escape(previous.mark))</a></sup>"
                        ))
                } else if let note = front.namedNotes[key] {
                    let index = document.footnotes.count
                    let html = inline("\\thanks{\(note)}")
                    if index < document.footnotes.count {
                        let note = document.footnotes[index]
                        front.printedNotes[key] = (note.id, note.number)
                    }
                    appendHTML(html)
                }
            }
        case "keywords", "IEEEkeywords":
            readKeywords(argument() ?? "")
        case "subjclass", "ccsdesc":
            _ = optional()
            let value = inline(argument() ?? "")
            if !value.isEmpty { front.classifications.append(value) }
            reserveFrontKeywords()
        case "inst", "IEEEauthorrefmark":
            let mark = inline(argument() ?? "")
            appendHTML("<sup class=\"latex-front-mark\">\(mark)</sup>")
        default: return false
        }
        return true
    }

    private func frontLabels(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Split only at outer control words. Braces around prose, macro arguments and verbatim delimiters remain opaque.
    private func extractFrontFields(_ text: String, commands: [String], field: (String, String) -> Void) -> String {
        let parts = LaTeXLexer.split(text, at: commands, keepingSeparators: true)
        var remaining = parts.first ?? ""
        var index = 1
        while index + 1 < parts.count {
            let reader = LaTeXReader(parts[index + 1], document: document, isBlock: false)
            field(parts[index], reader.argument() ?? "")
            remaining += reader.rest
            index += 2
        }
        return remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readFrontAuthor(_ source: String, short: String?) {
        guard !source.isEmpty else { return }
        let front = document.frontMatter
        let labels = document.classInfo.name == "elsarticle" ? frontLabels(short ?? "") : []
        var author = LaTeXFrontMatter.Author(name: "", shortName: labels.isEmpty ? short : nil, affiliations: labels)
        var ieeeNames: [String] = []
        var ieeeAffiliations: [String] = []
        let rest = extractFrontFields(
            source, commands: ["\\inst", "\\orcidID", "\\IEEEauthorblockN", "\\IEEEauthorblockA"]
        ) { name, value in
            switch name {
            case "\\inst": author.affiliations += frontLabels(value)
            case "\\orcidID": author.orcid = value
            case "\\IEEEauthorblockN": ieeeNames.append(value)
            default: ieeeAffiliations.append(value)
            }
        }
        author.name = (ieeeNames + [rest]).filter { !$0.isEmpty }.joined(separator: " ")
        front.authors.append(author)
        for affiliation in ieeeAffiliations {
            // IEEE's shared-name layout puts explicit marks inside both the name and the address.
            let printed = affiliation.contains("\\IEEEauthorrefmark")
            front.addAffiliation(label: nil, parts: [affiliation], attach: !printed, hasPrintedMark: printed)
        }
    }

    private func affiliationParts(_ source: String) -> [String] {
        let keys = ["organization", "organisation", "addressline", "city", "state", "postcode", "country"]
        if document.classInfo.name == "elsarticle", source.contains("=") {
            let fields = LaTeXPageSettings.options(source)
            if fields.contains(where: { keys.contains($0.key) }) { return fields.map(\.value).filter { !$0.isEmpty } }
        }
        var parts: [String] = []
        let rest = extractFrontFields(
            source,
            commands: [
                "\\institution", "\\department", "\\streetaddress", "\\city", "\\state", "\\postcode", "\\country",
            ]
        ) { _, value in
            if !value.isEmpty { parts.append(value) }
        }
        if !rest.isEmpty { parts.append(rest) }
        return parts
    }

    func readFrontEnvironment(_ name: String, body: String) {
        let front = document.frontMatter
        switch name {
        case "CCSXML": break
        case "frontmatter":
            let previous = front.insideEnvironment
            front.insideEnvironment = true
            let other = blocks(body)
            front.insideEnvironment = previous
            makeTitle()
            appendBlock(other)
        case "abstract":
            let previous = front.readingAbstract
            front.readingAbstract = true
            let heading = captionName("abstractname")
            let disposition = frontDispositionAttribute
            let content = blocks(body)
            let html =
                document.classInfo.journalStyle?.abstract(heading: heading, body: content)
                ?? "<div class=\"abstract latex-front-abstract\"\(disposition)>\n<p class=\"abstract-title\">\(heading)</p>\n\(content)</div>\n"
            front.readingAbstract = previous
            if front.abstractHTML == nil
                && (inPreamble || front.insideEnvironment || document.classInfo.journalFrontMatter
                    || front.title != nil && (!front.printed || !front.keywords.isEmpty))
            {
                front.abstractHTML = html
                if !inPreamble && !front.printed { appendBlock(document.placeholder("F", 0)) }
            } else {
                appendBlock(html)
            }
            if !front.keywords.isEmpty { reserveFrontKeywords() }
        default: readKeywords(body)
        }
    }

    private func readKeywords(_ source: String) {
        let keywords = LaTeXLexer.split(source, at: ["\\and", "\\sep"]).map(inline).filter { !$0.isEmpty }
        document.frontMatter.keywords += keywords
        reserveFrontKeywords()
    }

    private func reserveFrontKeywords() {
        let front = document.frontMatter
        if !inPreamble && !front.readingAbstract && !front.printed && !front.reservedKeywords {
            front.reservedKeywords = true
            appendBlock(document.placeholder("F", 1))
        }
    }

    private var frontDispositionAttribute: String {
        let info = document.classInfo
        return info.isKOMA ? info.bookStyle.fontAttribute(elements: ["disposition"], size: info.pointSize) : ""
    }

    func makeTitle() {
        let front = document.frontMatter
        guard !front.printed || document.insideBeamerFrame, !document.makingTitle else { return }
        front.printed = true
        document.makingTitle = true
        defer { document.makingTitle = false }
        let titleStyle =
            document.classInfo.hidesTitlePageNumber
            ? " data-latex-page-action=\"thispagestyle\" data-value=\"empty\"" : ""
        let span = document.classInfo.columns > 1 ? " data-latex-wide" : ""
        var html = "<header class=\"latex-title-block\"\(span)\(titleStyle)\(frontDispositionAttribute)>\n"
        if let title = front.title {
            let titleHTML = inline(title)
            document.titleHTML = titleHTML
            let notes = front.titleNotes.map { inline("\\thanks{\($0)}") }.joined()
            html += "<h1 class=\"latex-title latex-front-title\">\(titleHTML)\(notes)</h1>\n"
        }
        if let subtitle = front.subtitle {
            html += "<p class=\"latex-front-subtitle\">\(inline(subtitle))</p>\n"
        }
        var marks: [String: String] = [:]
        for (index, affiliation) in front.affiliations.enumerated()
        where !affiliation.hasPrintedMark && (affiliation.explicitLabel || front.affiliations.count > 1) {
            marks[affiliation.key] =
                document.classInfo.name == "elsarticle"
                ? LaTeXSymbols.format(index + 1, as: "alph") : String(index + 1)
        }
        if !front.authors.isEmpty {
            let names = front.authors.map { author in
                let labels = author.affiliations.compactMap { marks[$0] }.joined(separator: ",")
                var name = inline(author.name)
                if !labels.isEmpty { name += "<sup class=\"latex-front-mark\">\(HTML.escape(labels))</sup>" }
                name += author.notes.map { inline("\\thanks{\($0)}") }.joined()
                for email in author.email { name += "<span class=\"latex-front-email\">\(inline(email))</span>" }
                if let orcid = author.orcid { name += "<span class=\"latex-front-orcid\">\(inline(orcid))</span>" }
                return "<span class=\"latex-author-name latex-front-author\">\(name)</span>"
            }
            html += "<p class=\"latex-author\">\(names.joined())</p>\n"
        }
        if front.declaredEmptyAuthor && front.authors.isEmpty {
            html += "<p class=\"latex-author latex-empty-author\"><br></p>\n"
        }
        // An unreferenced corresponding-author declaration still prints a note in elsarticle.
        for key in front.noteOrder where front.printedNotes[key] == nil {
            if let note = front.namedNotes[key] { _ = inline("\\thanks{\(note)}") }
        }
        if !front.affiliations.isEmpty {
            html += "<div class=\"latex-front-affiliations\">\n"
            for affiliation in front.affiliations {
                let mark =
                    marks[affiliation.key].map { "<sup class=\"latex-front-mark\">\(HTML.escape($0))</sup> " } ?? ""
                let text = affiliation.parts.map(inline).joined(separator: ", ")
                html += "<p class=\"latex-front-affiliation\">\(mark)\(text)</p>\n"
            }
            html += "</div>\n"
        }
        // These classes do not include a date in their normal title block, even if the author supplies one.
        if !["amsbook", "IEEEtran", "llncs", "acmart", "elsarticle"].contains(document.classInfo.name) {
            let date = front.date ?? (document.classInfo.journalFrontMatter ? "" : "\\today")
            let dateHTML = inline(date)
            if !dateHTML.isEmpty {
                let printed = document.classInfo.journalStyle?.isAPS == true ? "(Dated: \(dateHTML))" : dateHTML
                html += "<p class=\"latex-date latex-front-date\">\(printed)</p>\n"
            }
        }
        if let publishers = front.publishers {
            html += "<p class=\"latex-front-publishers\">\(inline(publishers))</p>\n"
        }
        appendBlock(html + "</header>\n" + document.placeholder("F", 2))
    }
}

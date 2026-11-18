import Foundation

/// External records are collected during reading and selected only after the last citation.
final class LaTeXBibliography {
    struct Record {
        let type: String
        let fields: [String: String]
    }
    var records: [String: Record] = [:]
    var fileOrder: [String] = []
    // BibTeX's built-in month strings remain overridable by a database's own @string entries.
    var strings = [
        "jan": "January", "feb": "February", "mar": "March", "apr": "April", "may": "May", "jun": "June",
        "jul": "July", "aug": "August", "sep": "September", "oct": "October", "nov": "November", "dec": "December",
    ]
    var printCount = 0
    var wantsAll = false
    var citationOrder: [String] = []
    private var seen: Set<String> = []
    var style = ""
    var authorYearOption: Bool?
    var natbib = false
    var citationOrderOverride: Bool?
    var citationLabels: [String: (author: String, year: String)] = [:]

    var authorYear: Bool {
        authorYearOption
            ?? (style.hasPrefix("authoryear") || ["apalike", "chicago", "harvard", "agsm", "dcu"].contains(style)
                || style.hasSuffix("nat") || natbib && style.isEmpty)
    }

    func applyNatbibOptions(_ options: [String]) {
        for option in options {
            if option == "authoryear" { authorYearOption = true }
            if option == "numbers" || option == "super" { authorYearOption = false }
        }
    }

    func remember(_ keys: [String]) {
        for key in keys where seen.insert(key).inserted { citationOrder.append(key) }
    }

    func render(in document: LaTeXDocument) -> String {
        guard !records.isEmpty else { return "" }
        // Unsorted styles follow the first citation, then append uncited records in file order for \nocite{*}.
        // Sort only the selected records, preserving the citation order when two authors have the same name.
        let keys = citationOrder + (wantsAll ? fileOrder.filter { !seen.contains($0) } : [])
        var selected: [(key: String, entry: Entry)] = []
        for key in keys {
            guard let record = records[key] else { continue }
            var fields = record.fields
            if let parent = fields["crossref"].flatMap({ records[$0]?.fields }) {
                // One inheritance step handles proceedings and avoids following crossref cycles.
                for (field, value) in parent where fields[field] == nil {
                    guard document.reserveExpansion(characters: value.utf8.count) else { break }
                    fields[field] = value
                }
                if fields["booktitle"] == nil, let title = parent["title"],
                    document.reserveExpansion(characters: title.utf8.count)
                {
                    fields["booktitle"] = title
                }
            }
            guard document.reserveExpansion() else { break }
            selected.append((key, Entry(fields, key: key, type: record.type)))
        }
        let citationOrdered =
            citationOrderOverride ?? (style.hasPrefix("unsrt") || style == "none" || style.isEmpty && !authorYear)
        if !citationOrdered {
            selected = selected.sorted { $0.entry.sortKey < $1.entry.sortKey }
        }
        guard !selected.isEmpty else { return "" }
        let heading = document.isJapanese ? "参考文献" : document.hasChapters ? "Bibliography" : "References"
        var html = "<h2 class=\"latex-bibliography-heading\">\(heading)</h2>\n"
        if authorYear {
            html += "<ol class=\"latex-bibliography\">\n"
        } else {
            let digits = String(selected.count).count
            html += "<ol class=\"latex-bibliography latex-numbered\" style=\"--latex-label-digits: \(digits)ch\">\n"
        }
        for (position, item) in selected.enumerated() {
            let id = "bib-db-\(position + 1)"
            let entry = item.entry
            let label = authorYear ? entry.authorYear : String(position + 1)
            let row = "<li id=\"\(id)\"><span class=\"bib-label\">[\(label)]</span> \(entry.html)</li>\n"
            guard document.reserveExpansion(characters: row.utf8.count) else { break }
            document.bibliography[item.key] = (label, printCount > 0 ? id : "")
            citationLabels[item.key] = (entry.shortAuthor, entry.year)
            html += row
        }
        return html + "</ol>\n"
    }

    private struct Entry {
        let html: String
        let shortAuthor: String
        let year: String
        let sortKey: String
        var authorYear: String { [shortAuthor, year].filter { !$0.isEmpty }.joined(separator: ", ") }

        init(_ fields: [String: String], key: String, type: String) {
            let authors = LaTeXBibText.names(fields["author"] ?? "")
            let editors = LaTeXBibText.names(fields["editor"] ?? "")
            let citedNames = authors.isEmpty ? editors : authors
            let organization =
                ["manual", "proceedings"].contains(type) ? LaTeXBibText.decode(fields["organization"] ?? "") : ""
            let first = citedNames.first?.family ?? (organization.isEmpty ? key : organization)
            sortKey = first.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let short =
                citedNames.count >= 3 || citedNames.last?.family == "et al."
                ? first + " et al." : citedNames.map(\.family).joined(separator: " and ")
            shortAuthor = HTML.escape(short.isEmpty ? first : short)
            func field(_ name: String, sentenceCase: Bool = false) -> String {
                LaTeXBibText.decode(fields[name] ?? "", html: true, sentenceCase: sentenceCase)
            }
            func nameList(_ names: [(family: String, printedHTML: String)]) -> String {
                let words = names.map(\.printedHTML)
                guard let last = words.last else { return "" }
                if words.count == 1 { return last }
                if last == "et al." { return words.dropLast().joined(separator: ", ") + " " + last }
                return words.dropLast().joined(separator: ", ") + (words.count > 2 ? ", and " : " and ") + last
            }

            year = field("year").isEmpty ? String(field("date").prefix(4)) : field("year")
            let publication = LaTeXBibPublication(type: type, fields: fields)
            let editorCredit =
                editors.isEmpty ? "" : nameList(editors) + (editors.count == 1 ? ", editor" : ", editors")
            var pieces = publication.blocks(authors: nameList(authors), editors: editorCredit, year: year)
            for key in ["doi", "url"] {
                guard let value = fields[key], !value.isEmpty else { continue }
                let raw = value.replacingOccurrences(of: "\\_", with: "_").replacingOccurrences(of: "\\%", with: "%")
                    .replacingOccurrences(of: "\\&", with: "&")
                let url = key == "doi" && !raw.hasPrefix("https://") ? "https://doi.org/" + raw : raw
                let label = HTML.escape(raw)
                if let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                    pieces.append("<a href=\"\(HTML.escape(url))\">\(label)</a>")
                } else {
                    pieces.append(label)
                }
            }
            // A title's italic closing tag can follow its final punctuation. Inspect its visible
            // ending when adding the period between plain.bst blocks.
            html = pieces.filter { !$0.isEmpty }.map { piece in
                let punctuated = piece.range(of: #"[.?!](?:</[a-z]+>)*$"#, options: .regularExpression) != nil
                return punctuated ? piece : piece + "."
            }.joined(separator: " ")
        }
    }
}

/// The standard style joins fields inside a sentence with commas and starts a new block with
/// a period. Keeping the blocks as separate strings makes optional fields disappear with their
/// punctuation, e.g. the organization precedes the date only when a conference has no address.
private struct LaTeXBibPublication {
    let type: String
    let fields: [String: String]

    private func field(_ name: String, sentenceCase: Bool = false) -> String {
        LaTeXBibText.decode(fields[name] ?? "", html: true, sentenceCase: sentenceCase)
    }

    private func joined(_ parts: String..., separator: String = ", ") -> String {
        parts.filter { !$0.isEmpty }.joined(separator: separator)
    }

    private func italic(_ text: String) -> String { text.isEmpty ? "" : "<em>\(text)</em>" }

    private func labelled(_ label: String, _ value: String) -> String {
        value.isEmpty ? "" : "\(label) \(value)"
    }

    private var volumeAndSeries: String {
        let volume = field("volume")
        guard !volume.isEmpty else { return "" }
        return joined("volume " + volume, italic(field("series")), separator: " of ")
    }

    private func numberAndSeries(atStart: Bool) -> String {
        guard field("volume").isEmpty else { return "" }
        let number = field("number")
        return joined(labelled(atStart ? "Number" : "number", number), field("series"), separator: " in ")
    }

    private var rawPages: String {
        field("pages").replacingOccurrences(of: #"-+"#, with: "–", options: .regularExpression)
    }

    private var pages: String {
        let value = rawPages
        let multiple = value.contains { "–—,+".contains($0) }
        return labelled(multiple ? "pages" : "page", value)
    }

    private var chapterPages: String {
        let chapterType = field("type")
        let chapter = labelled(chapterType.isEmpty ? "chapter" : chapterType.lowercased(), field("chapter"))
        return joined(chapter, pages)
    }

    private func edition(afterPreviousField: Bool) -> String {
        var text = field("edition", sentenceCase: true)
        guard !text.isEmpty else { return "" }
        if afterPreviousField { text = text.prefix(1).lowercased() + text.dropFirst() }
        return text + " edition"
    }

    private func container(editors: String) -> String {
        let book = italic(field("booktitle"))
        return book.isEmpty ? "" : "In " + joined(editors, book)
    }

    /// Both proceedings forms place the address and date together. When an address is present
    /// the society and publisher follow the date in their own sentence, as in plain.bst.
    private func proceedings(_ title: String, organization: String, date: String) -> [String] {
        let publisher = field("publisher")
        let address = field("address")
        let producers = joined(organization, publisher)
        if !address.isEmpty { return [joined(title, address, date), producers] }
        return producers.isEmpty ? [joined(title, date)] : [title, joined(producers, date)]
    }

    func blocks(authors: String, editors: String, year: String) -> [String] {
        let date = joined(field("month"), year, separator: " ")
        let standalone = ["book", "inbook", "manual", "phdthesis", "proceedings"].contains(type)
        let title = standalone ? italic(field("title")) : field("title", sentenceCase: true)
        let publisher = field("publisher")
        let address = field("address")
        let organization = field("organization")
        let note = field("note")
        let blocks: [String]
        switch type {
        case "article":
            let number = field("number")
            let issue = field("volume") + (number.isEmpty ? "" : "(\(number))")
            let locator = issue.isEmpty ? pages : joined(issue, rawPages, separator: ":")
            blocks = [authors, title, joined(italic(field("journal")), locator, date)]
        case "book", "inbook":
            let imprint = joined(publisher, address)
            blocks = [
                authors.isEmpty ? editors : authors,
                joined(title, volumeAndSeries, type == "inbook" ? chapterPages : ""),
                numberAndSeries(atStart: true), joined(imprint, edition(afterPreviousField: !imprint.isEmpty), date),
            ]
        case "booklet":
            let imprint = joined(field("howpublished"), address)
            blocks = imprint.isEmpty ? [authors, joined(title, date)] : [authors, title, joined(imprint, date)]
        case "phdthesis", "mastersthesis":
            let degree = field("type", sentenceCase: true)
            let fallback = type == "phdthesis" ? "PhD thesis" : "Master’s thesis"
            blocks = [authors, title, joined(degree.isEmpty ? fallback : degree, field("school"), address, date)]
        case "techreport":
            let number = field("number")
            let report = field("type", sentenceCase: number.isEmpty)
            let fallback = number.isEmpty ? "Technical report" : "Technical Report"
            let designation = joined(report.isEmpty ? fallback : report, number, separator: " ")
            blocks = [authors, title, joined(designation, field("institution"), address, date)]
        case "incollection":
            let imprint = joined(publisher, address)
            blocks = [
                authors, title,
                joined(container(editors: editors), volumeAndSeries, numberAndSeries(atStart: false), chapterPages),
                joined(imprint, edition(afterPreviousField: !imprint.isEmpty), date),
            ]
        case "inproceedings", "conference":
            let location = joined(container(editors: editors), volumeAndSeries, numberAndSeries(atStart: false), pages)
            blocks = [authors, title] + proceedings(location, organization: organization, date: date)
        case "proceedings":
            let collection = joined(title, volumeAndSeries, numberAndSeries(atStart: false))
            blocks =
                [editors.isEmpty ? organization : editors]
                + proceedings(collection, organization: editors.isEmpty ? "" : organization, date: date)
        case "manual":
            let corporateAuthor = authors.isEmpty && !organization.isEmpty
            let credit = corporateAuthor ? joined(organization, address) : authors
            let imprint = corporateAuthor ? "" : joined(organization, address)
            let tail = joined(edition(afterPreviousField: !imprint.isEmpty || !title.isEmpty), date)
            blocks = imprint.isEmpty ? [credit, joined(title, tail)] : [credit, title, joined(imprint, tail)]
        case "unpublished":
            return [authors, title, joined(note, date)]
        default:
            let medium = field("howpublished")
            blocks = medium.isEmpty ? [authors, joined(title, date)] : [authors, title, joined(medium, date)]
        }
        return blocks + [note]
    }
}

extension LaTeXReader {
    func loadBibliography(_ paths: String) {
        for raw in paths.split(separator: ",") {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            if let source = readLocalText(path, defaultExtension: "bib") {
                var parser = LaTeXBibTeX(source, document: document)
                parser.parse()
            } else {
                let name = (path as NSString).pathExtension.isEmpty ? path + ".bib" : path
                keepFileNote(fileNote(name))
            }
        }
    }

    func readPackage() {
        let options = (optional() ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let packages = (argument() ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if packages.contains(where: { ["amsthm", "ntheorem", "thmtools"].contains($0) }) {
            document.usesAMSTheorem = true
        }
        if packages.contains("natbib") {
            document.bibDatabase.natbib = true
            document.bibDatabase.applyNatbibOptions(options)
        }
        if packages.contains("biblatex") {
            for option in options {
                let pair = option.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2 else { continue }
                if pair[0] == "style" { document.bibDatabase.style = pair[1].lowercased() }
                if pair[0] == "sorting" { document.bibDatabase.citationOrderOverride = pair[1] == "none" }
            }
        }
    }

    func externalBibliography(_ name: String) {
        switch name {
        case "setcitestyle":
            let options = (argument() ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            document.bibDatabase.applyNatbibOptions(options)
        case "bibliographystyle":
            document.bibDatabase.style = (argument() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case "nocite":
            let keys = (argument() ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if keys.contains("*") { document.bibDatabase.wantsAll = true }
            document.bibDatabase.remember(keys.filter { $0 != "*" })
        case "addbibresource":
            _ = optional()
            loadBibliography(argument() ?? "")
        default:
            if name == "bibliography" { loadBibliography(argument() ?? "") } else { _ = optional() }
            appendBlock(document.placeholder("B", document.bibDatabase.printCount))
            document.bibDatabase.printCount += 1
        }
    }
}

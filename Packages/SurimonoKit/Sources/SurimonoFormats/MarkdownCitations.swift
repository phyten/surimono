import Foundation

/// Citations are collected from prose nodes. Final labels and cross-referenced BibTeX
/// records come from the same database and expansion budget as a LaTeX document.
final class MarkdownCitations {
    private struct Item {
        let key: String
        let prefix: String
        let suffix: String
    }

    private struct Citation {
        let items: [Item]
        let inText: Bool
    }

    private let document = LaTeXDocument()
    private let metadata: MarkdownMetadata
    private var citations: [Citation] = []
    private var tocHeadings: [MarkdownExtensions.HeadingAnchor] = []
    private let nonce = UUID().uuidString
    var referencesMarker: String { "<!--\(nonce)-->" }
    var issues: [String] { document.readingIssues }

    init(metadata: MarkdownMetadata, directory: URL?, readFile: @escaping (URL) -> Data?) {
        self.metadata = metadata
        document.directory = directory
        document.readFile = readFile
        document.bibDatabase.printCount = 1
        let reader = LaTeXReader("", document: document, isBlock: false)
        var files = Set<String>()
        for file in metadata.bibliography where files.insert(file).inserted {
            if let source = reader.readLocalText(file, defaultExtension: "bib") {
                var parser = LaTeXBibTeX(source, document: document)
                parser.parse()
            } else {
                document.reportFileIssue("\(file) could not be read")
            }
        }
    }

    private static let key = #"[\p{L}\p{N}_.:/-]+"#
    private static let pattern = try? NSRegularExpression(
        pattern: #"(?<![a-zA-Z\d+.-])(?:[a-zA-Z][a-zA-Z\d+.-]*://|www\.)[^\s<]+|\[[^\[\]@\n]*@[^\[\]\n]*\]|(?<![\w@])@"#
            + key)
    private static let member = try? NSRegularExpression(
        pattern: #"^([^@]*?)(?<![\w@])-?@("# + key + #")(\s*,[^@]*)?$"#)

    /// Links, code and math have already been isolated by the Markdown renderer.
    func prose(_ text: String) -> String {
        func literal(_ part: String) -> String { HTML.escape(MarkdownExtensions.emojified(part)) }
        guard text.contains("@"), let pattern = Self.pattern else { return literal(text) }
        var html = ""
        var cursor = 0
        let source = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let matched = source.substring(with: match.range)
            let citation: Citation
            var consumed = match.range
            if matched.first == "[" {
                let parts = matched.dropFirst().dropLast().split(separator: ";", omittingEmptySubsequences: false)
                let items = parts.compactMap(Self.item)
                guard items.count == parts.count else { continue }
                citation = Citation(items: items, inText: false)
            } else if matched.first == "@" {
                var key = String(matched.dropFirst())
                // In prose the period after an ordinary key belongs to the sentence. A database may
                // also explicitly define a key ending in punctuation; prefer that full spelling.
                if document.bibDatabase.records[key] == nil {
                    while let last = key.last, ".:/".contains(last) {
                        key.removeLast()
                        consumed.length -= 1
                    }
                }
                guard !key.isEmpty else { continue }
                citation = Citation(items: [Item(key: key, prefix: "", suffix: "")], inText: true)
            } else {
                continue
            }
            document.bibDatabase.remember(citation.items.map(\.key))
            html +=
                literal(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                + token("C", index: citations.count)
            citations.append(citation)
            cursor = NSMaxRange(consumed)
        }
        return html + literal(source.substring(from: cursor))
    }

    private static func item(_ raw: Substring) -> Item? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.contains("://"),
            let match = member?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let key = Range(match.range(at: 2), in: text), let prefix = Range(match.range(at: 1), in: text)
        else { return nil }
        let suffix = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
        return Item(key: String(text[key]), prefix: String(text[prefix]), suffix: suffix)
    }

    private func token(_ kind: String, index: Int) -> String { "\u{E002}\(nonce)\(kind)\(index)\u{E003}" }

    func tableOfContents(_ anchors: [MarkdownExtensions.HeadingAnchor], levels: Int, title: String?) -> String {
        let labels = anchors.map { heading in
            guard heading.text.contains("@") else { return heading }
            let label = token("T", index: tocHeadings.count)
            tocHeadings.append(heading)
            return MarkdownExtensions.HeadingAnchor(
                number: heading.number, level: heading.level, id: heading.id, text: label)
        }
        return MarkdownExtensions.tableOfContents(labels, levels: levels, title: title)
    }

    private func replacing(_ kind: String, in body: String, with replacement: (Int) -> String?) -> String {
        let regex = try? NSRegularExpression(pattern: "\u{E002}\(nonce)\(kind)([0-9]+)\u{E003}")
        let source = body as NSString
        var html = ""
        var cursor = 0
        for match in regex?.matches(in: body, range: NSRange(location: 0, length: source.length)) ?? [] {
            guard let index = Int(source.substring(with: match.range(at: 1))), let value = replacement(index) else {
                continue
            }
            html += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            html += value
            cursor = NSMaxRange(match.range)
        }
        return html + source.substring(from: cursor)
    }

    func finish(_ body: String) -> String {
        for value in metadata.nocite {
            for word in value.split(whereSeparator: { $0.isWhitespace || $0 == "," }) where word.first == "@" {
                if word == "@*" {
                    document.bibDatabase.wantsAll = true
                } else {
                    document.bibDatabase.remember([String(word.dropFirst())])
                }
            }
        }
        // Nonces contain Latin letters and could outweigh the prose of a short Japanese note.
        let language = DocumentLanguage.detect(
            html: body.replacingOccurrences(of: nonce, with: ""), declared: metadata.language, fallback: "en")
        let heading =
            metadata.referenceSectionTitle ?? (DocumentLanguage.primary(language.code) == "ja" ? "参考文献" : "References")
        document.bibDatabase.joinsWideNames = DocumentLanguage.primary(language.code) == "ja"
        let bibliography = document.bibDatabase.render(in: document, heading: heading)
        // Repeating a long BibTeX author in a short source should not multiply its size without bound.
        var authorBudget = 2_000_000
        var html = replacing("C", in: body) { index in
            citations.indices.contains(index) ? render(citations[index], authorBudget: &authorBudget) : nil
        }
        if !tocHeadings.isEmpty {
            // Read the printed heading after its citations resolve, so the TOC neither allocates numbers ahead
            // of the prose nor nests citation links inside its own link to the heading.
            var labels: [String: String] = [:]
            for heading in DocumentOutline.headings(inHTML: html) {
                if let id = heading.id { labels[id] = heading.text }
            }
            html = replacing("T", in: html) { index in
                guard tocHeadings.indices.contains(index) else { return nil }
                let heading = tocHeadings[index]
                return HTML.escape(labels[heading.id] ?? heading.text)
            }
        }
        if let place = html.range(of: referencesMarker) {
            html.replaceSubrange(place, with: bibliography)
            return html.replacingOccurrences(of: referencesMarker, with: "")
        }
        // Without a `#refs` division the references end the text, and the notes follow them, as in Pandoc.
        if let notes = html.range(of: "<section class=\"footnotes\"", options: .backwards) {
            html.insert(contentsOf: bibliography, at: notes.lowerBound)
            return html
        }
        return html + bibliography
    }

    private func render(_ citation: Citation, authorBudget: inout Int) -> String {
        var author = ""
        let numbers = citation.items.map { item in
            let value: String
            if let entry = document.bibliography[item.key] {
                value = metadata.linkCitations ? "<a href=\"#\(entry.id)\">\(entry.label)</a>" : entry.label
                if citation.inText, let label = document.bibDatabase.citationLabels[item.key] {
                    if label.author.utf8.count <= min(20_000, authorBudget) {
                        author = label.author + " "
                        authorBudget -= label.author.utf8.count
                    } else {
                        author = HTML.escape(item.key) + " "
                    }
                }
            } else {
                value = "<strong class=\"latex-missing\">@\(HTML.escape(item.key))?</strong>"
            }
            return HTML.escape(item.prefix) + value + HTML.escape(item.suffix)
        }
        return "<span class=\"latex-cite\">\(author)[\(numbers.joined(separator: "; "))]</span>"
    }
}

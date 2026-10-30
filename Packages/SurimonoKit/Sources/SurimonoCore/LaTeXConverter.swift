import Foundation

/// A LaTeX document as HTML for the print themes: its structure and text, with math typeset by SwaTex.
///
/// Surimono is not a TeX engine. It reads the commonly used subset of LaTeX and the standard packages (amsmath and
/// friends through SwaTex, hyperref, xcolor, enumitem, listings), so a document prints in Surimono's own paper,
/// margins and theme. Commands it does not know keep their text; TikZ pictures are marked where they would be.
public enum LaTeXConverter {
    /// - Parameter directory: The document's folder, where images without an extension are looked up.
    public static func convert(_ text: String, directory: URL? = nil) -> HTMLFragment {
        let source = TextDecoding.normalizeNewlines(text)
        let document = LaTeXDocument()
        document.directory = directory
        let (preamble, body) = split(source)
        if let preamble { LaTeXReader(preamble, document: document, isBlock: false).readPreamble() }
        if LaTeXLexer.find("chapter", in: Array(body)) != nil { document.hasChapters = true }
        var html = LaTeXReader(body, document: document, isBlock: true).read()
        if document.titleHTML == nil, let title = document.title {
            // Without \maketitle the title still names the window and the exported PDF.
            let plain = title.replacingOccurrences(of: #"\\thanks\s*\{[^}]*\}"#, with: "", options: .regularExpression)
            document.titleHTML = LaTeXReader(plain, document: document, isBlock: false).read()
        }
        // Notes and the table of contents may hold references too, so they are in place before references resolve.
        html += document.footnoteSection()
        html = document.resolvePlaceholders(in: html)
        let fonts = MathRenderer.fontFaces(for: html)
        if !fonts.isEmpty { html += "<style>\n\(fonts)\n</style>\n" }
        return HTMLFragment(body: html, title: document.plainTitle)
    }

    /// The preamble and the body inside `document`; a fragment without one is all body. Comments and code are
    /// stepped over, so `\\end{document}` written in either does not end the document.
    private static func split(_ source: String) -> (preamble: String?, body: String) {
        let characters = Array(source)
        func environment(_ command: String, from start: Int) -> Int? {
            var cursor = start
            let marker = Array("{document}")
            while let found = LaTeXLexer.find(command, in: characters, from: cursor) {
                let after = found + command.count + 1
                if after + marker.count <= characters.count, Array(characters[after..<(after + marker.count)]) == marker
                {
                    return found
                }
                cursor = found + 1
            }
            return nil
        }
        guard let begin = environment("begin", from: 0) else { return (nil, source) }
        let bodyStart = begin + "\\begin{document}".count
        let bodyEnd = environment("end", from: bodyStart) ?? characters.count
        return (String(characters[..<begin]), String(characters[bodyStart..<bodyEnd]))
    }
}

/// What one document's conversion shares across nested groups: definitions, counters, labels and notes.
final class LaTeXDocument {
    struct Macro {
        let parameters: Int
        let defaultArgument: String?
        let body: String
    }

    struct Heading {
        let level: Int
        let number: String?
        let id: String
        let title: String
    }

    struct Theorem {
        /// The heading's source, such as `Theorem` or `定理`.
        let title: String
        /// The counter it numbers with, shared by `\newtheorem{…}[other]{…}`; nil for `\newtheorem*`.
        let counter: String?
        let style: String
    }

    struct Citation {
        let keys: [String]
        let before: String?
        let after: String?
    }

    enum ReferenceStyle {
        case number
        case equation
    }

    var documentClass = "article"
    var title: String?
    var titleHTML: String?
    var authors: String?
    /// nil prints today's date, as LaTeX does; an empty date prints none.
    var date: String?
    var macros: [String: Macro] = [:]
    /// Definitions given to every formula, so commands defined in the preamble work in math too.
    var mathDefinitions = ""
    var colors: [String: (Double, Double, Double)] = [:]
    var hasChapters = false
    var isAppendix = false
    var sectionCounters = Array(repeating: 0, count: 6)
    var partCounter = 0
    var headings: [Heading] = []
    var labels: [String: (number: String, id: String)] = [:]
    /// The most recent numbered thing; a `\label` names it.
    var labelTarget: (number: String, id: String)?
    var equationCount = 0
    var figureCount = 0
    var taggedCount = 0
    var itemCount = 0
    var tableCount = 0
    var directory: URL?
    var graphicsPaths: [String] = []
    var footnotes: [String] = []
    var references: [(key: String, style: ReferenceStyle)] = []
    var enumerateDepth = 0
    var theorems: [String: Theorem] = [:]
    var theoremStyle = "plain"
    /// amsthm's look (a period after the heading, the note in roman) rather than LaTeX's own `\newtheorem`.
    var usesAMSTheorem = false
    /// What a theorem counter counts within (`\newtheorem{…}{…}[section]`).
    var counterParents: [String: String] = [:]
    /// Each theorem counter's value and the number it counted under; a new parent number starts it again.
    var counterValues: [String: (value: Int, parent: String)] = [:]
    var theoremCount = 0
    var bibliography: [String: (label: String, id: String)] = [:]
    var bibliographyCount = 0
    var citations: [Citation] = []
    /// How many readers are reading inside one another.
    var depth = 0
    static let maximumDepth = 100
    /// Set while `\maketitle` reads the title, so a title that makes the title again is not read again.
    var makingTitle = false
    /// Each theorem's heading, read once: a heading that opens its own environment would otherwise read itself again.
    var theoremHeadings: [String: String] = [:]
    var headingBudget = 2_000_000
    var expansions = 0
    /// Characters macros produced, and the work spent putting them back into the source; both are bounded so a
    /// recursive or doubling definition cannot exhaust memory or time.
    var expandedCharacters = 0
    var expansionWork = 0
    /// Set once a limit is reached: later macros are dropped and their arguments read as text.
    var stopsExpanding = false
    let nonce = String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement() ?? "x" })

    var isJapanese: Bool {
        let japanese = ["j", "ltjs", "bxjs", "ujarticle", "ujreport", "ujbook", "utarticle", "tarticle"]
        return japanese.contains { documentClass.hasPrefix($0) }
    }

    var plainTitle: String? {
        titleHTML.map { $0.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) }
            .map { HTML.unescape($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func placeholder(_ kind: String, _ index: Int) -> String { "\u{E000}\(nonce)\(kind)\(index)\u{E001}" }

    func reference(_ key: String, style: ReferenceStyle) -> String {
        references.append((key, style))
        return placeholder("R", references.count - 1)
    }

    func citation(_ citation: Citation) -> String {
        citations.append(citation)
        return placeholder("C", citations.count - 1)
    }

    /// Fills in the table of contents, then the references and citations, which may point at things defined later in
    /// the document and may sit in the headings the table of contents repeats.
    func resolvePlaceholders(in html: String) -> String {
        resolveCitations()
        return replacing("C", in: replacing("R", in: replacing("T", in: html)))
    }

    private var resolvedCitations: [String] = []

    /// Each citation's HTML, in the order they were made. A note or an entry's label may cite again; a citation made
    /// earlier is filled in, a later one (or the citation itself) is not, so nothing refers back to itself. Labels
    /// that cite a lot, or a long label cited many times, could still multiply the text, so each citation is built
    /// within a size limit and all of them within a budget; past either, it shows its keys as written.
    private func resolveCitations() {
        var budget = 2_000_000
        resolvedCitations = []
        for (index, citation) in citations.enumerated() {
            if budget > 0, let html = citationHTML(citation, before: index, limit: min(20_000, budget)) {
                budget -= html.utf8.count
                resolvedCitations.append(html)
            } else {
                // No longer than the source that cites them.
                let keys = HTML.escape(citation.keys.joined(separator: ", "))
                resolvedCitations.append("<span class=\"latex-cite\">[\(keys)]</span>")
            }
        }
    }

    /// `[1, 2, p. 3]`, each number linking to its entry. A key with no `\bibitem` prints itself in bold, as biblatex
    /// does, so the reader can tell which source is meant. Each piece is checked against `limit` before it is added;
    /// nil when the citation would pass it.
    private func citationHTML(_ citation: Citation, before index: Int, limit: Int) -> String? {
        var html = "<span class=\"latex-cite\">["
        func add(_ piece: String) -> Bool {
            guard let filled = filled(piece, below: index, limit: limit - html.utf8.count) else { return false }
            html += filled
            return true
        }
        if let before = citation.before, !before.isEmpty, !add(before + " ") { return nil }
        for (position, key) in citation.keys.enumerated() {
            if position > 0, !add(", ") { return nil }
            if let entry = bibliography[key] {
                // The label goes in on its own, so a label too long is turned down before it is copied anywhere.
                guard add("<a href=\"#\(HTML.escape(entry.id))\">"), add(entry.label), add("</a>") else { return nil }
            } else if !add("<span class=\"latex-missing\">\(HTML.escape(key))</span>") {
                return nil
            }
        }
        if let after = citation.after, !after.isEmpty, !add(", " + after) { return nil }
        return add("]</span>") ? html : nil
    }

    /// A piece of a citation with its references and earlier citations filled in, or nil once it would pass `limit`.
    /// Filling in never makes a placeholder shorter, so the check before each addition is enough.
    private func filled(_ piece: String, below index: Int, limit: Int) -> String? {
        guard piece.utf8.count <= limit else { return nil }
        guard piece.contains("\u{E000}\(nonce)"),
            let regex = try? NSRegularExpression(pattern: "\u{E000}\(nonce)([RC])([0-9]+)\u{E001}")
        else { return piece }
        let nsPiece = piece as NSString
        var output = ""
        var size = 0
        func add(_ text: String) -> Bool {
            size += text.utf8.count
            guard size <= limit else { return false }
            output += text
            return true
        }
        var cursor = 0
        for match in regex.matches(in: piece, range: NSRange(location: 0, length: nsPiece.length)) {
            guard add(nsPiece.substring(with: NSRange(location: cursor, length: match.range.location - cursor))) else {
                return nil
            }
            cursor = match.range.location + match.range.length
            let number = Int(nsPiece.substring(with: match.range(at: 2))) ?? -1
            let replacement =
                nsPiece.substring(with: match.range(at: 1)) == "R"
                ? referenceHTML(number)
                : number < index && resolvedCitations.indices.contains(number)
                    ? resolvedCitations[number] : "<span class=\"latex-missing\">?</span>"
            guard add(replacement) else { return nil }
        }
        return add(nsPiece.substring(from: cursor)) ? output : nil
    }

    /// Fills in one kind of placeholder. The table of contents and citations can be long and a placeholder can be
    /// repeated (in a theorem heading printed many times), so what they add in one pass has a budget.
    private func replacing(_ kind: String, in html: String) -> String {
        guard html.contains("\u{E000}\(nonce)\(kind)"),
            let regex = try? NSRegularExpression(pattern: "\u{E000}\(nonce)\(kind)([0-9]+)\u{E001}")
        else { return html }
        let nsHTML = html as NSString
        var output = ""
        var cursor = 0
        var budget = 4_000_000
        var contents: String?
        for match in regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            output += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let index = Int(nsHTML.substring(with: match.range(at: 1))) ?? -1
            switch kind {
            case "T":
                let toc = contents ?? tableOfContents()
                contents = toc
                if toc.utf8.count <= budget {
                    output += toc
                    budget -= toc.utf8.count
                }
            case "C":
                let citation =
                    resolvedCitations.indices.contains(index)
                    ? resolvedCitations[index] : "<span class=\"latex-missing\">?</span>"
                if citation.utf8.count <= budget {
                    output += citation
                    budget -= citation.utf8.count
                } else {
                    output += "<span class=\"latex-cite\">[…]</span>"
                }
            default: output += referenceHTML(index)
            }
        }
        return output + nsHTML.substring(from: cursor)
    }

    /// A reference's number linking to what it names. A number is short unless it is an equation's own `\tag`; that
    /// is cut, so a long tag referred to many times cannot multiply.
    private func referenceHTML(_ index: Int) -> String {
        guard references.indices.contains(index) else { return "" }
        let (key, style) = references[index]
        // LaTeX prints ?? for a label it cannot find.
        guard let target = labels[key] else { return "<span class=\"latex-missing\">??</span>" }
        let number = target.number.utf8.count > 300 ? String(target.number.prefix(100)) + "…" : target.number
        let text = style == .equation ? "(\(number))" : number
        return "<a href=\"#\(HTML.escape(target.id))\">\(HTML.escape(text))</a>"
    }

    private func tableOfContents() -> String {
        let entries = headings.filter { $0.number != nil }
        guard let top = entries.map(\.level).min() else { return "" }
        var html = "<nav class=\"toc\">"
        var depth = 0
        var open: [Bool] = []
        for entry in entries {
            let level = entry.level - top + 1
            while depth < level {
                html += "<ul>"
                depth += 1
                open.append(false)
            }
            while depth > level {
                if open.removeLast() { html += "</li>" }
                html += "</ul>"
                depth -= 1
            }
            if open.last == true { html += "</li>" }
            let number = entry.number.map { "<span class=\"secnum\">\(HTML.escape($0))</span>" } ?? ""
            html += "<li><a href=\"#\(HTML.escape(entry.id))\">\(number)\(entry.title)</a>"
            open[open.count - 1] = true
        }
        while depth > 0 {
            if open.removeLast() { html += "</li>" }
            html += "</ul>"
            depth -= 1
        }
        return html + "</nav>\n"
    }

    func footnoteSection() -> String {
        guard !footnotes.isEmpty else { return "" }
        let items = footnotes.enumerated().map { "<li id=\"fn-\($0.offset + 1)\">\($0.element)</li>\n" }.joined()
        return "<section class=\"footnotes\">\n<ol>\n\(items)</ol>\n</section>\n"
    }

    /// An image's path as written, or with the extension LaTeX would find: graphicx tries several when a file is
    /// named without one, in the document's folder and in `\graphicspath`.
    func imageSource(_ file: String) -> String {
        guard let directory else { return file }
        let names =
            (file as NSString).pathExtension.isEmpty
            ? ["pdf", "png", "jpg", "jpeg", "svg", "gif"].map { file + "." + $0 } : [file]
        for folder in [""] + graphicsPaths {
            for name in names
            where FileManager.default.fileExists(atPath: directory.appending(path: folder + name).path) {
                return folder + name
            }
        }
        return file
    }

    /// Today's date, as `\today` prints it.
    func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: isJapanese ? "ja_JP" : "en_US")
        formatter.dateFormat = isJapanese ? "y年M月d日" : "MMMM d, y"
        return formatter.string(from: Date())
    }
}

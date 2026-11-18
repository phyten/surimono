import Foundation

/// A LaTeX document as HTML for the print themes: its structure and text, with math typeset by SwaTex.
///
/// Surimono is not a TeX engine. It reads the commonly used subset of LaTeX and the standard packages (amsmath and
/// friends through SwaTex, hyperref, xcolor, enumitem, listings), so a document prints in Surimono's own paper,
/// margins and theme. Commands it does not know keep their text; externalized TikZ pictures can be printed.
public enum LaTeXConverter {
    /// Companion files are supplied by the caller so parsing never implicitly opens a path from the document.
    public static func convert(
        _ text: String, directory: URL? = nil,
        documentURL: URL? = nil, textWidthPoints: Double? = nil, imageExists: @escaping (URL) -> Bool = { _ in false },
        readFile: @escaping (URL) -> Data? = { _ in nil },
        modificationDate: @escaping (URL) -> Date? = { _ in nil },
        fileIdentity: @escaping (URL) -> URL = { $0.standardizedFileURL }
    ) -> HTMLFragment {
        let source = TextDecoding.normalizeNewlines(text)
        func makeReader() -> LaTeXReader {
            let document = LaTeXDocument()
            document.directory = directory ?? documentURL?.deletingLastPathComponent()
            document.mainURL = documentURL
            document.textWidthPoints = textWidthPoints
            document.readFile = readFile
            document.modificationDate = modificationDate
            document.fileIdentity = fileIdentity
            document.imageExists = imageExists
            return LaTeXReader(source, document: document, isBlock: true)
        }
        var reader = makeReader()
        // Definitions, comments, code and untaken branches may quote a document boundary. Only a command
        // actually reached by the reader starts or ends the body. A fragment can quote both boundaries.
        if source.range(of: #"\\begin\s*\{document\}"#, options: .regularExpression) != nil {
            reader.readPreamble()
            if !reader.document.startedDocument { reader = makeReader() }
        }
        let document = reader.document
        var html = document.preambleFileNotes + reader.read()
        document.endedDocument = false
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
        return HTMLFragment(
            body: html, title: document.plainTitle, readingIssues: document.readingIssues,
            latexClass: document.classInfo)
    }

}

/// What one document's conversion shares across nested groups: definitions, counters, labels and notes.
final class LaTeXDocument {
    var imageExists: (URL) -> Bool = { _ in false }
    var textWidthPoints: Double?
    var mainURL: URL?
    var readFile: (URL) -> Data? = { _ in nil }
    var modificationDate: (URL) -> Date? = { _ in nil }
    var fileIdentity: (URL) -> URL = { $0.standardizedFileURL }
    var inputChain: [URL] = []
    var includeOnly: Set<String>?
    var fileIssues: [String] = []
    var seenFileIssues: Set<String> = []
    var preambleFileNotes = ""
    var pictureIndex = 0
    var picturePrefix = ""
    var nextPictureName: String?
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
        let command: String
        let keys: [String]
        let before: String?
        let after: String?
    }

    var startedDocument = false
    var endedDocument = false
    var classInfo = LaTeXDocumentClassInfo()
    var title: String?
    var titleHTML: String?
    var authors: String?
    /// nil prints today's date, as LaTeX does; an empty date prints none.
    var date: String?
    var macros: [String: Macro] = [:]
    var hasExtendedMathDefinitions = false
    var environments: [String: (begin: Macro, end: String)] = [:]
    /// Definitions given to every formula, so commands defined in the preamble work in math too.
    // In a formula TeX is already in math mode. This identity also works inside nested
    // ordinary macros that SwaTex expands itself, without changing the accessible source.
    var mathDefinitions = "\\def\\ensuremath#1{#1}"
    var booleans: [String: Bool] = [:]
    var toggles: [String: Bool] = [:]
    var loopMathNames: Set<String> = []
    var colors: [String: (Double, Double, Double)] = [:]
    var hasChapters = false {
        didSet {
            if hasChapters && !oldValue {
                counters.within("section", parent: "chapter", prefix: true)
                // The standard book/report classes omit chapter zero on floats and equations in front matter.
                for name in ["equation", "figure", "table"] {
                    counters.within(name, parent: "chapter", prefix: true, omitNonpositiveParent: true)
                }
                counters.within("footnote", parent: "chapter", prefix: false)
            }
        }
    }
    var isAppendix = false
    let counters = LaTeXCounters()
    var figureCaptions: LaTeXFigureCaptions?
    var insideSubfigure = false
    var subequationPrefix: String?
    var headings: [Heading] = []
    var labels: [String: (number: String, id: String)] = [:]
    /// The most recent numbered thing; a `\label` names it.
    var labelTarget: (number: String, id: String)?
    var taggedCount = 0
    var itemCount = 0
    var directory: URL?
    var graphicsPaths: [String] = []
    var listingDefaults: [String: String] = [:]
    var listingStyles: [String: String] = [:]
    var footnotes: [Footnote] = []
    var references: [Reference] = []
    var resolvingReferences: Set<Int> = []
    /// After 200 KB of nested link text, use an ellipsis so repeated captions cannot multiply indefinitely.
    var nestedReferenceWork = 200_000
    var targetDescriptions: [String: TargetDescription] = [:]
    var sharesReferenceNames = false
    var nameCopies = 0
    var referenceNames: [String: ReferenceNames] = [:]
    var deferredMath: [ReferencedFormula] = []
    var enumerateDepth = 0
    var theorems: [String: Theorem] = [:]
    var theoremStyle = "plain"
    /// amsthm's look (a period after the heading, the note in roman) rather than LaTeX's own `\newtheorem`.
    var usesAMSTheorem = false
    var theoremCount = 0
    var bibliography: [String: (label: String, id: String)] = [:]
    let bibDatabase = LaTeXBibliography()
    var bibliographyCount = 0
    var citations: [Citation] = []
    /// How many readers are reading inside one another.
    var depth = 0
    /// A hundred levels allow nested prose and macros while leaving stack space for the reader to recover.
    static let maximumDepth = 100
    /// Set while `\maketitle` reads the title, so a title that makes the title again is not read again.
    var makingTitle = false
    var titleNoteCount = 0
    var failedFormulas: [String] = []
    var seenFormulaIssues: Set<String> = []
    /// Each theorem's heading, read once: a heading that opens its own environment would otherwise read itself again.
    var theoremHeadings: [String: String] = [:]
    /// Two MB allow long theorem headings throughout a paper. Once spent, the environment name still identifies them.
    var headingBudget = 2_000_000
    var expansions = 0
    var unknownNames: [String] = []
    var seenUnknown: Set<String> = []
    var uppercase: Bool?
    var usedNoteIDs: Set<String> = []
    var emphasisDepth = 0
    var highlightColor: String?
    var nextPendingNote = 0
    var pendingByNumber: [String: ArraySlice<Int>] = [:]
    /// Characters macros produced, and the work spent putting them back into the source; both are bounded so a
    /// recursive or doubling definition cannot exhaust memory or time.
    var expandedCharacters = 0
    /// Stop expansion after 50 million units of scanning and copying: even small insertions can shift a long tail.
    var expansionWork = 0
    /// Plain source continues to print after expansion stops; the fragment reports the limit once.
    var stopsExpanding = false
    let nonce = String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement() ?? "x" })

    /// The print check panel can explain omissions here without putting diagnostic text on the paper.
    var readingIssues: [String] {
        var issues = fileIssues
        if !unknownNames.isEmpty { issues.append("commands not read: " + unknownNames.joined(separator: ", ")) }
        issues.append(contentsOf: failedFormulas)
        if stopsExpanding { issues.append("LaTeX expansion limit reached") }
        return issues
    }

    /// Keep first-use order so a repeated command yields one name and authors can locate it in source order.
    func recordUnknown(_ name: String) {
        if seenUnknown.insert(name).inserted { unknownNames.append(name) }
    }

    var isJapanese: Bool { classInfo.isJapanese }

    var plainTitle: String? {
        titleHTML.map { replacing("M", in: replacing("C", in: replacing("R", in: $0))) }
            .map { $0.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) }
            .map { HTML.unescape($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func placeholder(_ kind: String, _ index: Int) -> String { "\u{E000}\(nonce)\(kind)\(index)\u{E001}" }

    func citation(_ citation: Citation) -> String {
        bibDatabase.remember(citation.keys)
        citations.append(citation)
        return placeholder("C", citations.count - 1)
    }

    /// Fills in the table of contents, then the references and citations, which may point at things defined later in
    /// the document and may sit in the headings the table of contents repeats.
    func resolvePlaceholders(in html: String) -> String {
        let bibliography = bibDatabase.render(in: self)
        let body = bibDatabase.printCount > 0 ? replacing("B", in: html, bibliography: bibliography) : html
        resolveCitations()
        return replacing("M", in: replacing("C", in: replacing("R", in: replacing("T", in: body))))
    }

    private var resolvedCitations: [String] = []

    /// Each citation's HTML, in the order they were made. A note or an entry's label may cite again; a citation made
    /// earlier is filled in, a later one (or the citation itself) is not, so nothing refers back to itself. Labels
    /// that cite a lot, or a long label cited many times, could still multiply the text, so each citation is built
    /// within a size limit and all of them within a budget; past either, it shows its keys as written.
    private func resolveCitations() {
        // Allow 20 KB per citation for notes and 2 MB across the paper so repeated notes fall back to compact keys.
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
        let authorOnly = citation.command == "citeauthor"
        let yearOnly = citation.command == "citeyear"
        let hasDatabaseLabel = citation.keys.contains { bibDatabase.citationLabels[$0] != nil }
        let authorYear = hasDatabaseLabel && bibDatabase.authorYear
        let textual = hasDatabaseLabel && ["citet", "textcite"].contains(citation.command)
        let bare = (hasDatabaseLabel && (authorOnly || yearOnly)) || textual
        let close = bare ? "" : authorYear ? ")" : "]"
        var html = "<span class=\"latex-cite\">" + (bare ? "" : authorYear ? "(" : "[")
        func add(_ piece: String) -> Bool {
            guard let filled = filled(piece, below: index, limit: limit - html.utf8.count) else { return false }
            html += filled
            return true
        }
        if let before = citation.before, !before.isEmpty, !add(before + " ") { return nil }
        for (position, key) in citation.keys.enumerated() {
            if position > 0, !add(authorYear && !bare ? "; " : ", ") { return nil }
            if let entry = bibliography[key] {
                // The label goes in on its own, so a label too long is turned down before it is copied anywhere.
                func addLinked(_ text: String) -> Bool {
                    entry.id.isEmpty
                        ? add(text)
                        : add("<a href=\"#\(HTML.escape(entry.id))\">") && add(text) && add("</a>")
                }
                if let label = bibDatabase.citationLabels[key], authorOnly || yearOnly || textual {
                    if authorOnly {
                        guard addLinked(label.author) else { return nil }
                    } else if yearOnly {
                        guard addLinked(label.year) else { return nil }
                    } else {
                        guard add(label.author), add(authorYear ? " (" : " ["),
                            addLinked(authorYear ? label.year : entry.label)
                        else { return nil }
                        if position == citation.keys.count - 1, let after = citation.after, !after.isEmpty {
                            guard add(", "), add(after) else { return nil }
                        }
                        guard add(authorYear ? ")" : "]") else { return nil }
                    }
                } else if !addLinked(entry.label) {
                    return nil
                }
            } else if !add("<span class=\"latex-missing\">\(HTML.escape(key))</span>") {
                return nil
            }
        }
        if !textual || citation.keys.last.flatMap({ bibDatabase.citationLabels[$0] }) == nil,
            let after = citation.after, !after.isEmpty, !add(", " + after)
        {
            return nil
        }
        return add(close + "</span>") ? html : nil
    }

    /// A piece of a citation with its references and earlier citations filled in, or nil once it would pass `limit`.
    /// Filling in never makes a placeholder shorter, so the check before each addition is enough.
    func filled(_ piece: String, below index: Int, limit: Int) -> String? {
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
    private func replacing(_ kind: String, in html: String, bibliography: String = "") -> String {
        guard html.contains("\u{E000}\(nonce)\(kind)"),
            let regex = try? NSRegularExpression(pattern: "\u{E000}\(nonce)\(kind)([0-9]+)\u{E001}")
        else { return html }
        let nsHTML = html as NSString
        var output = ""
        var cursor = 0
        // Four MB allows rendered math and a long contents list. Omit excess contents or abbreviate other output.
        var budget = 4_000_000
        var contents: String?
        var repeatedBibliography: String?
        for match in regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            output += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let index = Int(nsHTML.substring(with: match.range(at: 1))) ?? -1
            switch kind {
            case "B":
                if bibliography.utf8.count <= budget {
                    if index == 0 {
                        output += bibliography
                    } else {
                        // Citation links have a single destination even if the author prints the list twice.
                        let repeated =
                            repeatedBibliography
                            ?? bibliography.replacingOccurrences(
                                of: #"<li id="bib-db-[0-9]+">"#, with: "<li>", options: .regularExpression)
                        repeatedBibliography = repeated
                        output += repeated
                    }
                    budget -= bibliography.utf8.count
                }
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
            default:
                guard budget > 0 else {
                    output += "…"
                    continue
                }
                let resolved = kind == "M" ? renderFormula(index) : referenceHTML(index)
                if resolved.utf8.count <= budget {
                    output += resolved
                    budget -= resolved.utf8.count
                } else {
                    output += "…"
                }
            }
        }
        return output + nsHTML.substring(from: cursor)
    }

    private func tableOfContents() -> String {
        let entries = headings.filter { $0.number != nil }
        guard let top = entries.map(\.level).min() else { return "" }
        let title = isJapanese ? "目次" : "Contents"
        var html = "<nav class=\"toc\"><p class=\"latex-contents-title\">\(title)</p>"
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
            let kind = entry.level == 0 ? " class=\"latex-toc-chapter\"" : ""
            html += "<li\(kind)><a href=\"#\(HTML.escape(entry.id))\">\(number)\(entry.title)</a>"
            open[open.count - 1] = true
        }
        while depth > 0 {
            if open.removeLast() { html += "</li>" }
            html += "</ul>"
            depth -= 1
        }
        return html + "</nav>\n"
    }

    /// An image's path as written, or with the extension LaTeX would find: graphicx tries several when a file is
    /// named without one, in the document's folder and in `\graphicspath`.
    func imageSource(_ file: String) -> String {
        guard let directory else { return file }
        let names =
            (file as NSString).pathExtension.isEmpty
            ? ["pdf", "png", "jpg", "jpeg", "svg", "gif"].map { file + "." + $0 } : [file]
        for base in searchDirectories {
            for folder in [""] + graphicsPaths {
                for name in names {
                    let url = base.appending(path: folder + name)
                    if imageExists(url) { return resourceSource(url, relativeTo: directory) }
                }
            }
        }
        if let base = inputChain.last?.deletingLastPathComponent() {
            return resourceSource(base.appending(path: file), relativeTo: directory)
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

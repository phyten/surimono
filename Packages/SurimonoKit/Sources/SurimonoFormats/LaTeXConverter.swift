import Foundation

/// A LaTeX document as HTML for the print themes: its structure and text, with math typeset by SwaTex.
///
/// Surimono is not a TeX engine. It reads the commonly used subset of LaTeX and the standard packages (amsmath and
/// friends through SwaTex, hyperref, xcolor, enumitem, listings), so a document prints in Surimono's own paper,
/// margins and theme. Commands it does not know keep their text; supported TikZ pictures are drawn, with externalized figures as a fallback.
public enum LaTeXConverter {
    package static let unreadCommandPrefix = "commands not read: "
    package static let japaneseUnreadCommandPrefix = "読み取れなかったコマンド："

    /// Companion files are supplied by the caller so parsing never implicitly opens a path from the document.
    public static func convert(
        _ text: String, fontIndex: InstalledFontIndex = .system, directory: URL? = nil,
        documentURL: URL? = nil, textWidthPoints: Double? = nil, imageExists: @escaping (URL) -> Bool = { _ in false },
        canProbePictureFallback: @escaping (URL) -> Bool = { _ in true },
        imageSizeInPoints: @escaping (URL) -> CGSize? = { _ in nil },
        readFile: @escaping (URL) -> Data? = { _ in nil },
        modificationDate: @escaping (URL) -> Date? = { _ in nil },
        fileIdentity: @escaping (URL) -> URL = { $0.standardizedFileURL }
    ) -> HTMLFragment {
        let source = TextDecoding.normalizeNewlines(text)
        func makeReader() -> LaTeXReader {
            let document = LaTeXDocument(fontIndex: fontIndex)
            document.directory = directory ?? documentURL?.deletingLastPathComponent()
            document.mainURL = documentURL
            document.textWidthPoints = textWidthPoints
            document.readFile = readFile
            document.modificationDate = modificationDate
            document.fileIdentity = fileIdentity
            document.canProbePictureFallback = canProbePictureFallback
            document.imageExists = imageExists
            document.imageSizeInPoints = imageSizeInPoints
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
        document.initialHyperref = document.hyperref
        let prefix = document.classInfo.columns > 1 ? document.columnMarker(document.classInfo.columns) : ""
        var html = prefix + document.preambleFileNotes + reader.read()
        document.endedDocument = false
        if document.titleHTML == nil, let title = document.frontMatter.title {
            // Without \maketitle the title still names the window and the exported PDF.
            let plain = title.replacingOccurrences(of: #"\\thanks\s*\{[^}]*\}"#, with: "", options: .regularExpression)
            document.titleHTML = LaTeXReader(plain, document: document, isBlock: false).read()
        }
        html = document.frontMatter.resolve(in: html, document: document)
        // Notes and the table of contents may hold references too, so they are in place before references resolve.
        html += document.footnoteSection()
        html = document.resolvePlaceholders(in: html)
        if document.classInfo.profile.body.readsQuestions {
            html = document.replacing("E", in: html)
            document.classInfo.pageNumbers.examTotals = [
                "numquestions": String(document.exam.questions.count),
                "numpoints": LaTeXExam.number(document.exam.total),
            ]
        }
        if document.pictureIndex > 0 { html += "<style>\n\(LaTeXReader.pictureCSS)\n</style>\n" }
        if let css = document.initialHyperref.styleSheet(hasLocalColors: document.hasLocalLinkColors) {
            html += "<style>\n\(css)\n</style>\n"
        }
        let fonts = MathRenderer.fontFaces(for: html)
        if !fonts.isEmpty { html += "<style>\n\(fonts)\n</style>\n" }
        return HTMLFragment(
            body: html, title: document.plainTitle, language: document.classInfo.mainLanguage,
            readingIssues: document.readingIssues,
            latexClass: document.typesettingInfo)
    }

}

/// What one document's conversion shares across nested groups: definitions, counters, labels and notes.
final class LaTeXDocument {
    var canProbePictureFallback: (URL) -> Bool = { _ in true }
    var imageExists: (URL) -> Bool = { _ in false }
    var imageSizeInPoints: (URL) -> CGSize? = { _ in nil }
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
    var pictureCaptions: LaTeXPictureCaptions?
    var pictureHeadings: [Int: String] = [:]
    var pictureStyles = ""
    var usesMetaArrows = false
    var plotDefaults: String?
    var pictureIndex = 0
    var picturePrefix = ""
    var nextPictureName: String?
    struct Heading {
        var chapter: Int?
        var chapterLabelHTML: String?
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
        var full = false
        let keys: [String]
        let before: String?
        let after: String?
    }

    var styleDeclaration: String?
    var stylePackage: LaTeXStylePackageRegistry.Request?
    var passedPackageOptions: [String: [String]] = [:]
    var styleMainFontRevision = 0
    var loadsTimesPackage = false
    var readingConferenceTitle = false
    var requestsRaggedBottom: Bool?
    var requestsFrenchSpacing: Bool?
    var lineParameters = LaTeXLineParameters() {
        didSet { lineParameterAttribute = lineParameters.attribute }
    }
    private(set) var lineParameterAttribute = ""

    var finalCopy = false
    var workshopTitle = ""
    var preamblePageActions: [(String, String)] = []
    var startedDocument = false
    var endedDocument = false
    var typesettingInfo: LaTeXDocumentClassInfo {
        var info = classInfo
        if info.usesPublicationGrid, let requestsRaggedBottom {
            info.raggedColumns = requestsRaggedBottom
        }
        let stock = pageSettings.pageBox(for: info)
        let box = landscapeBody && stock.paperWidth < stock.paperHeight ? stock.turnedForLandscape : stock
        info.resolvedPageBox = box
        let labelMetrics = LaTeXLabelMetrics(info)
        info.styleVariables =
            pageSettings.styleVariables(for: box, info: info) + "; " + labelMetrics.variables
            + "; --latex-array-baseline: " + LaTeXPageSettings.number(labelMetrics.baselines[4])
        if let scale = info.jsMagnification {
            info.styleVariables += "; --latex-js-scale: " + LaTeXPageSettings.number(scale)
        }
        if classInfo.profile.body.correspondence == .curriculumVitae {
            let ink = LaTeXCorrespondence.palette[correspondence.color] ?? LaTeXCorrespondence.defaultInk
            info.styleVariables += "; --latex-cv-ink: " + ink
            if classLanguageOptions.last(where: { ["sans", "roman"].contains($0) }) == "sans" {
                info.styleVariables += "; --latex-cv-font: var(--tex-sans-fonts)"
            }
        }
        info.mainFontName = pageSettings.fonts.mainFontName ?? info.profile.typography.defaultMainFont
        if let style = info.resolvedStyle, style.runningHeader != nil {
            info.headerStrutDepth = style.centeredRunningTitle ? 3.08 : 3.6 * 72 / 72.27
        }
        if info.usesTraditionalJapaneseNames && info.profile.structure.bookOpening != nil {
            info.japaneseMainFontName = pageSettings.fonts.japaneseMainFontName ?? "HiraMinProN-W3"
        }
        if info.profile.typography.usesScaledBodyFont {
            let fallback =
                pageSettings.fonts.japaneseMain?.ideographFallback.map { "\"Surimono \($0) Ideographs\", " } ?? ""
            info.styleVariables += "; --latex-js-body-font: " + fallback + "\"Surimono JS Mincho\""
            info.japaneseMainFontName = pageSettings.fonts.japaneseMainFontName ?? "HiraMinProN-W3"
            // fancyhdr terminates its header with a normal-size strut, above headsep.
            info.headerStrutDepth = 0.3 * labelMetrics.baselines[4] * 72 / 72.27
        }
        info.localFontFaces =
            (pageSettings.fonts.faceRules
            + [
                labelMetrics.localFace(fonts: pageSettings.fonts),
                labelMetrics.publicationFaces(for: info, index: pageSettings.fonts.index),
                labelMetrics.headingFace(for: info, index: pageSettings.fonts.index),
                info.profile.headings.readsElementFonts ? LaTeXBookStyle.sansFaces : nil,
            ]
            .compactMap { $0 }).joined(
                separator: "\n")
        return info
    }

    var correspondence = LaTeXCorrespondence()
    var landscapeBody = false
    var startedLandscape = false
    var exam = LaTeXExam()
    var pageSettings: LaTeXPageSettings

    init(fontIndex: InstalledFontIndex = .system) { pageSettings = LaTeXPageSettings(fontIndex: fontIndex) }
    var classInfo = LaTeXDocumentClassInfo.article
    var bodyPageStyles: LaTeXPageNumbers?
    var language = "en"
    var nativeCaptionLanguage: String?
    var basicBidiTables = false
    var classicBabelLanguages: Set<String> = []
    var spanishSectionDots = true
    var classLanguageOptions: [String] = []
    var localizedCaptions: [String: [String: String]] = [:]
    var quoteDepth = 0
    var lists: [String: [Heading]] = [:]
    let frontMatter = LaTeXFrontMatter()
    var titleHTML: String?
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
    var countRegisters: [String: Int] = [:]
    var hasChapters = false {
        didSet {
            if hasChapters && !oldValue {
                let unprefixed = classInfo.profile.headings.unprefixedChapterCounters
                counters.defaultSectionDepth = unprefixed ? 3 : 2
                counters.within("section", parent: "chapter", prefix: !unprefixed)
                // The standard book/report classes omit chapter zero on floats and equations in front matter.
                for name in unprefixed ? ["figure", "table"] : ["equation", "figure", "table"] {
                    counters.within(name, parent: "chapter", prefix: !unprefixed, omitNonpositiveParent: true)
                }
                counters.within("footnote", parent: "chapter", prefix: false)
            }
        }
    }
    var isAppendix = false
    var numbersChapters = true
    var hasNonArabicHeading = false
    var headingEndDot: String {
        switch classInfo.profile.headings.endDots {
        case .never: ""
        case .always: "."
        case .automatic: placeholder("D", 0)
        }
    }
    let counters = LaTeXCounters()
    var figureCaptions: LaTeXFigureCaptions?
    var insideSubfigure = false
    var insideBeamerFrame = false
    var numberedBeamerCaptions = false
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
    var listStack: [String] = []
    var enumerateDepth = 0
    var theorems: [String: Theorem] = [:]
    var theoremStyle = "plain"
    /// amsthm's look (a period after the heading, the note in roman) rather than LaTeX's own `\newtheorem`.
    var usesAMSTheorem = false
    var theoremCount = 0
    var bibliography: [String: (label: String, id: String)] = [:]
    let bibDatabase = LaTeXBibliography()
    var explicitPreambleInks: Set<String> = []
    var hyperref = LaTeXHyperref()
    var initialHyperref = LaTeXHyperref()
    var hasLocalLinkColors = false
    var bibliographyCount = 0
    var citations: [Citation] = []
    /// How many readers are reading inside one another.
    var depth = 0
    /// A hundred levels allow nested prose and macros while leaving stack space for the reader to recover.
    static let maximumDepth = 100
    /// Set while `\maketitle` reads the title, so a title that makes the title again is not read again.
    var makingTitle = false
    var insideTitlePage = false
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
        var issues = pictureHeadings.isEmpty ? fileIssues : fileIssues.map { replacing("P", in: $0, rawText: true) }
        if !unknownNames.isEmpty {
            let prefix =
                classInfo.mainLanguage == "ja"
                ? LaTeXConverter.japaneseUnreadCommandPrefix : LaTeXConverter.unreadCommandPrefix
            issues.append(prefix + unknownNames.joined(separator: ", "))
        }
        if let style = classInfo.resolvedStyle {
            issues += style.diagnostics.map { "\(style.requestedName): unknown option \($0)" }
        }
        issues.append(contentsOf: failedFormulas)
        if stopsExpanding { issues.append("LaTeX expansion limit reached") }
        return issues
    }

    /// Keep first-use order so a repeated command yields one name and authors can locate it in source order.
    func recordUnknown(_ name: String) {
        if seenUnknown.insert(name).inserted { unknownNames.append(name) }
    }

    var isJapanese: Bool { language == "ja" }

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
        let pictures = pictureHeadings.isEmpty ? html : replacing("P", in: html)
        let body = bibDatabase.printCount > 0 ? replacing("B", in: pictures, bibliography: bibliography) : pictures
        resolveCitations()
        let resolved = replacing("M", in: replacing("C", in: replacing("R", in: replacing("T", in: body))))
        // KOMA records non-Arabic heading numbers in the aux file for the next run.
        guard classInfo.profile.headings.endDots == .automatic else { return resolved }
        return resolved.replacingOccurrences(of: placeholder("D", 0), with: hasNonArabicHeading ? "." : "")
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
        let textual =
            hasDatabaseLabel
            && (["citet", "textcite"].contains(citation.command)
                || citation.command == "cite" && bibDatabase.natbib && authorYear && citation.after == nil
                    && !bibDatabase.parentheticalCite)
        let bare = (hasDatabaseLabel && (authorOnly || yearOnly)) || textual || citation.command == "citealp"
        let square = (!hasDatabaseLabel && !bibDatabase.natbib) || bibDatabase.usesSquareBrackets
        let delimiters = square ? ("[", "]") : ("(", ")")
        let close = bare ? "" : delimiters.1
        // Numeric references stay with their word. Author names and notes can span several lines.
        let breakable = classInfo.profile.body.composesLatinParagraphs && (authorYear || authorOnly || textual)
        let attribute = breakable ? " data-latex-cite-text" : ""
        // natbib.sty's \NAT@aysep\NAT@spacechar ends in a control space even after a comma or “et al.”.
        let normalSpace = breakable && bibDatabase.natbib ? "<span data-latex-control-space> </span>" : " "
        let separatorText = bibDatabase.authorYearSeparator
        let nameYear = separatorText.hasSuffix(" ") ? String(separatorText.dropLast()) + normalSpace : separatorText
        var html = "<span class=\"latex-cite\"\(attribute)>" + (bare ? "" : delimiters.0)
        func add(_ piece: String) -> Bool {
            guard let filled = filled(piece, below: index, limit: limit - html.utf8.count) else { return false }
            html += filled
            return true
        }
        if !textual, let before = citation.before, !before.isEmpty, !add(before + " ") { return nil }
        let compress =
            bibDatabase.natbib && bibDatabase.sortsAndCompresses && !authorYear
            && (!bare || citation.command == "citealp")
        let separator = authorYear && (bibDatabase.natbib || !bare) ? bibDatabase.multipleCitationSeparator : ", "
        let separateBrackets =
            !bare && !authorYear && !bibDatabase.natbib
            ? classInfo.profile.body.citationListSeparator : nil
        let parts: [(key: String, separator: String)]?
        if let separateBrackets {
            let range = classInfo.profile.body.citationRangeSeparator.map { "]" + $0 + "[" }
            parts = sortedNumbers(citation.keys, separator: "]" + separateBrackets + "[", range: range)
        } else {
            parts = compress ? sortedNumbers(citation.keys, separator: ", ", range: "–") : nil
        }
        let count = parts?.count ?? citation.keys.count
        for position in 0..<count {
            let key = parts?[position].key ?? citation.keys[position]
            if position > 0, !add(parts?[position].separator ?? separator) { return nil }
            if let entry = bibliography[key] {
                // The label goes in on its own, so a label too long is turned down before it is copied anywhere.
                func addLinked(_ text: String) -> Bool {
                    entry.id.isEmpty
                        ? add(text)
                        : add("<a href=\"#\(HTML.escape(entry.id))\">") && add(text) && add("</a>")
                }
                if let label = bibDatabase.citationLabels[key], authorOnly || yearOnly || textual {
                    let author = citation.full ? bibDatabase.fullAuthors[key] ?? label.author : label.author
                    if authorOnly {
                        guard addLinked(author) else { return nil }
                    } else if yearOnly {
                        guard addLinked(label.year) else { return nil }
                    } else {
                        let linked = bibDatabase.linksTextualAuthors && authorYear
                        guard linked ? addLinked(author) : add(author), add(normalSpace + delimiters.0) else {
                            return nil
                        }
                        if position == 0, let before = citation.before, !before.isEmpty, !add(before + " ") {
                            return nil
                        }
                        guard addLinked(authorYear ? label.year : entry.label) else { return nil }
                        if position == count - 1, let after = citation.after, !after.isEmpty {
                            guard add(", "), add(after) else { return nil }
                        }
                        guard add(delimiters.1) else { return nil }
                    }
                } else if citation.full, authorYear, let long = bibDatabase.fullAuthors[key],
                    let label = bibDatabase.citationLabels[key]
                {
                    guard addLinked(long + nameYear + label.year) else { return nil }
                } else if breakable && bibDatabase.natbib && authorYear, let label = bibDatabase.citationLabels[key],
                    !label.author.isEmpty,
                    !label.year.isEmpty
                {
                    guard addLinked(label.author + nameYear + label.year) else { return nil }
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

    // Keep the endpoints as keys so each printed number still links to its own bibliography entry.
    private func sortedNumbers(_ keys: [String], separator: String, range: String?) -> [(
        key: String, separator: String
    )] {
        let sorted = keys.map { key in
            (key: key, number: Int(bibliography[key]?.label ?? ""))
        }.sorted { ($0.number ?? .max) < ($1.number ?? .max) }
        var result: [(String, String)] = []
        var i = 0
        while i < sorted.count {
            let start = i
            result.append((sorted[i].key, separator))
            while range != nil, i + 1 < sorted.count, let current = sorted[i].number, current > 0, current < Int.max,
                sorted[i + 1].number == current + 1
            {
                i += 1
            }
            if i > start { result.append((sorted[i].key, i - start >= 2 ? range ?? separator : separator)) }
            i += 1
        }
        return result
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
    fileprivate func replacing(_ kind: String, in html: String, bibliography: String = "", rawText: Bool = false)
        -> String
    {
        guard html.contains("\u{E000}\(nonce)\(kind)"),
            let regex = try? NSRegularExpression(pattern: "\u{E000}\(nonce)\(kind)([0-9]+)\u{E001}")
        else { return html }
        let nsHTML = html as NSString
        var output = ""
        var cursor = 0
        // Four MB allows rendered math and a long contents list. Omit excess contents or abbreviate other output.
        var budget = 4_000_000
        var contents: [Int: String] = [:]
        var repeatedBibliography: String?
        for match in regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            output += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let index = Int(nsHTML.substring(with: match.range(at: 1))) ?? -1
            switch kind {
            case "E":
                if index == 0 {
                    output += String(exam.questions.count)
                } else if index == 1 {
                    output += LaTeXExam.number(exam.total)
                } else {
                    let table = contents[index] ?? exam.tableHTML(index - 2)
                    contents[index] = table
                    if table.utf8.count <= budget {
                        output += table
                        budget -= table.utf8.count
                    } else {
                        output += "…"
                    }
                }
            case "P":
                if let heading = pictureHeadings[index] {
                    output += rawText ? heading : HTML.escape(heading)
                }
            case "B":
                guard !bibliography.isEmpty, bibDatabase.printedHeadings.indices.contains(index) else { continue }
                let header = bibDatabase.printedHeadings[index]
                if header.utf8.count + bibliography.utf8.count <= budget {
                    output += header
                    budget -= header.utf8.count
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
                let toc = contents[index] ?? tableOfContents(index)
                contents[index] = toc
                if toc.utf8.count <= budget {
                    output += toc
                    budget -= toc.utf8.count
                }
            case "C":
                let citation =
                    resolvedCitations.indices.contains(index)
                    ? resolvedCitations[index] : "<span class=\"latex-missing\">?</span>"
                if citation.utf8.count <= budget {
                    if !rawText, classInfo.profile.body.spacesLinkedCounters, language == "ja",
                        citations.indices.contains(index), citations[index].command == "cite"
                    {
                        output += spacedJapaneseLink(citation, in: nsHTML, range: match.range)
                    } else {
                        output += citation
                    }
                    budget -= citation.utf8.count
                } else {
                    output += "<span class=\"latex-cite\">[…]</span>"
                }
            default:
                guard budget > 0 else {
                    output += "…"
                    continue
                }
                let resolved =
                    kind == "M" ? renderFormula(index) : spacedReference(index, in: nsHTML, range: match.range)
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

    enum ContentsList: Equatable {
        case headings(depth: Int, chapterFormat: String?)
        case figures
        case tables
    }

    private var contentsLists: [ContentsList] = []

    func contentsPlaceholder(_ list: ContentsList) -> String {
        if let index = contentsLists.firstIndex(of: list) { return placeholder("T", index) }
        contentsLists.append(list)
        return placeholder("T", contentsLists.count - 1)
    }

    private func tableOfContents(_ index: Int) -> String {
        guard contentsLists.indices.contains(index) else { return "" }
        let entries: [Heading]
        var chapterFormat: String?
        switch contentsLists[index] {
        case .headings(let depth, let format):
            entries = headings.filter { $0.number != nil && $0.level <= depth }
            chapterFormat = format
        case .figures: entries = lists["figure"] ?? []
        case .tables: entries = lists["table"] ?? []
        }
        guard let top = entries.map(\.level).min() else { return "" }
        var html = ""
        var depth = 0
        var open: [Bool] = []
        var lastChapter: Int?
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
            let number =
                entry.number.flatMap { number -> String? in
                    guard !number.isEmpty else { return nil }
                    let formatted =
                        entry.level == 0
                        ? chapterFormat?.replacingOccurrences(of: placeholder("N", 0), with: HTML.escape(number)) : nil
                    return "<span class=\"secnum\">\(formatted ?? entry.chapterLabelHTML ?? HTML.escape(number))</span>"
                } ?? ""
            let kind: String
            switch (contentsLists[index], entry.level) {
            case (.headings, -1): kind = " class=\"latex-toc-part\""
            case (.headings, let index) where LaTeXCounters.levels.indices.contains(index):
                kind = " class=\"latex-toc-\(LaTeXCounters.levels[index])\""
            case (.figures, _), (.tables, _): kind = " class=\"latex-toc-float\""
            default: kind = ""
            }
            let chapterBreak = entry.chapter != nil && lastChapter != nil && entry.chapter != lastChapter
            lastChapter = entry.chapter
            html +=
                "<li\(kind)\(chapterBreak ? " data-latex-list-chapter" : "")><a href=\"#\(HTML.escape(entry.id))\">\(number)\(entry.title)</a>"
            open[open.count - 1] = true
        }
        while depth > 0 {
            if open.removeLast() { html += "</li>" }
            html += "</ul>"
            depth -= 1
        }
        return html
    }

    /// An image's path as written, or with the extension LaTeX would find: graphicx tries several when a file is
    /// named without one, in the document's folder and in `\graphicspath`.
    func imageSource(_ file: String) -> (source: String, url: URL?) {
        guard let directory else { return (file, nil) }
        let names =
            (file as NSString).pathExtension.isEmpty
            ? ["pdf", "png", "jpg", "jpeg", "svg", "gif"].map { file + "." + $0 } : [file]
        for base in searchDirectories {
            for folder in [""] + graphicsPaths {
                for name in names {
                    let url = base.appending(path: folder + name)
                    if imageExists(url) { return (resourceSource(url, relativeTo: directory), url) }
                }
            }
        }
        if let base = inputChain.last?.deletingLastPathComponent() {
            return (resourceSource(base.appending(path: file), relativeTo: directory), nil)
        }
        return (file, nil)
    }

    /// Today's date, as `\today` prints it.
    func today() -> String {
        LaTeXLanguage.today(language, classicBabel: classicBabelLanguages.contains(language))
    }
}

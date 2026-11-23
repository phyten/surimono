import Foundation

public struct HTMLFragment: Equatable, Sendable {
    public var body: String
    public var title: String?
    public var language: String?
    /// Document-level diagnostics that have no position on a printed page.
    public var readingIssues: [String]
    /// The language plain text was told to be when it was converted, for what names it beside the paper.
    public var sourceLanguage: SourceLanguage?
    /// The decoded input associated with these exact pages, including whitespace invisible in a PDF.
    public var sourceText: String?
    // Keeping the full profile inline would reserve its size on the worker stack for each
    // temporary fragment, including the other formats' branches while a nested frame is read.
    private enum DocumentClassStorage: Equatable, Sendable {
        case none
        indirect case latex(LaTeXDocumentClassInfo)
    }

    private var documentClass: DocumentClassStorage = .none
    public var latexClass: LaTeXDocumentClassInfo? {
        get {
            guard case .latex(let info) = documentClass else { return nil }
            return info
        }
        set { documentClass = newValue.map { .latex($0) } ?? .none }
    }

    public init(
        body: String, title: String? = nil, language: String? = nil, readingIssues: [String] = [],
        latexClass: LaTeXDocumentClassInfo? = nil
    ) {
        self.body = body
        self.title = title
        self.language = language
        self.readingIssues = readingIssues
        self.latexClass = latexClass
    }
}

package enum HTML {
    package static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The text `escape(_:)` wrote, and the non-breaking space.
    package static func unescape(_ html: String) -> String {
        html.replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

public enum PlainTextConverter {
    package static let sourceOpen = "<pre class=\"surimono-source\">"

    /// The text as one preformatted block. A file name that tells a programming or configuration language (or, for
    /// a name that tells nothing, a shebang line) colors it; text with no name is never colored.
    public static func convert(_ text: String, fileName: String?) -> HTMLFragment {
        let language = fileName.flatMap { SourceLanguage.detect(fileName: $0, text: { text }) }
        // Code too long to color is shown whole without colors rather than cut.
        let colored = language.flatMap { SyntaxHighlighter.highlight(text, language: $0.id) }
        let opening = language == nil ? "<pre class=\"surimono-plain\">" : sourceOpen
        var fragment = HTMLFragment(body: "\(opening)\(colored ?? HTML.escape(text))</pre>")
        if language != nil { fragment.sourceText = text }
        fragment.sourceLanguage = language
        return fragment
    }

    public static func convert(_ text: String, fileExtension: String? = nil) -> HTMLFragment {
        convert(text, fileName: fileExtension.flatMap { $0.isEmpty ? nil : "file." + $0 })
    }
}

public enum CSVConverter {
    /// The delimiter of a table with no file name to tell it, such as one copied from a spreadsheet. As the
    /// clipboard's detector decides: the delimiter under which every record on its first lines has the same number
    /// of fields, and a tab when both do, so that the commas inside tab-separated cells ("1,200,000") stay data.
    /// When neither is regular, the one that separates more fields.
    public static func guessedDelimiter(of text: String) -> Character {
        let characters = Array(TextDecoding.normalizeNewlines(String(text.prefix(65_536))))
        var commas = 0
        var tabs = 0
        var records: [(commas: Int, tabs: Int)] = []
        var quoted = false
        var field = false
        var blank = true
        var index = 0
        func endRecord() {
            if !blank { records.append((commas, tabs)) }
            commas = 0
            tabs = 0
            blank = true
        }
        // The same reading of quotes as `convert`, so that a delimiter inside a quoted field is not counted.
        while index < characters.count, records.count < 64 {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    index += 1
                } else if quoted || !field {
                    quoted.toggle()
                }
                field = true
                blank = false
            } else if !quoted && (character == "," || character == "\t") {
                if character == "," { commas += 1 } else { tabs += 1 }
                field = false
                blank = false
            } else if !quoted && character == "\n" {
                endRecord()
                field = false
            } else {
                field = true
                if !character.isWhitespace { blank = false }
            }
            index += 1
        }
        if records.count < 64 { endRecord() }
        func regular(_ count: ((commas: Int, tabs: Int)) -> Int) -> Bool {
            guard let first = records.first.map(count), first > 0 else { return false }
            return records.allSatisfy { count($0) == first }
        }
        if regular(\.tabs) { return "\t" }
        if regular(\.commas) { return "," }
        let allTabs = records.reduce(0) { $0 + $1.tabs }
        let allCommas = records.reduce(0) { $0 + $1.commas }
        return allTabs > 0 && allTabs >= allCommas ? "\t" : ","
    }

    public static func convert(_ text: String, delimiter: Character = ",") -> HTMLFragment {
        convert(text, delimiter: delimiter, checkRow: { _ in })
    }

    package static func convert(_ text: String, delimiter: Character, checkRow: (Int) throws -> Void) rethrows
        -> HTMLFragment
    {
        let rows = try records(text, delimiter: delimiter, checkRow: checkRow)
        func render(_ fields: [String], tag: String) -> String {
            "<tr>" + fields.map { "<\(tag)>\(HTML.escape($0))</\(tag)>" }.joined() + "</tr>"
        }
        let head = rows.first.map { render($0, tag: "th") } ?? ""
        let body = rows.dropFirst().map { render($0, tag: "td") }.joined()
        return HTMLFragment(body: "<table class=\"surimono-csv\"><thead>\(head)</thead><tbody>\(body)</tbody></table>")
    }

    static func records(
        _ text: String, delimiter: Character, quote: Character = "\"", skipInitialSpace: Bool = false,
        checkRow: (Int) throws -> Void
    ) rethrows -> [[String]] {
        let characters = TextDecoding.normalizeNewlines(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            characters.formIndex(after: &index)
            if skipInitialSpace, character == " ", field.isEmpty, !quoted { continue }
            if character == quote {
                if quoted && index < characters.endIndex && characters[index] == quote {
                    field.append(quote)
                    characters.formIndex(after: &index)
                } else if quoted || field.isEmpty {
                    quoted.toggle()
                } else {
                    field.append(character)
                }
            } else if character == delimiter && !quoted {
                row.append(field)
                field = ""
            } else if character == "\n" && !quoted {
                row.append(field)
                try checkRow(rows.count + 1)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
        }
        if !characters.isEmpty && (characters.last != "\n" || quoted || !row.isEmpty || !field.isEmpty) {
            row.append(field)
            try checkRow(rows.count + 1)
            rows.append(row)
        }
        return rows
    }
}

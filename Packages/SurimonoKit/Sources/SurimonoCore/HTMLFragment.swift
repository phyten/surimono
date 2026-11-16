import Foundation

public struct HTMLFragment: Equatable, Sendable {
    public var body: String
    public var title: String?

    public init(body: String, title: String? = nil) {
        self.body = body
        self.title = title
    }
}

enum HTML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The text `escape(_:)` wrote, and the non-breaking space.
    static func unescape(_ html: String) -> String {
        html.replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

public enum PlainTextConverter {
    public static func convert(_ text: String) -> HTMLFragment {
        HTMLFragment(body: "<pre class=\"surimono-plain\">\(HTML.escape(text))</pre>")
    }
}

public enum CSVConverter {
    /// The delimiter of a table with no file name to tell it, such as one copied from a spreadsheet: a tab when tabs
    /// separate at least as many fields as commas on its first lines, as the clipboard's detector decides.
    public static func guessedDelimiter(of text: String) -> Character {
        let characters = Array(TextDecoding.normalizeNewlines(String(text.prefix(65_536))))
        var commas = 0
        var tabs = 0
        var quoted = false
        var field = false
        var lines = 0
        var index = 0
        // The same reading of quotes as `convert`, so that a delimiter inside a quoted field is not counted.
        while index < characters.count, lines < 64 {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    index += 1
                } else if quoted || !field {
                    quoted.toggle()
                }
                field = true
            } else if !quoted && (character == "," || character == "\t") {
                if character == "," { commas += 1 } else { tabs += 1 }
                field = false
            } else if !quoted && character == "\n" {
                lines += 1
                field = false
            } else {
                field = true
            }
            index += 1
        }
        return tabs > 0 && tabs >= commas ? "\t" : ","
    }

    public static func convert(_ text: String, delimiter: Character = ",") -> HTMLFragment {
        let characters = Array(TextDecoding.normalizeNewlines(text))
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
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
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index += 1
        }
        if !characters.isEmpty && (characters.last != "\n" || quoted || !row.isEmpty || !field.isEmpty) {
            row.append(field)
            rows.append(row)
        }
        func render(_ fields: [String], tag: String) -> String {
            "<tr>" + fields.map { "<\(tag)>\(HTML.escape($0))</\(tag)>" }.joined() + "</tr>"
        }
        let head = rows.first.map { render($0, tag: "th") } ?? ""
        let body = rows.dropFirst().map { render($0, tag: "td") }.joined()
        return HTMLFragment(body: "<table class=\"surimono-csv\"><thead>\(head)</thead><tbody>\(body)</tbody></table>")
    }
}

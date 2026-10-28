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
}

public enum PlainTextConverter {
    public static func convert(_ text: String) -> HTMLFragment {
        HTMLFragment(body: "<pre class=\"surimono-plain\">\(HTML.escape(text))</pre>")
    }
}

public enum CSVConverter {
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

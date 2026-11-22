import Foundation

extension RSTDocument {
    func rstTableDirective(_ directive: RSTDirective) -> String? {
        let caption = directive.argument.isEmpty ? "" : "<caption>\(inline(directive.argument))</caption>"
        if directive.name == "table" {
            var html = blocks(directive.lines)
            guard html.hasPrefix("<table"), let end = html.firstIndex(of: ">") else { return nil }
            html.insert(contentsOf: caption, at: html.index(after: end))
            return html
        }
        var headers = max(0, Int(directive.options["header-rows"] ?? "") ?? 0)
        let rows: [[[String]]]
        if directive.name == "list-table" {
            guard let cells = rstListRows(directive.lines) else { return nil }
            rows = cells
        } else {
            var source = directive.lines.joined(separator: "\n")
            if let path = directive.options["file"] {
                guard let file = rstFile(path), let text = rstRead(file) else { return nil }
                source = text
            }
            guard directive.options["url"] == nil else { return nil }
            let delimiter = directive.options["delim"] ?? directive.options["delimiter"] ?? ","
            let separator = delimiter == "tab" || delimiter == "\\t" ? "\t" : delimiter
            guard separator.count == 1, let character = separator.first else { return nil }
            let quote = (directive.options["quote"] ?? "\"").first ?? "\""
            func cells(_ csv: String) -> [[[String]]] {
                CSVConverter.records(
                    csv, delimiter: character, quote: quote, skipInitialSpace: directive.options["keepspace"] == nil
                ) { _ in }.map { row in
                    row.map { $0.rstStripped.components(separatedBy: "\n") }
                }
            }
            let headingRows = directive.options["header"].map(cells) ?? []
            let data = cells(source)
            guard headers <= data.count else { return nil }
            headers += headingRows.count
            rows = headingRows + data
        }
        guard !rows.isEmpty, headers <= rows.count else { return nil }
        let columns = rows.map(\.count).max() ?? 0
        // Padding sparse CSV input must not turn a short source into an arbitrarily large rectangular table.
        guard columns > 0, rows.count <= 120_000 / columns else { return nil }
        let stubs = max(0, Int(directive.options["stub-columns"] ?? "") ?? 0)
        var head = ""
        var body = ""
        for (index, row) in rows.enumerated() {
            var line = "<tr>"
            for column in 0..<columns {
                let tag = index < headers || column < stubs ? "th" : "td"
                line += "<\(tag)>\(column < row.count ? blocks(row[column]) : "")</\(tag)>"
            }
            line += "</tr>"
            if index < headers { head += line } else { body += line }
        }
        return "<table>\(caption)" + (head.isEmpty ? "" : "<thead>\(head)</thead>") + "<tbody>\(body)</tbody></table>"
    }

    /// A list-table is exactly two bullet-list levels. Indentation inside each cell belongs to its body parser.
    private func rstListRows(_ lines: [String]) -> [[[String]]]? {
        func item(_ line: String) -> (String, Int)? {
            guard let marker = line.first, "*-+".contains(marker), line.count == 1 || line.dropFirst().first == " "
            else {
                return nil
            }
            let padding = max(1, line.dropFirst().prefix(while: { $0 == " " }).count)
            return (String(line.dropFirst(padding + 1)), padding + 1)
        }
        var rows: [[[String]]] = []
        var row: [[String]] = []
        var cell: [String] = []
        var itemIndent = 0
        var cellIndent = 0
        for line in lines {
            if line.isEmpty {
                cell.append("")
            } else if let (first, prefix) = item(line) {
                if !cell.isEmpty {
                    row.append(cell)
                    cell = []
                }
                if !row.isEmpty {
                    rows.append(row)
                    row = []
                }
                guard let (text, offset) = item(first) else { return nil }
                itemIndent = prefix
                cellIndent = prefix + offset
                cell = [text]
            } else if line.rstIndent == itemIndent, let (text, prefix) = item(line.rstStripped) {
                row.append(cell)
                cell = [text]
                cellIndent = itemIndent + prefix
            } else if !cell.isEmpty, line.rstIndent >= cellIndent {
                cell.append(String(line.dropFirst(cellIndent)))
            } else {
                return nil
            }
        }
        if !cell.isEmpty { row.append(cell) }
        if !row.isEmpty { rows.append(row) }
        guard let columns = rows.first?.count, rows.allSatisfy({ $0.count == columns }) else { return nil }
        return rows
    }

    func rstCode(_ lines: [String], language: String, options: [String: String]) -> String {
        let numbered = options["number-lines"] != nil || options["linenos"] != nil
        let emphasized = options["emphasize-lines"] ?? ""
        let first = max(1, min(Int(options["number-lines"] ?? "") ?? 1, Int.max - lines.count))
        let code = lines.joined(separator: "\n")
        let languageClass =
            language.isEmpty ? " class=\"rst-plain-code\"" : " class=\"language-\(HTML.escape(language)) hl\""
        func codeText(_ source: String) -> String {
            guard !language.isEmpty else { return HTML.escape(source) }
            return SyntaxHighlighter.highlight(source, language: language) ?? HTML.escape(source)
        }
        var output: String
        if numbered || !emphasized.isEmpty {
            var selected = IndexSet()
            for range in emphasized.split(separator: ",") {
                let limits = range.split(separator: "-", maxSplits: 1).compactMap { Int(String($0).rstStripped) }
                if let lower = limits.first, let upper = limits.last, lower > 0, lower <= upper, upper <= lines.count {
                    selected.insert(integersIn: lower...upper)
                }
            }
            let body = lines.enumerated().map { index, line in
                var source = codeText(line)
                if selected.contains(index + 1) { source = "<mark>\(source)</mark>" }
                let mark = numbered ? "<small class=\"ln\">\(first + index) </small>" : ""
                return mark + source
            }.joined(separator: "\n")
            // The author selected line numbers here independently of the user's global numbering preference.
            output = "<pre class=\"rst-listing\"><code\(languageClass)>\(body)</code></pre>"
        } else {
            output =
                "<pre><code\(languageClass)>\(codeText(code))</code></pre>"
        }
        if let title = options["caption"] {
            return "<figure><figcaption>\(inline(title))</figcaption>\(output)</figure>"
        }
        return output
    }
}

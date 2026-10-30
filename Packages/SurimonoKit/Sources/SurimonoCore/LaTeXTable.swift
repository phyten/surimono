import Foundation

/// A `tabular` as an HTML table: column alignment and vertical rules from the column specification, rows split at
/// `\\`, cells at `&`, horizontal rules from `\hline` and booktabs, and `\multicolumn` and `\multirow`.
struct LaTeXTable {
    private struct Column {
        var alignment = "left"
        var ruleLeft = false
        var ruleRight = false
    }

    private enum Rule {
        case thin
        case thick

        var css: String { self == .thick ? "1pt solid currentColor" : "0.5pt solid currentColor" }
    }

    private struct Row {
        var cells: [String] = []
        var ruleAbove: Rule?
        var ruleBelow: Rule?
        /// Columns (1-based, inclusive) of `\cline` and `\cmidrule` above the row.
        var partialRules: [ClosedRange<Int>] = []
        var isHeader = false
    }

    let spec: String
    let body: String

    func html(inline: (String) -> String) -> String {
        var budget = Self.maximumColumns
        let columns = Self.columns(Array(spec), budget: &budget)
        let rows = self.rows()
        var pendingRowspans: [Int: Int] = [:]
        var html = "<table class=\"latex-tabular\"><tbody>\n"
        for row in rows {
            var column = 0
            var cells = ""
            for source in row.cells {
                if let remaining = pendingRowspans[column], remaining > 0 {
                    // The cell under a \multirow is left empty in the source and taken by the span.
                    pendingRowspans[column] = remaining - 1
                    column += 1
                    continue
                }
                let cell = Self.cell(source.trimmingCharacters(in: .whitespacesAndNewlines))
                let format = column < columns.count ? columns[column] : Column()
                var style = ["text-align: \(cell.alignment ?? format.alignment)"]
                if format.ruleLeft && column == 0 { style.append("border-left: \(Rule.thin.css)") }
                let last = column + cell.columns - 1
                let lastFormat = last < columns.count ? columns[last] : Column()
                if lastFormat.ruleRight || (last + 1 < columns.count && columns[last + 1].ruleLeft) {
                    style.append("border-right: \(Rule.thin.css)")
                }
                let above =
                    row.ruleAbove
                    ?? (row.partialRules.contains { $0.contains(column + 1) || $0.contains(last + 1) } ? .thin : nil)
                if let above { style.append("border-top: \(above.css)") }
                if let below = row.ruleBelow { style.append("border-bottom: \(below.css)") }
                let tag = row.isHeader ? "th" : "td"
                var attributes = " style=\"\(style.joined(separator: "; "))\""
                if cell.columns > 1 { attributes += " colspan=\"\(cell.columns)\"" }
                if cell.rows > 1 {
                    attributes += " rowspan=\"\(cell.rows)\""
                    pendingRowspans[column] = cell.rows - 1
                }
                cells += "<\(tag)\(attributes)>\(inline(cell.content))</\(tag)>"
                column += cell.columns
            }
            html += "<tr>\(cells)</tr>\n"
        }
        return html + "</tbody></table>\n"
    }

    /// More columns than any page holds; the specification stops growing there, so nested `*{100}{…}` stays small.
    private static let maximumColumns = 200

    /// Real specifications nest `*{…}{…}` once or twice; deeper groups are skipped rather than copied again.
    private static let maximumDepth = 8

    private static func columns(_ spec: [Character], budget: inout Int, depth: Int = 0) -> [Column] {
        var columns: [Column] = []
        var ruleBefore = false
        var index = 0
        func group() -> String {
            guard index < spec.count, spec[index] == "{" else { return "" }
            var depth = 0
            var text = ""
            while index < spec.count {
                let character = spec[index]
                index += 1
                if character == "{" {
                    depth += 1
                    if depth == 1 { continue }
                }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                text.append(character)
            }
            return text
        }
        while index < spec.count {
            let character = spec[index]
            index += 1
            switch character {
            case "|":
                if columns.isEmpty || ruleBefore {
                    ruleBefore = true
                } else {
                    columns[columns.count - 1].ruleRight = true
                }
            case "l", "c", "r", "p", "m", "b", "X", "S", "L", "C", "R", "J":
                var column = Column()
                column.alignment =
                    switch character {
                    case "c", "C", "S": "center"
                    case "r", "R": "right"
                    default: "left"
                    }
                if "pmb".contains(character) { _ = group() }
                column.ruleLeft = ruleBefore
                ruleBefore = false
                guard budget > 0 else { break }
                budget -= 1
                columns.append(column)
            case "@", "!", ">", "<":
                _ = group()
            case "*":
                let count = Int(group().trimmingCharacters(in: .whitespaces)) ?? 0
                let inner = group()
                guard depth < maximumDepth else { break }
                // Read once, then copied while the budget lasts.
                let repeated = Self.columns(Array(inner), budget: &budget, depth: depth + 1)
                for _ in 1..<max(min(count, maximumColumns), 1) where budget >= repeated.count && !repeated.isEmpty {
                    budget -= repeated.count
                    columns += repeated
                }
                if count >= 1 { columns += repeated }
            default:
                break
            }
        }
        if ruleBefore, !columns.isEmpty { columns[columns.count - 1].ruleRight = true }
        return columns
    }

    private func rows() -> [Row] {
        var rows: [Row] = []
        var carriedRule: Rule?
        var sawMidrule = false
        for source in Self.split(body, at: ["\\\\", "\\tabularnewline"]) {
            var text = Substring(source)
            var row = Row()
            // Rules written before a row's cells belong above it; a source row of rules alone goes under the last.
            while true {
                text = text.drop(while: { $0.isWhitespace })
                if let rest = Self.dropping("\\hline", from: text) {
                    row.ruleAbove = .thin
                    text = rest
                } else if let rest = Self.dropping("\\toprule", from: text) {
                    row.ruleAbove = .thick
                    text = Self.droppingOptional(rest)
                } else if let rest = Self.dropping("\\midrule", from: text) {
                    row.ruleAbove = .thin
                    text = Self.droppingOptional(rest)
                    // booktabs puts the head above the first \midrule.
                    if !sawMidrule {
                        sawMidrule = true
                        for index in rows.indices { rows[index].isHeader = true }
                    }
                } else if let rest = Self.dropping("\\bottomrule", from: text) {
                    row.ruleAbove = .thick
                    text = Self.droppingOptional(rest)
                } else if let rest = Self.dropping("\\cline", from: text) ?? Self.dropping("\\cmidrule", from: text) {
                    var after = Self.droppingOptional(rest.drop(while: { $0 == " " }))
                    if after.first == "(", let close = after.firstIndex(of: ")") {
                        after = after[after.index(after: close)...]
                    }
                    if after.first == "{", let close = after.firstIndex(of: "}") {
                        let range = after[after.index(after: after.startIndex)..<close].split(separator: "-")
                        if range.count == 2, let first = Int(range[0]), let last = Int(range[1]), first <= last {
                            row.partialRules.append(first...last)
                        }
                        after = after[after.index(after: close)...]
                    }
                    text = after
                } else if let rest = Self.dropping("\\addlinespace", from: text) {
                    text = Self.droppingOptional(rest)
                } else {
                    break
                }
            }
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty {
                if rows.isEmpty {
                    carriedRule = row.ruleAbove ?? carriedRule
                } else if let rule = row.ruleAbove {
                    rows[rows.count - 1].ruleBelow = rule
                }
                continue
            }
            if row.ruleAbove == nil { row.ruleAbove = carriedRule }
            carriedRule = nil
            row.cells = Self.split(content, at: ["&"])
            rows.append(row)
        }
        return rows
    }

    private static func dropping(_ command: String, from text: Substring) -> Substring? {
        guard text.hasPrefix(command) else { return nil }
        let rest = text.dropFirst(command.count)
        if let next = rest.first, next.isASCII, next.isLetter { return nil }
        return rest
    }

    private static func droppingOptional(_ text: Substring) -> Substring {
        let trimmed = text.drop(while: { $0 == " " })
        guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { return text }
        return trimmed[trimmed.index(after: close)...]
    }

    /// The source split at separators outside braces; escaped characters do not separate.
    private static func split(_ text: String, at separators: [String]) -> [String] {
        let characters = Array(text)
        let separators = separators.map(Array.init)
        var parts: [String] = []
        var current: [Character] = []
        var depth = 0
        var index = 0
        outer: while index < characters.count {
            let character = characters[index]
            if character == "%" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "\\", let opaque = LaTeXLexer.opaqueEnd(characters, at: index) {
                // `\verb|a&b|` in a cell is code, not a column separator.
                let end = max(opaque, index + 1)
                current.append(contentsOf: characters[index..<end])
                index = end
                continue
            }
            if depth == 0 {
                for separator in separators
                where index + separator.count <= characters.count
                    && Array(characters[index..<(index + separator.count)]) == separator
                {
                    // `\tabularnewline` must not split inside a longer command name.
                    let end = index + separator.count
                    if separator.count > 2, end < characters.count, characters[end].isASCII, characters[end].isLetter {
                        continue
                    }
                    parts.append(String(current))
                    current = []
                    index = end
                    continue outer
                }
            }
            if character == "\\", index + 1 < characters.count {
                current += [character, characters[index + 1]]
                index += 2
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            current.append(character)
            index += 1
        }
        parts.append(String(current))
        return parts
    }

    private struct Cell {
        var content: String
        var columns = 1
        var rows = 1
        var alignment: String?
    }

    /// `\multicolumn{n}{spec}{text}` and `\multirow{n}{width}{text}` around a cell's text.
    private static func cell(_ source: String) -> Cell {
        let reader = Arguments(source)
        if reader.take("\\multicolumn") {
            let count = Int(reader.group().trimmingCharacters(in: .whitespaces)) ?? 1
            var budget = 1
            let spec = columns(Array(reader.group()), budget: &budget)
            var inner = cell(reader.group())
            inner.columns = min(max(count, 1), 100)
            inner.alignment = spec.first?.alignment
            return inner
        }
        if reader.take("\\multirow") {
            reader.optional()
            let count = Int(reader.group().trimmingCharacters(in: .whitespaces)) ?? 1
            reader.optional()
            _ = reader.group()
            reader.optional()
            var inner = cell(reader.group())
            inner.rows = min(max(count, 1), 1000)
            return inner
        }
        return Cell(content: source)
    }

    /// Reads a command's groups from the start of a cell.
    private final class Arguments {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) { characters = Array(text) }

        func take(_ command: String) -> Bool {
            let word = Array(command)
            guard characters.count >= word.count, Array(characters[0..<word.count]) == word else { return false }
            index = word.count
            return true
        }

        func optional() {
            skipSpaces()
            guard index < characters.count, characters[index] == "[" else { return }
            while index < characters.count, characters[index] != "]" { index += 1 }
            index += 1
        }

        func group() -> String {
            skipSpaces()
            guard index < characters.count else { return "" }
            guard characters[index] == "{" else {
                index += 1
                return String(characters[index - 1])
            }
            var depth = 0
            var text = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "{" {
                    depth += 1
                    if depth == 1 { continue }
                }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                text.append(character)
            }
            return text
        }

        private func skipSpaces() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }
    }
}

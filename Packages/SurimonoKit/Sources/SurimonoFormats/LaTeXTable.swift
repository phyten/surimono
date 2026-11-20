import Foundation

/// A `tabular` as an HTML table: column alignment and vertical rules from the column specification, rows split at
/// `\\`, cells at `&`, horizontal rules from `\hline` and booktabs, and `\multicolumn` and `\multirow`.
struct LaTeXTable {
    private struct Column {
        var alignment = "start"
        var noLeadingSpace = false
        var noTrailingSpace = false
        var ruleLeft = false
        var ruleRight = false
        var paragraph: Character?
        var width: String?
        var bold = false
    }

    private struct Decoration {
        var alignment: String?
        var bold = false

        mutating func read(_ source: String) {
            // Execute no column preamble code. Only its alignment and bold declarations describe printed cells.
            for token in source.split(whereSeparator: { !$0.isLetter }) {
                switch token {
                case "centering", "Centering": alignment = "center"
                case "raggedleft", "RaggedLeft": alignment = "end"
                case "raggedright", "RaggedRight": alignment = "start"
                case "bfseries", "bf": bold = true
                default: break
                }
            }
        }

        func apply(to column: inout Column) {
            if let alignment { column.alignment = alignment }
            if bold { column.bold = true }
        }
    }

    private enum Rule {
        case thin
        case thick
        case mid
        case double

        var printedKind: String? {
            switch self {
            case .thin: nil
            case .thick: "heavy"
            case .mid: "light"
            case .double: "double"
            }
        }

        var isBooktabs: Bool { self == .thick || self == .mid }

        static let thinCSS = "0.5pt solid currentColor"
    }

    private struct Row {
        var cells: [String] = []
        var ruleAbove: Rule?
        var ruleBelow: Rule?
        /// Columns (1-based, inclusive) of `\cline` and `\cmidrule` above the row.
        var partialRules: [(columns: ClosedRange<Int>, rule: Rule)] = []
        var hasBooktabsAbove: Bool { ruleAbove?.isBooktabs == true || partialRules.contains { $0.rule.isBooktabs } }
        var extraDepth: String?
        var isHeader = false
        var background: (spec: String, model: String?)?
    }

    let spec: String
    let body: String
    var basicBidi = false
    var isLongtable = false
    var targetWidth: String?
    var columnTypes: [Character: String] = [:]

    static let spacingRegisters: Set<String> = ["tabcolsep", "ltleft", "ltright", "ltpre", "ltpost"]
    var spacing: [String: String] = [:]
    var arrayStretch: Double?
    var extraRowHeight: String?
    var japaneseSize: String?
    var japaneseMetrics: LaTeXLabelMetrics?

    private func trackWidth(_ css: String) -> String {
        guard japaneseMetrics != nil, css.hasSuffix("%"), let percent = Double(css.dropLast()) else { return css }
        // A TeX paragraph column resolves linewidth against the enclosing text, even in
        // a naturally sized longtable. CSS percentages alone refer to the table itself.
        return "calc(\(LaTeXPageSettings.number(percent / 100)) * var(--latex-table-measure, 100%))"
    }

    func html(
        color: (String, String?) -> String? = { LaTeXSymbols.cssColor($0, model: $1, defined: [:]) },
        inline: (String) -> String
    ) -> String {
        var budget = Self.maximumColumns
        var aliasBudget = 32_768
        let columns = Self.columns(Array(spec), budget: &budget, aliases: columnTypes, aliasBudget: &aliasBudget)
        let flexible = columns.filter { $0.paragraph == "X" }.count
        let tableWidth = flexible == 0 ? nil : targetWidth
        let rows = self.rows()
        var pendingRowspans: [Int: Int] = [:]
        var head = ""
        var bodyHTML = ""
        var captions = ""
        for (index, row) in rows.enumerated() {
            if isLongtable, Self.isCaption(row) {
                captions += inline(row.cells[0]) + "\n"
                continue
            }
            let rowBackground = row.background.flatMap { color($0.spec, $0.model) }
            var column = 0
            var cells = ""
            for source in row.cells {
                if let remaining = pendingRowspans[column], remaining > 0 {
                    // The cell under a \multirow is left empty in the source and taken by the span.
                    pendingRowspans[column] = remaining - 1
                    column += 1
                    continue
                }
                let cell = Self.cell(
                    source.trimmingCharacters(in: .whitespacesAndNewlines), aliases: columnTypes,
                    aliasBudget: &aliasBudget)
                let format = cell.columnFormat ?? (column < columns.count ? columns[column] : Column())
                var style = ["text-align: \(format.alignment)"]
                if let vertical = cell.vertical {
                    style.append("vertical-align: \(vertical)")
                } else if let column = format.paragraph, column != "X" {
                    // General themes can use native cell alignment. The class sheet sets the baseline
                    // shared by the paragraph boxes and supplies their internal reference lines.
                    let fallback = column == "m" ? "middle" : column == "b" ? "bottom" : "top"
                    style.append("vertical-align: var(--latex-cell-align, \(fallback))")
                }
                if let width = format.width.map(trackWidth) {
                    style.append("width: \(width)")
                    if tableWidth != nil { style.append("min-width: \(width)") }
                }
                if format.noLeadingSpace { style.append("padding-inline-start: 0") }
                if format.bold { style.append("font-weight: bold") }
                if let value = cell.background.flatMap({ color($0.spec, $0.model) }) ?? rowBackground {
                    style.append("background-color: \(value)")
                }
                if format.ruleLeft && column == 0 { style.append("border-left: \(Rule.thinCSS)") }
                let last = column + cell.columns - 1
                let lastFormat = last < columns.count ? columns[last] : Column()
                if lastFormat.noTrailingSpace { style.append("padding-inline-end: 0") }
                if lastFormat.ruleRight || (last + 1 < columns.count && columns[last + 1].ruleLeft) {
                    style.append("border-right: \(Rule.thinCSS)")
                }
                let above =
                    row.ruleAbove ?? row.partialRules.first { $0.columns.overlaps((column + 1)...(last + 1)) }?.rule
                var ruleClasses: [String] = []
                // A closing rule also crosses columns occupied by a cell from an earlier row.
                let finalRow = index + min(cell.rows - 1, rows.count - 1 - index)
                for (edge, rule) in [("top", above), ("bottom", rows[finalRow].ruleBelow)] {
                    guard let rule else { continue }
                    if let kind = rule.printedKind {
                        ruleClasses.append("latex-\(edge)-\(kind)")
                    } else {
                        style.append("border-\(edge): \(Rule.thinCSS)")
                    }
                }
                let tag = row.isHeader ? "th" : "td"
                let direction = basicBidi ? " dir=\"rtl\"" : ""
                let columnType = format.paragraph.map { " data-latex-column=\"\($0)\"" } ?? ""
                var attributes = "\(direction)\(columnType) style=\"\(style.joined(separator: "; "))\""
                if !ruleClasses.isEmpty { attributes += " class=\"\(ruleClasses.joined(separator: " "))\"" }
                if cell.columns > 1 { attributes += " colspan=\"\(cell.columns)\"" }
                if cell.rows > 1 {
                    attributes += " rowspan=\"\(cell.rows)\""
                    pendingRowspans[column] = cell.rows - 1
                }
                var contents = cell.isPlainText ? HTML.escape(cell.content) : inline(cell.content)
                if format.paragraph == "m", cell.vertical == nil {
                    contents = "<span class=\"latex-middle-cell\"><span>\(contents)</span></span>"
                } else if format.paragraph == "b", cell.vertical == nil {
                    contents = "<span class=\"latex-bottom-cell\">\(contents)</span>"
                }
                cells += "<\(tag)\(attributes)>\(contents)</\(tag)>"
                column += cell.columns
            }
            // The white space on either side of a booktabs rule belongs to the adjacent text rows.
            // This also works when a longtable's midrule is the final token in its repeated heading.
            var spacing = ""
            if row.hasBooktabsAbove || (index > 0 && rows[index - 1].ruleBelow?.isBooktabs == true) {
                spacing += " latex-below-rule"
            }
            if row.ruleBelow?.isBooktabs == true || (index + 1 < rows.count && rows[index + 1].hasBooktabsAbove) {
                spacing += " latex-above-rule"
            }
            let attr = spacing.isEmpty ? "" : " class=\"\(spacing.dropFirst())\""
            let depth = row.extraDepth.map { " style=\"--latex-row-skip: \($0)\"" } ?? ""
            let rowHTML = "<tr\(attr)\(depth)>\(cells)</tr>\n"
            if isLongtable && row.isHeader { head += rowHTML } else { bodyHTML += rowHTML }
        }
        let thead = head.isEmpty ? "" : "<thead>\n\(head)</thead>"
        let cssClass = isLongtable ? "latex-tabular latex-longtable" : "latex-tabular"
        let spacingCSS = LaTeXPageSettings.cssVariables(spacing)
        var strut = spacingCSS.isEmpty ? [] : [spacingCSS]
        if let japaneseSize, let pitch = japaneseMetrics?.baseline(for: japaneseSize) {
            strut += [
                "font-size: var(--latex-size-\(japaneseSize))",
                "--latex-array-baseline: \(LaTeXPageSettings.number(pitch))",
            ]
        }
        if let arrayStretch, arrayStretch.isFinite, arrayStretch > 0, arrayStretch <= 100 {
            strut.append("--latex-arraystretch: \(LaTeXPageSettings.number(arrayStretch))")
        }
        if let extraRowHeight { strut.append("--latex-extrarowheight: \(extraRowHeight)") }
        if let tableWidth {
            strut += ["width: \(tableWidth)", "--latex-x-share: \(LaTeXPageSettings.number(100 / Double(flexible)))%"]
        }
        // A grid of paragraph columns has no natural-width cells to measure. Give the fixed
        // tracks their entire outer widths and let the remaining X tracks share the difference.
        let paragraphGrid = tableWidth != nil && columns.allSatisfy { $0.paragraph == "X" || $0.width != nil }
        let tracks =
            paragraphGrid
            ? "<colgroup>"
                + columns.enumerated().map { index, column in
                    let pads = (column.noLeadingSpace ? 0 : 1) + (column.noTrailingSpace ? 0 : 1)
                    let rules =
                        (index == 0 && column.ruleLeft ? 1 : 0)
                        + (column.ruleRight || (index + 1 < columns.count && columns[index + 1].ruleLeft) ? 1 : 0)
                    guard let width = column.width.map(trackWidth) else { return "<col>" }
                    return
                        "<col style=\"width: calc(\(width) + \(pads) * var(--latex-tabcolsep, calc(6 * var(--tex-pt))) + \(rules) * .4 * var(--tex-pt))\">"
                }.joined() + "</colgroup>" : ""
        let sized = tableWidth == nil ? "" : " data-latex-tabularx"
        let style = strut.isEmpty ? "" : " style=\"\(strut.joined(separator: "; "))\""
        // babel's basic bidi mode leaves the TeX alignment grid LTR; each entry still reads RTL.
        let direction = basicBidi ? " dir=\"ltr\"" : ""
        let html =
            "<table\(direction) class=\"\(cssClass)\"\(sized)\(style)>\(tracks)\(thead)<tbody>\n\(bodyHTML)</tbody></table>\n"
        let wrapper = spacingCSS.isEmpty ? "" : " style=\"\(spacingCSS)\""
        return captions.isEmpty
            ? html : "<figure class=\"latex-table latex-longtable\"\(wrapper)>\n\(captions)\(html)</figure>\n"
    }

    /// More columns than any page holds; the specification stops growing there, so nested `*{100}{…}` stays small.
    private static let maximumColumns = 200

    /// Real specifications nest `*{…}{…}` once or twice; deeper groups are skipped rather than copied again.
    private static let maximumDepth = 8

    private static func columns(
        _ spec: [Character], budget: inout Int, aliases: [Character: String], aliasBudget: inout Int, depth: Int = 0
    ) -> [Column] {
        var columns: [Column] = []
        var ruleBefore = false
        var suppressLeadingSpace = false
        var decoration = Decoration()
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
            if let alias = aliases[character] {
                // Bound both deep aliases and wide trees of aliases which produce no columns.
                let cost = alias.utf8.count + 1
                guard budget > 0, depth < maximumDepth, cost <= aliasBudget else { continue }
                aliasBudget -= cost
                var added = Self.columns(
                    Array(alias), budget: &budget, aliases: aliases, aliasBudget: &aliasBudget, depth: depth + 1)
                if !added.isEmpty {
                    if suppressLeadingSpace { added[0].noLeadingSpace = true }
                    suppressLeadingSpace = false
                    decoration.apply(to: &added[0])
                    if ruleBefore { added[0].ruleLeft = true }
                    ruleBefore = false
                    decoration = Decoration()
                    columns += added
                }
                continue
            }
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
                    case "r", "R": "end"
                    case "p", "m", "b", "X": "justify"
                    default: "start"
                    }
                if "pmbX".contains(character) { column.paragraph = character }
                if "pmb".contains(character) { column.width = LaTeXSymbols.printLength(group()) }
                decoration.apply(to: &column)
                decoration = Decoration()
                column.noLeadingSpace = suppressLeadingSpace
                suppressLeadingSpace = false
                column.ruleLeft = ruleBefore
                ruleBefore = false
                guard budget > 0 else { break }
                budget -= 1
                columns.append(column)
            case ">":
                decoration.read(group())
            case "<":
                var after = Decoration()
                after.read(group())
                if !columns.isEmpty { after.apply(to: &columns[columns.count - 1]) }
            case "@", "!":
                let material = group()
                if character == "@", material.isEmpty {
                    suppressLeadingSpace = true
                    if !columns.isEmpty { columns[columns.count - 1].noTrailingSpace = true }
                }
            case "*":
                let count = Int(group().trimmingCharacters(in: .whitespaces)) ?? 0
                let inner = group()
                guard depth < maximumDepth else { break }
                // Read once, then copied while the budget lasts.
                var repeated = Self.columns(
                    Array(inner), budget: &budget, aliases: aliases, aliasBudget: &aliasBudget, depth: depth + 1)
                let first = repeated.first
                if count > 0, !repeated.isEmpty, suppressLeadingSpace {
                    repeated[0].noLeadingSpace = true
                    suppressLeadingSpace = false
                }
                for _ in 1..<max(min(count, maximumColumns), 1) where budget >= repeated.count && !repeated.isEmpty {
                    budget -= repeated.count
                    columns += repeated
                    if let first { repeated[0] = first }
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
        guard isLongtable else { return rows(in: body).rows }
        let boundaries = ["\\endfirsthead", "\\endhead", "\\endfoot", "\\endlastfoot"]
        let parts = LaTeXLexer.split(body, at: boundaries, keepingSeparators: true, protectingEnvironments: true)
        var sections: [String: String] = [:]
        var content = ""
        for part in parts {
            if boundaries.contains(part) {
                sections[part] = content
                content = ""
            } else {
                content += part
            }
        }
        // WebKit prints the thead only once. Prefer the actual first-page heading (even an
        // explicitly empty one), so a "continued" caption cannot displace the original.
        let header = sections["\\endfirsthead"] ?? sections["\\endhead"]
        var headRows = rows(in: header ?? "", detectHeader: false).rows
        for index in headRows.indices { headRows[index].isHeader = true }
        var bodyRows = rows(in: content, detectHeader: header == nil).rows
        if let foot = sections["\\endlastfoot"] ?? sections["\\endfoot"], !bodyRows.isEmpty {
            // Continuation text is page-specific. Only its full-width closing rule belongs
            // to the continuous HTML table, on the last body row exactly once.
            let footer = rows(in: foot, detectHeader: false)
            if let rule = footer.trailingRule ?? footer.rows.reversed().lazy.compactMap(\.ruleAbove).first {
                bodyRows[bodyRows.count - 1].ruleBelow = rule
            }
        }
        return headRows + bodyRows
    }

    private static func isCaption(_ row: Row) -> Bool {
        row.cells.count == 1
            && dropping("\\caption", from: row.cells[0].trimmingCharacters(in: .whitespacesAndNewlines)[...]) != nil
    }

    private func rows(in body: String, detectHeader: Bool = true) -> (rows: [Row], trailingRule: Rule?) {
        var rows: [Row] = []
        var carriedRule: Rule?
        var sawMidrule = false
        let sources = LaTeXLexer.split(body, at: ["\\\\", "\\tabularnewline"], protectingEnvironments: true)
        for (i, source) in sources.enumerated() {
            var text = Substring(source)
            if i > 0 {
                if text.first == "*" { text = text.dropFirst() }
                let trimmed = text.drop(while: { $0.isWhitespace })
                if trimmed.first == "[", let end = trimmed.firstIndex(of: "]"),
                    let depth = LaTeXSymbols.printLength(
                        String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]))
                {
                    if !rows.isEmpty { rows[rows.count - 1].extraDepth = depth }
                    text = trimmed[trimmed.index(after: end)...]
                }
            }
            var row = Row()
            // Rules written before a row's cells belong above it; a source row of rules alone goes under the last.
            while true {
                text = text.drop(while: { $0.isWhitespace })
                if let rest = Self.dropping("\\rowcolor", from: text) {
                    let background = Self.tableColor(rest)
                    row.background = background.color
                    text = background.rest
                } else if let rest = Self.dropping("\\hline", from: text) {
                    row.ruleAbove = row.ruleAbove == nil ? .thin : .double
                    text = rest
                } else if let rest = Self.dropping("\\toprule", from: text) {
                    row.ruleAbove = .thick
                    text = Self.droppingOptional(rest)
                } else if let rest = Self.dropping("\\midrule", from: text) {
                    row.ruleAbove = .mid
                    text = Self.droppingOptional(rest)
                    // booktabs puts the head above the first \midrule.
                    if detectHeader, !sawMidrule {
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
                            row.partialRules.append((first...last, text.hasPrefix("\\cmidrule") ? .mid : .thin))
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
            row.cells = LaTeXLexer.split(content, at: ["&"], protectingEnvironments: true)
            rows.append(row)
        }
        return (rows, rows.last?.ruleBelow ?? carriedRule)
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

    private struct Cell {
        var vertical: String?
        var content: String
        var isPlainText = false
        var background: (spec: String, model: String?)?
        var columns = 1
        var rows = 1
        var columnFormat: Column?
    }

    /// `\multicolumn{n}{spec}{text}` and `\multirow{n}{width}{text}` around a cell's text.
    private static func cell(_ source: String, aliases: [Character: String], aliasBudget: inout Int, depth: Int = 0)
        -> Cell
    {
        // Preserve excessive nesting as text without sending it into another recursive parser.
        guard depth < 32 else { return Cell(content: source, isPlainText: true) }
        if source.contains("\\cellcolor") {
            // colortbl accepts the declaration after the cell text too. Keep verbatim examples and
            // nested groups opaque; multicolumn and multirow will inspect their own inner cells.
            let parts = LaTeXLexer.split(
                source, at: ["\\cellcolor"], keepingSeparators: true, protectingEnvironments: true)
            if parts.count > 1 {
                var content = parts[0]
                var color: (String, String?)?
                for index in stride(from: 2, to: parts.count, by: 2) {
                    let parsed = tableColor(parts[index][...])
                    color = parsed.color ?? color
                    content += parsed.rest
                }
                var inner = cell(
                    content.trimmingCharacters(in: .whitespacesAndNewlines), aliases: aliases,
                    aliasBudget: &aliasBudget, depth: depth + 1)
                inner.background = color ?? inner.background
                return inner
            }
        }
        let reader = Arguments(source)
        if reader.take("\\multicolumn") {
            let count = Int(reader.group().trimmingCharacters(in: .whitespaces)) ?? 1
            var budget = 1
            let spec = columns(Array(reader.group()), budget: &budget, aliases: aliases, aliasBudget: &aliasBudget)
            var inner = cell(reader.group(), aliases: aliases, aliasBudget: &aliasBudget, depth: depth + 1)
            inner.columns = min(max(count, 1), 100)
            inner.columnFormat = spec.first
            return inner
        }
        if reader.take("\\multirow") {
            let position = reader.optional()
            let count = Int(reader.group().trimmingCharacters(in: .whitespaces)) ?? 1
            reader.optional()
            _ = reader.group()
            reader.optional()
            var inner = cell(reader.group(), aliases: aliases, aliasBudget: &aliasBudget, depth: depth + 1)
            inner.rows = min(max(count, 1), 1000)
            inner.vertical = position == "t" ? "top" : position == "b" ? "bottom" : "middle"
            return inner
        }
        return Cell(content: source)
    }

    /// colortbl accepts an optional xcolor model and two optional overhang lengths. The latter
    /// need no HTML equivalent; preserving them as cell text would print TeX dimensions on the page.
    private static func tableColor(_ input: Substring) -> (color: (String, String?)?, rest: Substring) {
        var rest = input.drop(while: { $0.isWhitespace })
        func optional() -> String? {
            guard rest.first == "[", let end = rest.firstIndex(of: "]") else { return nil }
            let value = String(rest[rest.index(after: rest.startIndex)..<end])
            rest = rest[rest.index(after: end)...].drop(while: { $0.isWhitespace })
            return value
        }
        let model = optional()
        guard rest.first == "{", let end = rest.firstIndex(of: "}") else { return (nil, rest) }
        let spec = String(rest[rest.index(after: rest.startIndex)..<end])
        rest = rest[rest.index(after: end)...].drop(while: { $0.isWhitespace })
        _ = optional()
        _ = optional()
        return ((spec, model), rest)
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

        @discardableResult
        func optional() -> String? {
            skipSpaces()
            guard index < characters.count, characters[index] == "[" else { return nil }
            index += 1
            let start = index
            while index < characters.count, characters[index] != "]" { index += 1 }
            let option = String(characters[start..<index])
            guard index < characters.count else { return nil }
            index += 1
            return option
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

import Foundation

extension ClipboardScanners {
    static func latex(_ window: ClipboardWindow, level: ClipboardFormatSettings.Carefulness, work: inout ClipboardWork)
        -> ClipboardCandidate
    {
        var candidate = ClipboardCandidate(kind: .latex)
        work.visit(window.bytes.count)
        guard window.bytes.contains(92) else { return candidate }
        let b = window.bytes
        var i = 0
        var stack: [String] = []
        var braces = 0
        var commands = 0
        var allCommands = 0
        var starts = false
        var prefix = false
        var document = false
        var running: [UInt8] = []
        running.reserveCapacity(b.count)
        var textStart = 0
        var mathDepth = 0
        var mathDelimiter: Int?
        let structural: Set<String> = [
            "documentclass", "begin", "section", "subsection", "subsubsection", "chapter", "paragraph", "title",
            "newcommand", "def", "usepackage", "item", "maketitle", "tableofcontents",
        ]
        func string(_ range: Range<Int>) -> String { String(decoding: b[range], as: UTF8.self) }
        func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        while i < b.count {
            work.visit()
            if b[i] == 37 {
                let beforeComment = ClipboardSlice(b, textStart..<i)
                if !starts && !beforeComment.trimmed.isEmpty { prefix = true }
                running.append(contentsOf: b[beforeComment.range])
                while i < b.count && b[i] != 10 {
                    work.visit()
                    i += 1
                }
                textStart = i
                continue
            }
            if b[i] == 92 {
                let preceding = ClipboardSlice(b, textStart..<i)
                if !starts && !preceding.trimmed.isEmpty { prefix = true }
                if mathDepth == 0 { running.append(contentsOf: b[preceding.range]) }
                i += 1
                let start = i
                while i < b.count && letter(b[i]) {
                    work.visit()
                    i += 1
                }
                let name = string(start..<i)
                if name.isEmpty {
                    if i < b.count && (b[i] == 91 || b[i] == 93) {
                        mathDepth = b[i] == 91 ? mathDepth + 1 : max(0, mathDepth - 1)
                    }
                    i = min(i + 1, b.count)
                    textStart = i
                    continue
                }
                allCommands += 1
                if structural.contains(name) {
                    commands += 1
                    starts = true
                }
                if ["documentclass", "section", "subsection", "newcommand"].contains(name) {
                    var next = i
                    while next < b.count && (b[next] == 32 || b[next] == 10) {
                        next += 1
                        work.visit()
                    }
                    if next == b.count || (b[next] != 123 && b[next] != 91 && b[next] != 42) {
                        candidate.accepted = false
                    }
                }
                if name == "documentclass" { document = true }
                if name == "verb" || name == "lstinline" {
                    if i < b.count && b[i] == 42 { i += 1 }
                    if i < b.count {
                        let delimiter = b[i]
                        i += 1
                        while i < b.count && b[i] != delimiter && b[i] != 10 {
                            work.visit()
                            i += 1
                        }
                        if i == b.count || b[i] != delimiter { candidate.accepted = false } else { i += 1 }
                    } else {
                        candidate.accepted = false
                    }
                } else if name == "begin" || name == "end" {
                    while i < b.count && (b[i] == 32 || b[i] == 10) {
                        work.visit()
                        i += 1
                    }
                    if i < b.count && b[i] == 123 {
                        i += 1
                        let envStart = i
                        while i < b.count && b[i] != 125 && b[i] != 10 {
                            work.visit()
                            i += 1
                        }
                        let env = string(envStart..<i)
                        if env.utf8.count > 64
                            || !env.utf8.allSatisfy({ letter($0) || (48...57).contains($0) || $0 == 42 })
                        {
                            candidate.accepted = false
                        }
                        if i == b.count || b[i] != 125 { candidate.accepted = false } else { i += 1 }
                        if name == "end" {
                            if [
                                "equation", "equation*", "align", "align*", "aligned", "displaymath", "math",
                                "tikzpicture", "tabular",
                            ].contains(env) {
                                mathDepth = max(0, mathDepth - 1)
                            }
                            if stack.last == env { stack.removeLast() } else { candidate.accepted = false }
                        } else if LaTeXLexer.verbatimEnvironments.contains(env) {
                            let close = Array("\\end{\(env)}".utf8)
                            var closed = false
                            while i < b.count {
                                work.visit()
                                if b[i] == 92 && token(b, i, close, work: &work) {
                                    i += close.count
                                    closed = true
                                    break
                                }
                                i += 1
                            }
                            if !closed { candidate.accepted = false }
                        } else {
                            stack.append(env)
                            if [
                                "equation", "equation*", "align", "align*", "aligned", "displaymath", "math",
                                "tikzpicture", "tabular",
                            ].contains(env) {
                                mathDepth += 1
                            }
                        }
                    } else {
                        candidate.accepted = false
                    }
                }
                textStart = i
                continue
            }
            if b[i] == 36 {
                if mathDelimiter == nil && mathDepth == 0 {
                    let beforeMath = ClipboardSlice(b, textStart..<i)
                    if !starts && !beforeMath.trimmed.isEmpty { prefix = true }
                    running.append(contentsOf: b[beforeMath.range])
                }
                let width = i + 1 < b.count && b[i + 1] == 36 ? 2 : 1
                if let open = mathDelimiter {
                    if open == width { mathDelimiter = nil } else { candidate.accepted = false }
                } else {
                    mathDelimiter = width
                }
                i += width
                textStart = i
                continue
            }
            if mathDelimiter != nil {
                i += 1
                textStart = i
                continue
            }
            if b[i] == 123 { braces += 1 }
            if b[i] == 125 {
                braces -= 1
                if braces < 0 { candidate.accepted = false }
            }
            i += 1
        }
        if mathDepth == 0 { running.append(contentsOf: b[textStart..<b.count]) }
        candidate.structures = commands > 0 ? commands : (allCommands >= 2 && b.contains(123) ? 1 : 0)
        candidate.strength = document ? 95 : 65
        candidate.ownsStart = !prefix && starts
        candidate.accepted =
            candidate.accepted && !prefix && braces == 0 && stack.isEmpty && mathDelimiter == nil && mathDepth == 0
        for i in running.indices where running[i] == 123 || running[i] == 125 { running[i] = 32 }
        candidate.accepted = candidate.accepted && !unsafeText(running, work: &work)
        let required = level == .careful ? 4 : (level == .standard ? 2 : 1)
        candidate.sufficient = document || commands >= required || (commands >= 1 && allCommands >= 4)
        candidate.evidence = [.markup(commands)]
        if document { candidate.evidence.append(.document) }
        if !candidate.accepted { candidate.evidence.append(.conflictingSyntax) }
        return candidate
    }

    private struct TableField {
        var range: Range<Int>
        var count = 0
        var first: UInt8?
        var japanesePeriod = false
        var periodSpace = false
        var periodNewline = false
    }

    private struct TableScan {
        var fields: [TableField] = []
        var rows: [Range<Int>] = []
        var closed = true
        var valid = true
        var quoted = false
        var delimiters = 0
    }

    private static func table(_ bytes: [UInt8], delimiter: UInt8, collect: Bool, work: inout ClipboardWork) -> TableScan
    {
        var result = TableScan()
        var rowStart = 0
        var fieldStart = 0
        var fieldEnd: Int?
        var field = TableField(range: 0..<0)
        var previous: UInt8 = 0
        var penultimate: UInt8 = 0
        var inQuote = false
        var afterQuote = false
        var rowPresent = false
        var i = 0
        func appendField(_ end: Int) {
            if collect {
                field.range = fieldStart..<(fieldEnd ?? end)
                result.fields.append(field)
            }
            fieldEnd = nil
            field = TableField(range: 0..<0)
            previous = 0
            penultimate = 0
        }
        func content(_ b: UInt8) {
            if !collect { return }
            if field.first == nil { field.first = b }
            field.count += 1
            if previous == 46 && b == 32 { field.periodSpace = true }
            if previous == 46 && b == 10 { field.periodNewline = true }
            if penultimate == 227 && previous == 128 && b == 130 { field.japanesePeriod = true }
            penultimate = previous
            previous = b
        }
        while i < bytes.count {
            work.visit()
            let b = bytes[i]
            i += 1
            if inQuote {
                if b == 34 {
                    if i < bytes.count && bytes[i] == 34 {
                        content(34)
                        i += 1
                        work.visit()
                    } else {
                        inQuote = false
                        afterQuote = true
                        fieldEnd = i - 1
                    }
                } else {
                    content(b)
                }
            } else if b == delimiter {
                appendField(i - 1)
                fieldStart = i
                afterQuote = false
                rowPresent = true
                result.delimiters += 1
            } else if b == 10 {
                if rowPresent {
                    appendField(i - 1)
                    if collect { result.rows.append(rowStart..<result.fields.count) }
                }
                rowStart = result.fields.count
                fieldStart = i
                fieldEnd = nil
                field = TableField(range: 0..<0)
                previous = 0
                penultimate = 0
                afterQuote = false
                rowPresent = false
            } else if b == 34 {
                if i - 1 == fieldStart && !afterQuote {
                    inQuote = true
                    result.quoted = true
                    fieldStart = i
                    rowPresent = true
                } else {
                    result.valid = false
                    content(b)
                    rowPresent = true
                }
            } else {
                if afterQuote { result.valid = false }
                content(b)
                rowPresent = true
            }
        }
        if rowPresent {
            appendField(i)
            if collect { result.rows.append(rowStart..<result.fields.count) }
        }
        result.closed = !inQuote
        return result
    }

    private static func numeric(_ field: ClipboardSlice) -> Bool {
        let value = field.trimmed
        guard let first = value.first else { return false }
        // Double accepts signed decimal/hexadecimal numbers, infinities and NaNs. Only decoding
        // plausible numeric fields avoids Foundation/String work for every ordinary text cell.
        switch first {
        case 43, 45, 46, 48...57, 73, 78, 105, 110: return Double(value.string) != nil
        default: return false
        }
    }

    static func csv(
        _ window: ClipboardWindow, hints: ClipboardFormatHints, level: ClipboardFormatSettings.Carefulness,
        work: inout ClipboardWork
    ) -> ClipboardCandidate {
        let bytes = window.bytes
        var result = ClipboardCandidate(kind: .csv)
        result.delimiter = ","
        work.visit(bytes.count)
        guard bytes.contains(44) || bytes.contains(9) else { return result }
        // Count with the same quote automaton for both separators; collect ranges only for the winner.
        let comma = table(bytes, delimiter: 44, collect: false, work: &work)
        let tab = table(bytes, delimiter: 9, collect: false, work: &work)
        let useTab = tab.delimiters > 0 && tab.delimiters >= comma.delimiters
        let parsed = table(bytes, delimiter: useTab ? 9 : 44, collect: true, work: &work)
        result.delimiter = useTab ? "\t" : ","
        let rows = parsed.rows
        guard parsed.delimiters > 0, rows.count >= 2 || hints.hasTabularData else { return result }
        let columns = rows.first?.count ?? 0
        result.ownsStart = columns >= 2
        result.structures = rows.count
        result.strength = 70
        var ambiguous = false
        var hasNumeric = false
        var spaced = 0
        var groupedRows = 0
        var numericRows = 0
        var rectangular = true
        var multiRows = 0
        var allTrailingEmpty = true
        var hasJapanesePeriod = false
        var sentence = false
        var shortHeader = columns >= 2
        for (rowIndex, row) in rows.enumerated() {
            work.visit(row.count)
            if row.count != columns { rectangular = false }
            if row.count >= 2 { multiRows += 1 }
            if useTab && parsed.fields[row.lowerBound].count == 0 { ambiguous = true }
            if parsed.fields[row.upperBound - 1].count != 0 { allTrailingEmpty = false }
            var allNumeric = true
            for index in row {
                let field = parsed.fields[index]
                let value = ClipboardSlice(bytes, field.range)
                work.visit(value.count)
                let number = !parsed.quoted && numeric(value)
                hasNumeric = hasNumeric || number
                allNumeric = allNumeric && number
                if field.first == 32 { spaced += 1 }
                let japanese = field.japanesePeriod
                let periodSpace = field.periodSpace
                hasJapanesePeriod = hasJapanesePeriod || japanese
                sentence = sentence || japanese || periodSpace || field.periodNewline
                if rowIndex == 0 && (field.count >= 100 || japanese || periodSpace) {
                    shortHeader = false
                }
                if !parsed.quoted && value.contains(";") {
                    var start = field.range.lowerBound
                    var seen = false
                    for end in field.range.lowerBound...field.range.upperBound
                    where end == field.range.upperBound || bytes[end] == 59 {
                        if seen && numeric(ClipboardSlice(bytes, start..<end)) { ambiguous = true }
                        start = end + 1
                        seen = true
                    }
                }
            }
            if !useTab && !parsed.quoted {
                if allNumeric { numericRows += 1 }
                let joined = ClipboardSlice(
                    bytes,
                    parsed.fields[row.lowerBound].range.lowerBound..<parsed.fields[row.upperBound - 1].range.upperBound)
                if let first = joined.first,
                    first == 43 || first == 45 || first == 36 || first >= 128 || (48...57).contains(first)
                {
                    if matches(joined, #"^[+$€£¥-]?\d{1,3}(?:,\d{2,3})+(?:\.\d+)?$"#, work: &work) { groupedRows += 1 }
                }
                if joined.contains("St") || joined.contains("Rd") || joined.contains("Ro") || joined.contains("Av")
                    || joined.contains("La") || joined.contains("Ln") || joined.contains("Dr")
                {
                    if matches(
                        joined, #"\b(?:Street|St\.?|Road|Rd\.?|Avenue|Ave\.?|Lane|Ln\.?|Drive|Dr\.?)\b"#, work: &work)
                    {
                        ambiguous = true
                    }
                }
            }
        }
        if !useTab && !parsed.quoted && spaced >= rows.count { ambiguous = true }
        if !useTab && !parsed.quoted && !hasNumeric { ambiguous = true }
        if groupedRows == rows.count || numericRows == rows.count { ambiguous = true }
        if !useTab && (!shortHeader || multiRows < 2) { result.structures = 0 }
        if columns == 1 && rows.count >= 4
            && rows.dropFirst().allSatisfy({ $0.count == rows[1].count && $0.count >= 2 })
        {
            result.structures = rows.count
        }
        if useTab && columns == 1 { result.structures = 0 }
        if !useTab && !parsed.quoted && allTrailingEmpty { result.structures = 0 }
        if !useTab && !parsed.quoted && !hasNumeric && hasJapanesePeriod { result.structures = 0 }
        if !useTab && !parsed.quoted {
            if sentence {
                ambiguous = true
                if !rectangular { result.structures = 0 }
            }
            if spaced >= rows.count && !rectangular { result.structures = 0 }
        }
        result.accepted = rectangular && columns >= 2 && parsed.valid && parsed.closed && !ambiguous
        let required = level == .careful ? 4 : 3
        result.sufficient = rows.count >= required || hints.hasTabularData
        result.evidence = [.tables(1)]
        if hints.hasTabularData { result.evidence.append(.pasteboard) }
        if !parsed.closed { result.evidence.append(.incomplete) }
        if ambiguous { result.evidence.append(.conflictingSyntax) }
        return result
    }
}

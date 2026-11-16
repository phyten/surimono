import Foundation

extension ClipboardScanners {
    static func latex(_ window: ClipboardWindow, level: ClipboardFormatSettings.Carefulness, work: inout ClipboardWork)
        -> ClipboardCandidate
    {
        var candidate = ClipboardCandidate(kind: .latex)
        let b = window.bytes
        var i = 0
        var stack: [String] = []
        var braces = 0
        var commands = 0
        var allCommands = 0
        var starts = false
        var prefix = false
        var document = false
        var running = ""
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
                let beforeComment = string(textStart..<i)
                if !starts && !trimmed(beforeComment).isEmpty { prefix = true }
                running += beforeComment
                while i < b.count && b[i] != 10 {
                    work.visit()
                    i += 1
                }
                textStart = i
                continue
            }
            if b[i] == 92 {
                let preceding = string(textStart..<i)
                if !starts && !trimmed(preceding).isEmpty { prefix = true }
                if mathDepth == 0 { running += preceding }
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
                    let beforeMath = string(textStart..<i)
                    if !starts && !trimmed(beforeMath).isEmpty { prefix = true }
                    running += beforeMath
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
        if mathDepth == 0 { running += string(textStart..<b.count) }
        candidate.structures = commands > 0 ? commands : (allCommands >= 2 && window.text.contains("{") ? 1 : 0)
        candidate.strength = document ? 95 : 65
        candidate.ownsStart = !prefix && starts
        candidate.accepted =
            candidate.accepted && !prefix && braces == 0 && stack.isEmpty && mathDelimiter == nil && mathDepth == 0
        let plain = running.replacingOccurrences(of: "{", with: " ").replacingOccurrences(of: "}", with: " ")
        candidate.accepted = candidate.accepted && !unsafeText(plain, work: &work)
        let required = level == .careful ? 4 : (level == .standard ? 2 : 1)
        candidate.sufficient = document || commands >= required || (commands >= 1 && allCommands >= 4)
        candidate.evidence = [.markup(commands)]
        if document { candidate.evidence.append(.document) }
        if !candidate.accepted { candidate.evidence.append(.conflictingSyntax) }
        return candidate
    }

    private struct TableScan: Sendable {
        var rows: [[String]] = []
        var closed = true
        var valid = true
        var quoted = false
        var delimiters = 0
    }

    private static func table(_ bytes: [UInt8], delimiter: UInt8, work: inout ClipboardWork) -> TableScan {
        var result = TableScan()
        var row: [String] = []
        var field: [UInt8] = []
        var inQuote = false
        var afterQuote = false
        var rowPresent = false
        var i = 0
        func value(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
        while i < bytes.count {
            work.visit()
            let b = bytes[i]
            i += 1
            if inQuote {
                if b == 34 {
                    if i < bytes.count && bytes[i] == 34 {
                        field.append(34)
                        i += 1
                        work.visit()
                    } else {
                        inQuote = false
                        afterQuote = true
                    }
                } else {
                    field.append(b)
                }
            } else if b == delimiter {
                row.append(value(field))
                field = []
                afterQuote = false
                rowPresent = true
                result.delimiters += 1
            } else if b == 10 {
                if rowPresent || !field.isEmpty || !row.isEmpty {
                    row.append(value(field))
                    result.rows.append(row)
                }
                row = []
                field = []
                afterQuote = false
                rowPresent = false
            } else if b == 34 {
                if field.isEmpty && !afterQuote {
                    inQuote = true
                    result.quoted = true
                    rowPresent = true
                } else {
                    result.valid = false
                    field.append(b)
                }
            } else {
                if afterQuote { result.valid = false }
                field.append(b)
                rowPresent = true
            }
        }
        if rowPresent || !field.isEmpty || !row.isEmpty {
            row.append(value(field))
            result.rows.append(row)
        }
        result.closed = !inQuote
        return result
    }

    static func csv(
        _ window: ClipboardWindow, hints: ClipboardFormatHints, level: ClipboardFormatSettings.Carefulness,
        work: inout ClipboardWork
    ) -> ClipboardCandidate {
        let comma = table(window.bytes, delimiter: 44, work: &work)
        let tab = table(window.bytes, delimiter: 9, work: &work)
        let useTab = tab.delimiters > 0 && tab.delimiters >= comma.delimiters
        let parsed = useTab ? tab : comma
        var result = ClipboardCandidate(kind: .csv)
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
        for row in rows {
            work.visit(row.count)
            if row.count != columns { result.accepted = false }
            if useTab && row.first == "" { ambiguous = true }
            for field in row {
                work.visit(field.utf8.count)
                if !parsed.quoted && field.contains(";") {
                    let pieces = field.split(separator: ";", omittingEmptySubsequences: false)
                    if pieces.dropFirst().contains(where: { Double(trimmed(String($0))) != nil }) { ambiguous = true }
                }
                if Double(trimmed(field)) != nil { hasNumeric = true }
                if field.hasPrefix(" ") { spaced += 1 }
            }
            if !useTab && !parsed.quoted {
                let joined = row.joined(separator: ",")
                if row.allSatisfy({ Double(trimmed($0)) != nil }) { numericRows += 1 }
                if matches(joined, #"^[+$€£¥-]?\d{1,3}(?:,\d{2,3})+(?:\.\d+)?$"#, work: &work) { groupedRows += 1 }
                if matches(
                    joined, #"\b(?:Street|St\.?|Road|Rd\.?|Avenue|Ave\.?|Lane|Ln\.?|Drive|Dr\.?)\b"#, work: &work)
                {
                    ambiguous = true
                }
            }
        }
        if !useTab && !parsed.quoted && spaced >= rows.count { ambiguous = true }
        if !useTab && !parsed.quoted && !hasNumeric { ambiguous = true }
        if groupedRows == rows.count || numericRows == rows.count { ambiguous = true }
        let header = rows.first ?? []
        let shortHeader =
            header.count >= 2 && header.allSatisfy { $0.utf8.count < 100 && !$0.contains("。") && !$0.contains(". ") }
        let multiRows = rows.filter { $0.count >= 2 }.count
        if !useTab && (!shortHeader || multiRows < 2) { result.structures = 0 }
        if columns == 1 && rows.count >= 4
            && rows.dropFirst().allSatisfy({ $0.count == rows[1].count && $0.count >= 2 })
        {
            result.structures = rows.count
        }
        if useTab && columns == 1 { result.structures = 0 }
        if !useTab && !parsed.quoted && rows.allSatisfy({ $0.last == "" }) { result.structures = 0 }
        if !useTab && !parsed.quoted && !hasNumeric
            && rows.contains(where: { $0.contains(where: { $0.contains("。") }) })
        {
            result.structures = 0
        }
        if !useTab && !parsed.quoted {
            let sentence = rows.contains { row in
                row.contains { $0.contains("。") || $0.contains(". ") || $0.contains(".\n") }
            }
            if sentence {
                ambiguous = true
                if !rows.allSatisfy({ $0.count == columns }) { result.structures = 0 }
            }
            if spaced >= rows.count && !rows.allSatisfy({ $0.count == columns }) { result.structures = 0 }
        }
        result.accepted = result.accepted && columns >= 2 && parsed.valid && parsed.closed && !ambiguous
        let required = level == .careful ? 4 : 3
        result.sufficient = rows.count >= required || hints.hasTabularData
        result.evidence = [.tables(1)]
        if hints.hasTabularData { result.evidence.append(.pasteboard) }
        if !parsed.closed { result.evidence.append(.incomplete) }
        if ambiguous { result.evidence.append(.conflictingSyntax) }
        return result
    }
}

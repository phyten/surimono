import Foundation

struct TikZError: Error {
    let feature: String

    init(_ feature: String) {
        self.feature = String(feature.prefix(160))
    }
}

// Keep groups intact: a label, a formula or a nested style can contain a comma, semicolon or closing bracket.
struct TikZScanner {
    var tail: Substring

    init(_ source: String) { tail = source[...] }

    mutating func space() { tail = tail.drop(while: { $0.isWhitespace }) }

    mutating func take(_ prefix: String) -> Bool {
        space()
        guard tail.hasPrefix(prefix) else { return false }
        tail = tail.dropFirst(prefix.count)
        return true
    }

    mutating func word() throws -> String {
        space()
        let name = tail.prefix(while: { $0.isASCII && $0.isLetter })
        guard !name.isEmpty else { throw TikZError(String(tail.prefix(24))) }
        tail = tail[name.endIndex...]
        return String(name)
    }

    mutating func group(_ opening: Character, _ closing: Character) throws -> String {
        guard take(String(opening)) else { throw TikZError(String(tail.prefix(24))) }
        var depth = 1
        var braces = 0
        var escaped = false
        for i in tail.indices {
            let c = tail[i]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if opening != "{", c == "{" {
                braces += 1
            } else if opening != "{", c == "}" {
                braces -= 1
                guard braces >= 0 else { throw TikZError("}") }
            } else if braces == 0 {
                if c == opening { depth += 1 }
                if c == closing { depth -= 1 }
                if depth == 0 {
                    let content = String(tail[..<i])
                    tail = tail[tail.index(after: i)...]
                    return content
                }
            }
        }
        throw TikZError(String(opening))
    }

    mutating func options() throws -> String {
        space()
        return tail.first == "[" ? try group("[", "]") : ""
    }

    /// Braced labels can themselves contain line breaks. Only outer ampersands and double backslashes
    /// delimit cells and rows. Empty cells have different naming rules in PGF and are outside this subset.
    static func matrixRows(_ source: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var start = source.startIndex
        var i = start
        var depth = 0
        var count = 0
        func finishCell(_ end: String.Index) throws {
            let cell = String(source[start..<end]).tikzTrimmed
            guard !cell.isEmpty, cell.first != "|", cell.first != "[", row.count < 64, count < 256 else {
                throw TikZError("matrix cell")
            }
            count += 1
            row.append(cell)
        }
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            if c == "\\" {
                guard next < source.endIndex else { throw TikZError("matrix row") }
                let after = source.index(after: next)
                if depth == 0, source[next] == "\\" {
                    try finishCell(i)
                    guard rows.count < 64, rows.first.map({ $0.count == row.count }) ?? true else {
                        throw TikZError("matrix columns")
                    }
                    rows.append(row)
                    row = []
                    start = after
                }
                i = after
                continue
            }
            if c == "&", depth == 0 {
                try finishCell(i)
                start = next
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                guard depth >= 0 else { throw TikZError("matrix cell") }
            }
            i = next
        }
        guard !rows.isEmpty, row.isEmpty, depth == 0, source[start...].allSatisfy(\.isWhitespace) else {
            throw TikZError("matrix row")
        }
        return rows
    }

    static func split(_ source: String, at separator: Character) throws -> [String] {
        var braces = 0
        var brackets = 0
        var parentheses = 0
        var escaped = false
        var parts: [String] = []
        var start = source.startIndex
        for i in source.indices {
            let c = source[i]
            if escaped {
                escaped = false
                continue
            }
            if c == "\\" {
                escaped = true
                continue
            }
            if c == "{" { braces += 1 }
            if c == "}" { braces -= 1 }
            if braces == 0 {
                if c == "(" { parentheses += 1 }
                if c == ")" { parentheses -= 1 }
                if c == "[" { brackets += 1 }
                if c == "]" { brackets -= 1 }
                if c == separator, brackets == 0, parentheses == 0 {
                    parts.append(String(source[start..<i]).tikzTrimmed)
                    start = source.index(after: i)
                }
            }
            guard min(braces, brackets, parentheses) >= 0 else { throw TikZError(String(c)) }
        }
        guard braces == 0, brackets == 0, parentheses == 0 else { throw TikZError(String(source.prefix(32))) }
        parts.append(String(source[start...]).tikzTrimmed)
        return parts
    }
}

extension String {
    var tikzTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var tikzUnbraced: String {
        var reader = TikZScanner(tikzTrimmed)
        if reader.tail.first == "{", let value = try? reader.group("{", "}"), reader.tail.isEmpty {
            return value.tikzTrimmed
        }
        return tikzTrimmed
    }
}

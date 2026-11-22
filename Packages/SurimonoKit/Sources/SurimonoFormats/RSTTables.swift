import Foundation

extension RSTBlockReader {
    func table() -> String? {
        let first = lines[index]
        if first.hasPrefix("+-"), first.last == "+", first.allSatisfy({ $0 == "+" || $0 == "-" }) {
            let start = index
            while index < lines.count, lines[index].hasPrefix("|") || lines[index].hasPrefix("+") { index += 1 }
            let source = Array(lines[start..<index])
            return gridTable(source) ?? brokenTable(source)
        }
        guard first.first == "=", first.contains(" "), first.allSatisfy({ $0 == "=" || $0 == " " }) else { return nil }
        let start = index
        guard let lastBorder = simpleEnds[start], lastBorder > start + 1 else {
            return brokenTable(nonblank())
        }
        index = lastBorder + 1
        return simpleTable(Array(lines[start..<index]))
    }

    /// Pair borders in one backward pass. Repeated malformed borders must not each rescan the remaining file.
    func indexSimpleTables() -> [Int: Int] {
        var nearest: [String: Int] = [:]
        var closing: [String: Int] = [:]
        var ends: [Int: Int] = [:]
        for i in lines.indices.reversed() {
            let line = lines[i]
            guard line.first == "=", line.contains(" "), line.allSatisfy({ $0 == "=" || $0 == " " }) else { continue }
            let key = line.rstStripped
            if let end = closing[key] ?? nearest[key] { ends[i] = end }
            nearest[key] = i
            if i + 1 == lines.count || Self.blank(lines[i + 1]) { closing[key] = i }
        }
        return ends
    }

    private func brokenTable(_ source: [String]) -> String {
        document.issueCount += 1
        return "<pre>\(HTML.escape(source.joined(separator: "\n")))</pre>"
    }

    /// An empty slot is the second column occupied by an East Asian wide character.
    private static func columns(_ line: String) -> [String] {
        var result: [String] = []
        for ch in line {
            result.append(String(ch))
            if let value = ch.unicodeScalars.first?.value {
                switch value {
                case 0x1100...0x115f, 0x2e80...0xa4cf, 0xac00...0xd7a3, 0xf900...0xfaff, 0xfe10...0xfe19,
                    0xfe30...0xfe6f, 0xff01...0xff60, 0xffe0...0xffe6, 0x20000...0x3fffd:
                    result.append("")
                default: break
                }
            }
        }
        return result
    }

    private func cell(_ lines: [String], header: Bool, columns: Int = 1, rows: Int = 1) -> String {
        let content = lines.map { String($0.reversed().drop(while: { $0 == " " }).reversed()) }
        let indent = content.lazy.filter { !$0.isEmpty }.map(\.rstIndent).min() ?? 0
        let body = document.blocks(content.map { String($0.dropFirst(indent)) })
        let tag = header ? "th" : "td"
        let colspan = columns > 1 ? " colspan=\"\(columns)\"" : ""
        let rowspan = rows > 1 ? " rowspan=\"\(rows)\"" : ""
        return "<\(tag)\(colspan)\(rowspan)>\(body)</\(tag)>"
    }

    private func gridTable(_ source: [String]) -> String? {
        let grid = source.map(Self.columns)
        guard grid.count >= 3, let top = grid.first, let bottom = grid.last, bottom.last == "+",
            bottom.allSatisfy({ $0 == "+" || $0 == "-" }), grid.allSatisfy({ $0.count == top.count })
        else { return nil }
        var edges: Set<Int> = []
        var dividers: [Int] = []
        var headerEnd: Int?
        for (row, line) in grid.enumerated() {
            var boundary = false
            for col in line.indices where line[col] == "+" {
                let before = col > 0 ? line[col - 1] : ""
                let after = col + 1 < line.count ? line[col + 1] : ""
                if before == "-" || before == "=" || after == "-" || after == "=" {
                    edges.insert(col)
                    boundary = true
                }
            }
            if boundary {
                dividers.append(row)
                if line.contains("="), line.allSatisfy({ $0 == "+" || $0 == "=" }) { headerEnd = row }
            }
        }
        let x = edges.sorted()
        guard x.count >= 2, dividers.count >= 2, x.first == 0, x.last == top.count - 1,
            dividers.first == 0, dividers.last == grid.count - 1
        else { return nil }
        let count = x.count - 1
        var coveredUntil = [Int](repeating: 0, count: count)
        var head = ""
        var body = ""
        for r in 0..<(dividers.count - 1) {
            let y = dividers[r]
            let header = y < (headerEnd ?? 0)
            guard y + 1 < dividers[r + 1] else { return nil }
            var row = "<tr>"
            var col = 0
            while col < count {
                guard coveredUntil[col] <= r else {
                    col += 1
                    continue
                }
                var right = col + 1
                while right < count, grid[y + 1][x[right]] != "|" { right += 1 }
                var end = r + 1
                while end < dividers.count - 1 {
                    let border = grid[dividers[end]][x[col] + 1]
                    if border == "-" || border == "=" { break }
                    end += 1
                }
                var content: [String] = []
                for physical in (y + 1)..<dividers[end] {
                    content.append(grid[physical][(x[col] + 1)..<x[right]].joined())
                }
                row += cell(content, header: header, columns: right - col, rows: end - r)
                for c in col..<right { coveredUntil[c] = end }
                col = right
            }
            if header { head += row + "</tr>" } else { body += row + "</tr>" }
        }
        return wrapTable(head: head, body: body)
    }

    private func simpleTable(_ source: [String]) -> String {
        let grid = source.map(Self.columns)
        guard let top = grid.first else { return "" }
        let starts = top.indices.filter { top[$0] == "=" && ($0 == 0 || top[$0 - 1] == " ") }
        let headEnd = grid.indices.dropFirst().dropLast().first(where: { grid[$0] == top }) ?? 0
        var rowLines: [[String]] = []
        var head = ""
        var body = ""

        func appendRow(header: Bool, separator: [String] = []) {
            guard !rowLines.isEmpty else { return }
            var row = "<tr>"
            var col = 0
            while col < starts.count {
                var right = col + 1
                while right < starts.count, starts[right] <= separator.count,
                    separator[starts[right] - 1] == "-"
                { right += 1 }
                let lines: [String] = rowLines.map { chars in
                    let end = right < starts.count ? min(chars.count, starts[right]) : chars.count
                    return starts[col] < end ? chars[starts[col]..<end].joined() : ""
                }
                row += cell(lines, header: header, columns: right - col)
                col = right
            }
            if header { head += row + "</tr>" } else { body += row + "</tr>" }
            rowLines.removeAll(keepingCapacity: true)
        }
        for i in grid.indices.dropFirst() {
            let line = grid[i]
            if line == top || i == grid.count - 1 {
                appendRow(header: i <= headEnd)
            } else if line.allSatisfy({ $0 == " " }) {
                if !rowLines.isEmpty { rowLines.append([]) }
            } else if line.contains("-"), line.allSatisfy({ $0 == "-" || $0 == " " }) {
                appendRow(header: i < headEnd, separator: line)
            } else {
                if starts.count > 1, line.prefix(starts[1]).contains(where: { $0 != " " }) {
                    appendRow(header: i < headEnd)
                }
                rowLines.append(line)
            }
        }
        return wrapTable(head: head, body: body)
    }

    private func wrapTable(head: String, body: String) -> String {
        "<table>" + (head.isEmpty ? "" : "<thead>\(head)</thead>") + "<tbody>\(body)</tbody></table>"
    }
}

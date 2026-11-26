import Foundation

extension WikiReader {
    func table(_ lines: [String], at index: inout Int, opening: String, nesting: Int) -> String {
        var output = "<table" + Self.safeAttributes(Self.attributes(String(opening.dropFirst(2))), cell: true) + ">"
        var row = false
        var cell: String?
        var pending: [String] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let content = pending.joined(separator: "\n")
            pending.removeAll(keepingCapacity: true)
            output += blocks(content)
        }
        func endCell() {
            flush()
            if let previous = cell {
                output += "</\(previous)>"
                cell = nil
            }
        }
        while index < lines.count {
            if PreviewConversion.expired { return "" }
            let line = lines[index]
            index += 1
            if line.hasPrefix("|}") { break }
            if line.hasPrefix("{|") {
                flush()
                if nesting < 32 {
                    output += table(lines, at: &index, opening: line, nesting: nesting + 1)
                } else {
                    var balance = 1
                    output += HTML.escape(line)
                    while index < lines.count && balance > 0 {
                        if index.isMultiple(of: 128), PreviewConversion.expired { return "" }
                        let literal = lines[index]
                        if literal.hasPrefix("{|") { balance += 1 }
                        if literal.hasPrefix("|}") { balance -= 1 }
                        output += "\n" + HTML.escape(literal)
                        index += 1
                    }
                }
            } else if line.hasPrefix("|+") {
                endCell()
                output += "<caption>" + inline(String(line.dropFirst(2)).wikiTrim) + "</caption>"
            } else if line.hasPrefix("|-") {
                endCell()
                if row { output += "</tr>" }
                output += "<tr>"
                row = true
            } else if line.hasPrefix("!") || line.hasPrefix("|") {
                if !row {
                    output += "<tr>"
                    row = true
                }
                let header = line.hasPrefix("!")
                let cells = String(line.dropFirst()).wikiFields(separatedBy: header ? "!!" : "||")
                for (offset, part) in cells.enumerated() {
                    if offset.isMultiple(of: 128), PreviewConversion.expired { return "" }
                    endCell()
                    let tag = header ? "th" : "td"
                    cell = tag
                    var text = part.wikiTrim
                    var attrs = ""
                    if let pipe = text.firstIndex(of: "|"), text[..<pipe].contains("=") {
                        attrs = Self.safeAttributes(Self.attributes(String(text[..<pipe])), cell: true)
                        text = String(text[text.index(after: pipe)...]).wikiTrim
                    }
                    output += "<\(tag)\(attrs)>"
                    if !text.isEmpty { pending.append(text) }
                }
            } else {
                pending.append(line)
            }
        }
        endCell()
        return output + (row ? "</tr>" : "") + "</table>"
    }
}

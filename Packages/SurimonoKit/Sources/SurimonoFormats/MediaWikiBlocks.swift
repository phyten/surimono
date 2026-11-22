import Foundation

extension WikiReader {
    func singleAtom(_ text: String) -> Atom? {
        guard text.first == "\u{E000}", text.last == "\u{E001}",
            let index = Int(text.dropFirst().dropLast()), atoms.indices.contains(index)
        else { return nil }
        return atoms[index]
    }

    func blocks(_ source: String) -> String {
        guard depth < 32, StackSpace.hasRoom else {
            reachedNestingLimit = true
            return HTML.escape(source)
        }
        depth += 1
        defer { depth -= 1 }
        let lines = source.components(separatedBy: "\n")
        var index = 0
        var output = ""
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                output += "<p>" + paragraph.joined(separator: " ") + "</p>\n"
                paragraph.removeAll()
            }
        }
        while index < lines.count {
            let raw = lines[index]
            let line = raw.wikiTrim
            index += 1
            if line.isEmpty {
                flush()
                continue
            }
            if depth == 1, index == 1, raw.prefix(10).uppercased().hasPrefix("#REDIRECT "),
                let a = singleAtom(String(raw.dropFirst(10)).wikiTrim), a.kind == "link"
            {
                return note((japanese ? "転送先: " : "Redirect to ") + HTML.escape(a.body))
            }
            if raw.hasPrefix(" ") {
                flush()
                var pre = [String(raw.dropFirst())]
                while index < lines.count, lines[index].hasPrefix(" ") {
                    pre.append(String(lines[index].dropFirst()))
                    index += 1
                }
                output += "<pre>" + pre.map(inline).joined(separator: "\n") + "</pre>"
                continue
            }
            let level = raw.prefix { $0 == "=" }.count
            if (1...6).contains(level), line.reversed().prefix(while: { $0 == "=" }).count == level,
                line.count > level * 2
            {
                flush()
                output += heading(level, String(line.dropFirst(level).dropLast(level)).wikiTrim)
            } else if raw.hasPrefix("{|") {
                flush()
                output += table(lines, at: &index, opening: raw, nesting: 0)
            } else if let first = raw.first, "*#;:".contains(first) {
                flush()
                if first == ":", let a = singleAtom(String(line.dropFirst()).wikiTrim), a.kind == "math" {
                    output += render(a, display: true)
                } else {
                    index -= 1
                    output += list(lines, at: &index)
                }
            } else if line.hasPrefix("----"), line.allSatisfy({ $0 == "-" }) {
                flush()
                output += "<hr>"
            } else if let a = singleAtom(line) {
                let block = !["ref", "chem", "nowiki", "literal", "html", "parameter", "link"].contains(a.kind)
                let content = render(a, block: true)
                if block || a.kind == "html" || content.hasPrefix("<figure")
                    || content.hasPrefix("<span class=\"wiki-note")
                {
                    flush()
                    output += content
                } else if !content.isEmpty {
                    paragraph.append(content)
                }
            } else if startsHTMLBlock(line) {
                flush()
                output += inline(line)
            } else if ["__TOC__", "__FORCETOC__", "__NOTOC__", "__NOEDITSECTION__"].contains(line) {
                flush()
                output += inline(line)
            } else {
                let content = inline(raw)
                if !content.isEmpty { paragraph.append(content) }
            }
        }
        flush()
        return output
    }

    private func startsHTMLBlock(_ line: String) -> Bool {
        guard line.first == "\u{E000}", let end = line.firstIndex(of: "\u{E001}"),
            let tag = singleAtom(String(line[...end])), tag.kind == "html"
        else { return false }
        let name = String(tag.body.drop(while: { $0 == "<" || $0 == "/" }).prefix(while: { $0.isLetter }))
        return [
            "blockquote", "div", "center", "dl", "dt", "dd", "ol", "ul", "li", "table", "thead", "tbody",
            "tfoot", "tr", "th", "td", "caption", "colgroup", "hr",
        ].contains(name)
    }

    private func list(_ lines: [String], at index: inout Int) -> String {
        var output = ""
        var stack: [(list: String, item: String)] = []
        func close() {
            if let last = stack.popLast() { output += "</\(last.item)></\(last.list)>" }
        }
        while index < lines.count {
            let line = lines[index]
            let prefix = line.prefix { "*#;:".contains($0) }
            guard !prefix.isEmpty else { break }
            let content = String(line.dropFirst(prefix.count)).wikiTrim
            if prefix == ":", let a = singleAtom(content), a.kind == "math" { break }
            index += 1
            guard prefix.count <= 64 else {
                while !stack.isEmpty { close() }
                output += HTML.escape(line)
                continue
            }
            let path: [(String, String)] = prefix.enumerated().map { level, marker in
                switch marker {
                case "*": ("ul", "li")
                case "#": ("ol", "li")
                case ";": ("dl", "dt")
                case ":" where stack.indices.contains(level) && stack[level].list == "dl": ("dl", "dd")
                default: ("blockquote", "p")
                }
            }
            var shared = 0
            while shared < min(path.count, stack.count), path[shared].0 == stack[shared].list { shared += 1 }
            while stack.count > shared { close() }
            if shared == path.count, let last = stack.last, let target = path.last {
                output += "</\(last.item)><\(target.1)>"
                stack[shared - 1].item = target.1
            }
            for pair in path.dropFirst(shared) {
                output += "<\(pair.0)><\(pair.1)>"
                stack.append(pair)
            }
            if prefix.last == ";", let colon = content.firstIndex(of: ":") {
                output +=
                    inline(String(content[..<colon]).wikiTrim) + "</dt><dd>"
                    + inline(String(content[content.index(after: colon)...]).wikiTrim)
                stack[stack.count - 1].item = "dd"
            } else {
                output += inline(content)
            }
        }
        while !stack.isEmpty { close() }
        return output
    }
}

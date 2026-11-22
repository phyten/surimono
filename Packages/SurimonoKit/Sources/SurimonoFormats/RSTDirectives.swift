import Foundation

struct RSTDirectiveState {
    struct Contents {
        let id: String
        let label: String
        let depth: Int
        let local: Bool
        let position: Int
    }
    var contents: [Contents] = []
    let token = UUID().uuidString
    var numbering: [String: String]?
    var nextClasses: [String] = []
    var includeStack: [URL] = []
    var bytesRead = 0
    var readCount = 0
}

struct RSTDirective {
    let name: String
    let argument: String
    let options: [String: String]
    let lines: [String]

    init?(_ first: String, _ body: [String]) {
        guard first.hasPrefix(".. "), let separator = first.range(of: "::") else { return nil }
        let prefix = first[..<separator.lowerBound].dropFirst(3)
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" }) else {
            return nil
        }
        name = prefix.lowercased()
        argument = String(first[separator.upperBound...]).rstStripped
        var rest = body[...]
        var params: [String: String] = [:]
        while let line = rest.first, line.hasPrefix(":"), let colon = line.dropFirst().firstIndex(of: ":") {
            let key = line[line.index(after: line.startIndex)..<colon]
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { break }
            var value = String(line[line.index(after: colon)...]).rstStripped
            rest = rest.dropFirst()
            while let continuation = rest.first, continuation.hasPrefix(" ") {
                value += "\n" + continuation.rstStripped
                rest = rest.dropFirst()
            }
            params[key.lowercased()] = value
        }
        while rest.first?.isEmpty == true { rest = rest.dropFirst() }
        while rest.last?.isEmpty == true { rest = rest.dropLast() }
        options = params
        lines = Array(rest)
    }
}

extension RSTDocument {
    func renderDirective(_ first: String, body: [String]) -> String? {
        guard let d = RSTDirective(first, body) else { return nil }
        let rendered: String
        let named = !d.argument.isEmpty
        let content: [String]
        if !named {
            content = d.lines
        } else if d.options.isEmpty {
            content = [d.argument] + body
        } else {
            content = [d.argument, ""] + d.lines
        }
        switch d.name {
        case "image": rendered = rstImage(d.argument, options: d.options)
        case "figure":
            let caption = d.lines.prefix { !$0.isEmpty }
            let legend = d.lines.dropFirst(caption.count).drop(while: { $0.isEmpty })
            let remainder = legend.isEmpty ? "" : "<div class=\"legend\">\(blocks(Array(legend)))</div>"
            let body = d.lines.isEmpty ? "" : "<figcaption>\(blocks(Array(caption)))\(remainder)</figcaption>"
            rendered = "<figure>\(rstImage(d.argument, options: d.options))\(body)</figure>"
        case "note", "warning", "tip", "important", "caution", "danger", "error", "hint", "attention", "seealso":
            let kind = MarkdownCallouts.Kind(name: d.name == "seealso" ? "note" : d.name)
            let titles = [
                "attention": "Attention!", "caution": "Caution!", "danger": "!DANGER!", "seealso": "See also",
            ]
            let label = titles[d.name] ?? kind.defaultTitle
            rendered = kind.opening + kind.title(label) + blocks(content) + "</div>"
        case "admonition":
            let kind = MarkdownCallouts.Kind(name: "neutral")
            rendered = kind.opening + kind.title(inline(d.argument)) + blocks(d.lines) + "</div>"
        case "topic", "sidebar":
            let subtitle = d.options["subtitle"].map { "<p class=\"sidebar-subtitle\">\(inline($0))</p>" } ?? ""
            rendered =
                "<aside class=\"\(d.name)\"><p class=\"\(d.name)-title\">\(inline(d.argument))</p>"
                + subtitle + blocks(d.lines) + "</aside>"
        case "rubric": rendered = "<p class=\"rubric\">\(inline(d.argument))</p>"
        case "epigraph", "highlights", "pull-quote":
            // Reuse the ordinary quotation parser, including the attribution following the last paragraph.
            rendered = blocks(content.map { $0.isEmpty ? "" : "  " + $0 })
        case "compound", "container": rendered = "<div>\(blocks(d.lines))</div>"
        case "code", "code-block", "sourcecode":
            rendered = rstCode(d.lines, language: d.argument, options: d.options)
        case "parsed-literal":
            rendered = "<pre class=\"literal-block\">\(inline(content.joined(separator: "\n")))</pre>"
        case "math":
            rendered = content.split(whereSeparator: { $0.isEmpty }).map { group in
                let latex = group.joined(separator: "\n")
                return "<div class=\"math-block\">"
                    + (MathRenderer.html(latex, display: true) ?? MathRenderer.fallback(latex, display: true))
                    + "</div>"
            }.joined()
        case "table", "csv-table", "list-table":
            guard let table = rstTableDirective(d) else { return rstUnreadable(first, body) }
            rendered = table
        case "include":
            guard d.options["literal"] != nil || d.options["code"] != nil, let (_, lines) = rstIncludedFile(d) else {
                return rstUnreadable(first, body)
            }
            if let language = d.options["code"] { return rstCode(lines, language: language, options: d.options) }
            return "<pre class=\"literal-block\">\(HTML.escape(lines.joined(separator: "\n")))</pre>"
        case "contents":
            guard directives.contents.count < 256 else { return rstUnreadable(first, body) }
            let name = d.argument.isEmpty ? "contents" : d.argument
            let id = references.id(name, kind: "topic")
            references.targets[RSTReferences.name(name)] = .address("#" + id)
            let toc = RSTDirectiveState.Contents(
                id: id, label: d.argument, depth: max(1, Int(d.options["depth"] ?? "") ?? 6),
                local: d.options["local"] != nil, position: anchors.count)
            let index = directives.contents.count
            directives.contents.append(toc)
            return "<!--\(directives.token)toc\(index)-->"
        case "sectnum", "section-numbering":
            directives.numbering = d.options
            return ""
        case "header", "footer", "meta", "index": return ""
        case "raw":
            guard d.argument.split(whereSeparator: \.isWhitespace).contains("html") else { return "" }
            return rstRawHTML(d.lines.joined(separator: "\n"))
        case "class", "rst-class":
            let classes = d.argument.split(whereSeparator: \.isWhitespace).map(String.init)
            if d.lines.isEmpty {
                directives.nextClasses += classes
                return ""
            }
            return blocks(d.lines, classes: classes)
        case "title":
            title = d.argument
            return ""
        case "line-block":
            // Use the line-block reader so nested indentation has the same meaning in both spellings.
            rendered = blocks(d.lines.map { "| " + $0 })
        case "toctree": rendered = rstTree(d.lines)
        case "only", "glossary": rendered = blocks(d.lines)
        case "versionadded", "versionchanged", "deprecated":
            let label = [
                "versionadded": "Added in version", "versionchanged": "Changed in version",
                "deprecated": "Deprecated since version",
            ]
            rendered = "<p><em>\(label[d.name] ?? d.name) \(inline(d.argument))</em></p>" + blocks(d.lines)
        default:
            issueCount += 1
            // Unknown options and arguments may be the only text the author supplied.
            return "<div class=\"callout callout-neutral\"><p class=\"callout-title\">\(HTML.escape(d.name))</p>"
                + (named ? "<p>\(HTML.escape(d.argument))</p>" : "")
                + (body.isEmpty ? "" : "<pre>\(HTML.escape(body.joined(separator: "\n")))</pre>") + "</div>"
        }
        var classes = (d.options["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        if d.name == "container" { classes += d.argument.split(whereSeparator: \.isWhitespace).map(String.init) }
        var result = applyDirectiveClasses(classes, to: rendered)
        if let name = d.options["name"], !name.isEmpty {
            let id = references.id(name, kind: d.name)
            references.targets[RSTReferences.name(name)] = .address("#" + id)
            result = rstAttachTargets([id], to: result)
        }
        return result
    }

    /// Ordinary includes feed the surrounding block parser so their section headings remain in the same outline.
    func readNormalInclude(_ first: String, body: [String], _ render: ([String]) -> Void) -> Bool {
        guard let d = RSTDirective(first, body), d.name == "include", d.options["literal"] == nil,
            d.options["code"] == nil, let (file, lines) = rstIncludedFile(d)
        else { return false }
        directives.includeStack.append(file)
        defer { directives.includeStack.removeLast() }
        render(lines.map(Self.expandTabs))
        return true
    }

    private func rstIncludedFile(_ directive: RSTDirective) -> (URL, [String])? {
        guard let file = rstFile(directive.argument), directives.includeStack.count < 8,
            !directives.includeStack.contains(file), let text = rstRead(file)
        else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let start = max(0, min(Int(directive.options["start-line"] ?? "") ?? 0, lines.count))
        let end = max(start, min(Int(directive.options["end-line"] ?? "") ?? lines.count, lines.count))
        var selected = lines[start..<end]
        if let marker = directive.options["start-after"] {
            guard let cut = selected.firstIndex(where: { $0.contains(marker) }) else { return nil }
            selected = selected.suffix(from: selected.index(after: cut))
        }
        if let marker = directive.options["end-before"] {
            guard let cut = selected.firstIndex(where: { $0.contains(marker) }) else { return nil }
            selected = selected.prefix(upTo: cut)
        }
        return (file, Array(selected))
    }

    private func rstUnreadable(_ first: String, _ body: [String]) -> String {
        issueCount += 1
        let source = ([first] + body.map { $0.isEmpty ? "" : "   " + $0 }).joined(separator: "\n")
        return "<pre>\(HTML.escape(source))</pre>"
    }

    func applyDirectiveClasses(_ classes: [String], to html: String) -> String {
        guard !classes.isEmpty, html.hasPrefix("<"), let end = html.firstIndex(of: ">") else { return html }
        let names = HTML.escape(classes.joined(separator: " "))
        var result = html
        if let attribute = result[..<end].range(of: " class=\"") {
            result.insert(contentsOf: names + " ", at: attribute.upperBound)
        } else {
            result.insert(contentsOf: " class=\"\(names)\"", at: end)
        }
        return result
    }

    private func rstTree(_ lines: [String]) -> String {
        let items = lines.compactMap { line -> String? in
            let entry = line.rstStripped
            guard !entry.isEmpty else { return nil }
            var label = entry
            if let split = entry.lastIndex(of: "<"), entry.hasSuffix(">") {
                label = String(entry[..<split]).rstStripped
            } else {
                let path = entry.hasSuffix(".rst") || entry.hasSuffix(".rest") ? entry : entry + ".rst"
                if let file = rstFile(path), let contents = rstRead(file) {
                    let rows = contents.split(separator: "\n", omittingEmptySubsequences: false)
                    for (index, row) in rows.enumerated().dropFirst() {
                        if let mark = row.first, row.count > 1, mark.isASCII, !mark.isLetter, !mark.isNumber,
                            !mark.isWhitespace, row.allSatisfy({ $0 == mark }), !rows[index - 1].isEmpty
                        {
                            label = String(rows[index - 1])
                            break
                        }
                    }
                }
            }
            return "<li>\(HTML.escape(label))</li>"
        }
        return "<ul>\(items.joined())</ul>"
    }
}

import Foundation

struct ComputationalLabel {
    var id: String
    let kind: String
    enum Value {
        case number(String)
        case heading(String)
    }
    var value: Value
    let name: String
    var shortText: String {
        switch value {
        case .number(let number): number
        case .heading(let title): title
        }
    }
    var text: String {
        if case .number = value { return name + " " + shortText }
        return shortText
    }
    var attribute: String { id.isEmpty ? "" : " id=\"\(HTML.escape(id))\"" }

    static let names = [
        "fig": ("Figure", "図"), "tbl": ("Table", "表"), "sec": ("Section", "節"), "eq": ("Equation", "式"),
        "thm": ("Theorem", "定理"), "lem": ("Lemma", "補題"), "def": ("Definition", "定義"),
        "exm": ("Example", "例"), "cor": ("Corollary", "系"), "prp": ("Proposition", "命題"),
        "cnj": ("Conjecture", "予想"), "rem": ("Remark", "注"), "exr": ("Exercise", "演習"),
        "sol": ("Solution", "解答"), "nte": ("Note", "注"),
    ]

    static func kind(_ id: String) -> String? {
        guard let split = id.firstIndex(where: { $0 == ":" || $0 == "-" }) else { return nil }
        let prefix = String(id[..<split])
        return names[prefix] == nil ? nil : prefix
    }

    /// The label a Quarto reference written as `@id` points to, or nil when it is a citation. Quarto takes `@` for a
    /// cross-reference only when a known kind and a hyphen start the name (`fig-a`, or `Fig-a` for a capitalized
    /// "Figure"); anything else, `fig:a` included, is a citation key.
    static func quartoTarget(_ id: String) -> String? {
        guard let split = id.firstIndex(of: "-") else { return nil }
        let prefix = id[..<split]
        if names[String(prefix)] != nil { return id }
        guard let first = prefix.first, first.isUppercase, names[prefix.lowercased()] != nil,
            prefix.dropFirst().allSatisfy(\.isLowercase)
        else { return nil }
        return prefix.lowercased() + id[split...]
    }
}

enum ComputationalInsertion {
    case literal(String)
    /// A cross-reference to the label `id`. `unresolved` is what the tool that wrote it prints when no label answers,
    /// and `written` the name as the document wrote it. bookdown's references only find numbered targets
    /// (`numbered`): a heading without a number is not in its table.
    case reference(id: String, numberOnly: Bool, numbered: Bool, unresolved: String, written: String)
}

extension ComputationalBody {
    mutating func deferInsertion(_ insertion: ComputationalInsertion) -> String {
        let marker = "\(token)ref\(insertions.count)end"
        insertions.append(insertion)
        return marker
    }

    mutating func register(_ id: String, kind: String, heading: String? = nil) -> ComputationalLabel {
        if let existing = labels[id] { return existing }
        // bookdown's tables (`tab:`) are Quarto's `tbl-` under another prefix, kept out of `names` so that a Quarto
        // `@tab-…` stays a citation.
        let counter = kind == "tab" ? "tbl" : kind
        counts[counter, default: 0] += 1
        let value = heading.map(ComputationalLabel.Value.heading) ?? .number(String(counts[counter, default: 0]))
        let name = ComputationalLabel.names[counter]
        let label = ComputationalLabel(
            id: id, kind: kind, value: value,
            name: (metadata.japanese ? name?.1 : name?.0) ?? kind)
        if !id.isEmpty { labels[id] = label }
        return label
    }

    /// `literalSpans` are UTF-8 offsets within `source` that print as written: code spans running over several lines
    /// and HTML code elements, as `MarkdownExtensions.protection` found them.
    mutating func inline(_ source: String, literalSpans: [Range<Int>] = []) -> String {
        // Every alternative starts with one of these characters; a line without any is returned as it is.
        guard source.utf8.contains(where: { [96, 36, 60, 93, 123, 94, 91, 92, 64].contains($0) }) else { return source }
        // Literal spans, math, tags and link destinations are consumed before the prose extensions are looked for.
        let scanner = ComputationalInlineScanner(source)
        let characters = scanner.characters
        func text(_ range: Range<Int>) -> String { String(characters[range]) }
        // Found only once the line holds something that may be a reference.
        var literals: ComputationalLiterals?
        func isLiteral(_ range: Range<Int>) -> Bool {
            if literals == nil { literals = ComputationalLiterals(characters, spans: literalSpans) }
            return literals?.contains(range) ?? false
        }
        // A footnote or a span is read again on its own, and keeps the part of the spans that falls in it.
        var utf8Starts: [Int] = []
        func nested(_ range: Range<Int>) -> [Range<Int>] {
            guard !literalSpans.isEmpty else { return [] }
            if utf8Starts.isEmpty {
                utf8Starts = characters.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1.utf8.count) }
            }
            return ComputationalLiterals.spans(
                literalSpans, within: utf8Starts[range.lowerBound]..<utf8Starts[range.upperBound])
        }
        var html = ""
        var start = 0
        for match in scanner.matches() {
            html += text(start..<match.range.lowerBound)
            let original = text(match.range)
            if let code = match.code, let expr = text(code).wholeMatch(of: /^(?:r|\{[\w.+-]+\})\s+(.+)$/) {
                html += deferInsertion(
                    .literal("<code class=\"inline-expression\">\(HTML.escape(String(expr.1)))</code>"))
            } else if let shortcode = match.shortcode.map(text) {
                let args = shortcode.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                let value = args.count > 1 ? String(args[1]) : ""
                switch args.first {
                case "pagebreak": html += "<div class=\"page-break\"></div>"
                case "include":
                    html += notice(
                        metadata.japanese ? "外部ファイルは読み込みません（\(value)）。" : "Included file is not read (\(value)).")
                case "meta": html += deferInsertion(.literal(HTML.escape(metadata.values[value] ?? "")))
                default: html += deferInsertion(.literal("<code>\(HTML.escape(original))</code>"))
                }
            } else if let footnote = match.footnote {
                let id = "\(token)note\(notes.count)"
                let definition = inline(text(footnote), literalSpans: nested(footnote))
                notes.append("[^\(id)]: \(definition)")
                html += "[^\(id)]"
            } else if let spanText = match.spanText, let attrs = match.spanAttributes {
                let content = inline(text(spanText), literalSpans: nested(spanText))
                html += "<span\(ComputationalAttributes(text(attrs)).html)>\(content)</span>"
            } else if match.bareReference != nil, match.range.lowerBound > 0,
                case let prior = characters[match.range.lowerBound - 1],
                prior.isLetter || prior.isNumber || prior == "_" || prior == "\\"
            {
                html += original
            } else if let ref = match.bookdown, !isLiteral(match.range) {
                // bookdown's `\@ref()` gives the number alone; the text around it names the figure or table.
                let id = text(ref)
                bookdownTargets.insert(id)
                html += deferInsertion(
                    .reference(id: id, numberOnly: true, numbered: true, unresolved: "??", written: id))
            } else if format == .quarto, let ref = match.crossReference ?? match.bareReference,
                let target = ComputationalLabel.quartoTarget(text(ref)), !isLiteral(match.range)
            {
                // A citation never reaches here, so a heading or figure with the same name cannot capture it. R Markdown
                // writes its cross-references with `\@ref()` and cites with `@`, whatever the key looks like.
                let numberOnly = match.crossReferenceMinus.map { !$0.isEmpty } ?? false
                html += deferInsertion(
                    .reference(
                        id: target, numberOnly: numberOnly, numbered: false, unresolved: "?@" + text(ref),
                        written: text(ref)))
            } else {
                html += original
            }
            start = match.range.upperBound
        }
        return html + text(start..<characters.count)
    }

    /// The label a reference finds, if any. The display and the print check both ask here, so they agree.
    private func target(_ id: String, numbered: Bool) -> ComputationalLabel? {
        guard let label = labels[id] else { return nil }
        if numbered, case .heading = label.value { return nil }
        return label
    }

    /// The references that name no label in the document, as written, once each in the order they are first used.
    var unresolvedReferences: [String] {
        var seen: Set<String> = []
        return insertions.compactMap { insertion in
            guard case .reference(let id, _, let numbered, _, let written) = insertion,
                target(id, numbered: numbered) == nil, seen.insert(written).inserted
            else { return nil }
            return written
        }
    }

    func resolve(_ html: String, plainText: Bool = false) -> String {
        guard !insertions.isEmpty,
            let regex = try? NSRegularExpression(pattern: "(?:<!--)?" + token + "ref([0-9]+)end(?:-->)?")
        else {
            return html
        }
        let source = html as NSString
        var result = ""
        var start = 0
        var inTag = false
        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let prefix = source.substring(with: NSRange(location: start, length: match.range.location - start))
            result += prefix
            if let delimiter = prefix.last(where: { $0 == "<" || $0 == ">" }) { inTag = delimiter == "<" }
            let textOnly = inTag || plainText
            guard let index = Int(source.substring(with: match.range(at: 1))), insertions.indices.contains(index) else {
                continue
            }
            switch insertions[index] {
            case .literal(let value):
                result +=
                    textOnly ? value.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression) : value
            case .reference(let id, let numberOnly, let numbered, let unresolved, _):
                // bookdown and Quarto print an unresolved reference in bold.
                if let target = target(id, numbered: numbered) {
                    let text = HTML.escape(numberOnly ? target.shortText : target.text)
                    result += textOnly ? text : "<a href=\"#\(HTML.escape(target.id))\">\(text)</a>"
                } else {
                    let text = HTML.escape(unresolved)
                    result += textOnly ? text : "<strong>\(text)</strong>"
                }
            }
            start = NSMaxRange(match.range)
        }
        return result + source.substring(from: start)
    }
}

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
}

enum ComputationalInsertion {
    case literal(String)
    case reference(id: String, numberOnly: Bool, original: String)
}

extension ComputationalBody {
    mutating func deferInsertion(_ insertion: ComputationalInsertion) -> String {
        let marker = "\(token)ref\(insertions.count)end"
        insertions.append(insertion)
        return marker
    }

    mutating func register(_ id: String, kind: String, heading: String? = nil) -> ComputationalLabel {
        if let existing = labels[id] { return existing }
        counts[kind, default: 0] += 1
        let value = heading.map(ComputationalLabel.Value.heading) ?? .number(String(counts[kind, default: 0]))
        let name = ComputationalLabel.names[kind]
        let label = ComputationalLabel(
            id: id, kind: kind, value: value,
            name: (metadata.japanese ? name?.1 : name?.0) ?? kind)
        if !id.isEmpty { labels[id] = label }
        return label
    }

    mutating func inline(_ source: String) -> String {
        // Every alternative starts with one of these characters; a line without any is returned as it is.
        guard source.utf8.contains(where: { [96, 36, 60, 93, 123, 94, 91, 92, 64].contains($0) }) else { return source }
        // Literal spans, math, tags and link destinations are consumed before the prose extensions are looked for.
        let scanner = ComputationalInlineScanner(source)
        let characters = scanner.characters
        func text(_ range: Range<Int>) -> String { String(characters[range]) }
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
                let definition = inline(text(footnote))
                notes.append("[^\(id)]: \(definition)")
                html += "[^\(id)]"
            } else if let spanText = match.spanText, let attrs = match.spanAttributes {
                html += "<span\(ComputationalAttributes(text(attrs)).html)>\(inline(text(spanText)))</span>"
            } else if match.bareReference != nil, match.range.lowerBound > 0,
                case let prior = characters[match.range.lowerBound - 1],
                prior.isLetter || prior.isNumber || prior == "_" || prior == "\\"
            {
                html += original
            } else if let ref = match.bookdown ?? match.crossReference ?? match.bareReference {
                let numberOnly = match.crossReferenceMinus.map { !$0.isEmpty } ?? false
                html += deferInsertion(.reference(id: text(ref), numberOnly: numberOnly, original: original))
            } else {
                html += original
            }
            start = match.range.upperBound
        }
        return html + text(start..<characters.count)
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
            case .reference(let id, let numberOnly, let original):
                if let target = labels[id] {
                    let text = HTML.escape(numberOnly ? target.shortText : target.text)
                    result += textOnly ? text : "<a href=\"#\(HTML.escape(target.id))\">\(text)</a>"
                } else {
                    result += HTML.escape(original)
                }
            }
            start = NSMaxRange(match.range)
        }
        return result + source.substring(from: start)
    }
}

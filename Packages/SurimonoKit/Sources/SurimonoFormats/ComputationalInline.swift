import Foundation

struct ComputationalLabel {
    let id: String
    let kind: String
    var number: String
    let name: String
    var text: String { name + " " + number }
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

    mutating func register(_ id: String, kind: String) -> ComputationalLabel {
        if let existing = labels[id] { return existing }
        counts[kind, default: 0] += 1
        let name = ComputationalLabel.names[kind]
        let label = ComputationalLabel(
            id: id, kind: kind, number: String(counts[kind, default: 0]),
            name: (metadata.japanese ? name?.1 : name?.0) ?? kind)
        if !id.isEmpty { labels[id] = label }
        return label
    }

    mutating func inline(_ source: String) -> String {
        // Consume literal spans, math, tags and link destinations before looking for prose extensions.
        let pattern =
            #/
            (`+)(.*?)\1(?!`)                  # inline code, including literal examples
            | \$\$.*?\$\$ | \$[^$]+\$         # math
            | <[^>]+> | \]\([^)]+\)           # raw tag or link destination
            | \{\{<\s*(.*?)\s*>\}\}           # shortcode
            | \^\[([^\]]+)\]                  # anonymous footnote
            | \[([^\]]*)\]\{([.\#][^}]+)\}    # attributed span
            | \\@ref\(([\w:.-]+)\)            # bookdown
            | \[(\-?)@([\w:.-]+)\]            # bracketed cross-reference
            | @([\w:-]+(?:\.[\w:-]+)*)        # bare reference
            /#
        var html = ""
        var start = source.startIndex
        for match in source.matches(of: pattern) {
            html += source[start..<match.range.lowerBound]
            let original = String(source[match.range])
            if let code = match.2, let expr = code.wholeMatch(of: /^(?:r|\{[\w.+-]+\})\s+(.+)$/) {
                html += deferInsertion(
                    .literal("<code class=\"inline-expression\">\(HTML.escape(String(expr.1)))</code>"))
            } else if let shortcode = match.3 {
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
            } else if let footnote = match.4 {
                let id = "\(token)note\(notes.count)"
                let definition = inline(String(footnote))
                notes.append("[^\(id)]: \(definition)")
                html += "[^\(id)]"
            } else if let text = match.5, let attrs = match.6 {
                html += "<span\(ComputationalAttributes(String(attrs)).html)>\(inline(String(text)))</span>"
            } else if match.10 != nil, let prior = source[..<match.range.lowerBound].last,
                prior.isLetter || prior.isNumber || prior == "_" || prior == "\\"
            {
                html += original
            } else if let ref = match.7 ?? match.9 ?? match.10 {
                html += deferInsertion(.reference(id: String(ref), numberOnly: match.8 == "-", original: original))
            } else {
                html += original
            }
            start = match.range.upperBound
        }
        return html + source[start...]
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
                    let text = numberOnly ? target.number : target.text
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

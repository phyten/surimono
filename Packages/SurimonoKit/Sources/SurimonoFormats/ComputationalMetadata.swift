import Foundation

/// Only scalar metadata is exposed to the document. Project configuration and executable YAML tags have no interpreter.
struct ComputationalMetadata {
    var values: [String: String] = [:]
    var defaults: [String: String] = [:]
    var unreadable: String?
    var japanese: Bool = false
    private(set) var keys: Set<String> = []

    var reading = ComputationalReadingHeader()

    init(lines: inout [String], format: DocumentFormat? = nil) {
        guard lines.first == "---" || lines.first == "\u{FEFF}---" else { return }
        let end = lines.dropFirst().firstIndex { $0 == "---" || $0 == "..." }
        let count = end.map { $0 + 1 } ?? lines.count
        let header = Array(lines.prefix(count))
        lines.removeFirst(count)
        guard let end, MarkdownConverter.frontMatterEnd(in: header, allowsBOM: true) != nil else {
            unreadable = header.joined(separator: "\n")
            return
        }
        var index = 1
        while index < end {
            let row = header[index]
            index += 1
            guard !row.hasPrefix("#"), let (key, raw) = Self.pair(row) else { continue }
            let start = index
            while index < end {
                let next = header[index]
                if !next.isEmpty && next.first?.isWhitespace != true && !next.hasPrefix("- ") { break }
                index += 1
            }
            keys.insert(key)
            guard !["format", "output", "params", "knit"].contains(key) else { continue }
            let children = header[start..<index]
            if key == "execute" {
                for child in children {
                    if let (option, value) = Self.pair(child) {
                        defaults[option] = Self.scalar(value)
                        values["execute." + option] = Self.scalar(value)
                    }
                }
            } else if ["|", ">"].contains(raw) {
                values[key] = Self.blockScalar(children, folded: raw == ">")
            } else if raw.hasPrefix("[") && raw.hasSuffix("]") {
                let entries = Self.items(String(raw.dropFirst().dropLast()))
                values[key] = entries.compactMap { key == "author" ? Self.author($0) : Self.scalar($0) }.joined(
                    separator: ", ")
            } else if raw.isEmpty && !children.isEmpty {
                // Keep dotted scalar paths for the meta shortcode without interpreting project settings.
                var parents: [(indent: Int, key: String)] = []
                for line in children where !line.trimmed.hasPrefix("-") {
                    guard let (field, value) = Self.pair(line) else { continue }
                    let indent = line.prefix(while: \.isWhitespace).count
                    while let last = parents.last, last.indent >= indent { parents.removeLast() }
                    let path = ([key] + parents.map(\.key) + [field]).joined(separator: ".")
                    if value.isEmpty { parents.append((indent, field)) } else { values[path] = Self.scalar(value) }
                }
                let items = children.compactMap { line -> String? in
                    let entry = line.trimmed
                    let item = entry.hasPrefix("- ") ? String(entry.dropFirst(2)) : entry
                    if entry.hasPrefix("- "), item.hasPrefix("{") { return Self.author(item) }
                    if let (field, value) = Self.pair(item) { return field == "name" ? Self.scalar(value) : nil }
                    return entry.hasPrefix("- ") ? Self.scalar(item) : nil
                }
                values[key] = items.joined(separator: ", ")
            } else {
                if let first = raw.first, ["'", "\"", "["].contains(first),
                    raw.count < 2 || raw.last != (first == "[" ? "]" : first)
                {
                    values.removeAll()
                    defaults.removeAll()
                    unreadable = header.joined(separator: "\n")
                    return
                }
                values[key] = Self.scalar(raw)
            }
        }
        if let format { reading = ComputationalReadingHeader(header[1..<end], format: format, metadata: values) }
    }

    static func blockScalar(_ lines: ArraySlice<String>, folded: Bool) -> String {
        let indent = lines.filter { !$0.trimmed.isEmpty }.map { $0.prefix(while: \.isWhitespace).count }.min() ?? 0
        return lines.map { String($0.dropFirst(indent)) }.joined(separator: folded ? " " : "\n").trimmed
    }

    static func pair(_ text: String) -> (String, String)? {
        guard let split = text.firstIndex(of: ":") else { return nil }
        return (String(text[..<split]).trimmed, String(text[text.index(after: split)...]).trimmed)
    }

    private static func author(_ text: String) -> String? {
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return scalar(text) }
        for item in items(String(text.dropFirst().dropLast())) {
            if let (key, value) = pair(item), key == "name" { return scalar(value) }
        }
        return nil
    }

    static func scalar(_ text: String) -> String {
        let value = text.trimmed
        if value.count >= 2, value.first == value.last, value.first == "'" || value.first == "\"" {
            if value.first == "\"", let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) {
                return decoded
            }
            let inner = String(value.dropFirst().dropLast())
            return value.first == "'" ? inner.replacingOccurrences(of: "''", with: "'") : inner
        }
        return value
    }

    static func items(_ text: String) -> [String] {
        var valid = true
        return items(text, valid: &valid)
    }

    /// A malformed flow collection cannot supply file instructions.
    static func flowItems(_ text: String) -> [String]? {
        var valid = true
        var result = items(text, valid: &valid)
        if result.last == "" { result.removeLast() }
        return valid ? result : nil
    }

    private static func items(_ text: String, valid: inout Bool) -> [String] {
        var quote: Character?
        var closing: [Character] = []
        var escaped = false
        var parts: [String] = []
        var current = ""
        for char in text {
            if char == ",", quote == nil, closing.isEmpty {
                parts.append(current.trimmed)
                current = ""
            } else {
                if escaped {
                    escaped = false
                } else if quote == "\"" && char == "\\" {
                    escaped = true
                } else if char == quote {
                    quote = nil
                } else if quote == nil {
                    if char == "\"" || char == "'" {
                        quote = char
                    } else if char == "{" || char == "[" {
                        closing.append(char == "{" ? "}" : "]")
                    } else if char == "}" || char == "]" {
                        if closing.popLast() != char { valid = false }
                    }
                }
                current.append(char)
            }
        }
        valid = valid && quote == nil && closing.isEmpty
        parts.append(current.trimmed)
        return parts
    }

    var header: String {
        var body = ""
        for key in ["title", "subtitle", "author", "date"] {
            guard let value = values[key], !value.isEmpty else { continue }
            if key == "date", ["today", "last-modified"].contains(value.lowercased()) || value.contains("`r ") {
                continue
            }
            let tag = key == "title" ? "h1" : "p"
            body += "<\(tag) class=\"org-\(key)\">\(HTML.escape(value))</\(tag)>"
        }
        return body.isEmpty ? "" : "<header class=\"org-title-block\">\(body)</header>\n"
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

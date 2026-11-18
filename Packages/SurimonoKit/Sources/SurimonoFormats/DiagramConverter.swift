import Foundation

/// Keeps diagram input inert until the renderer has installed its offline engines.
public enum DiagramConverter {
    static func format(language: String?) -> DocumentFormat? {
        switch language?.lowercased() {
        case "dot", "graphviz": .graphviz
        case "plantuml", "puml": .plantuml
        default: nil
        }
    }

    static func block(_ source: String, format: DocumentFormat) -> String {
        let name = format == .graphviz ? "graphviz" : "plantuml"
        return "<div class=\"\(name)-block\"><pre class=\"diagram-source\">\(HTML.escape(source))</pre></div>\n"
    }

    public static func convert(_ source: String, format: DocumentFormat) -> HTMLFragment {
        let diagrams = format == .plantuml ? sections(source) : [source]
        return HTMLFragment(
            body: "<div class=\"diagram-document\">\n"
                + diagrams.map {
                    block($0, format: format)
                }.joined() + "</div>\n")
    }

    /// Preserve incomplete sections too, so malformed files have a visible error instead of disappearing.
    static func sections(_ source: String) -> [String] {
        var result: [String] = []
        var current: [String] = []
        var kind: String?
        for line in TextDecoding.normalizeNewlines(source).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: #"^@start[a-zA-Z]+\b"#, options: .regularExpression) {
                if !current.isEmpty { result.append(current.joined(separator: "\n")) }
                kind = String(trimmed[range].dropFirst(6))
                current = [line]
            } else if let active = kind {
                current.append(line)
                if trimmed == "@end" + active {
                    result.append(current.joined(separator: "\n"))
                    current = []
                    kind = nil
                }
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result.isEmpty ? ["@startuml\n" + source + "\n@enduml"] : result
    }

    /// Bounded, conservative recognition; quoted braces and comments cannot close a DOT graph.
    package static func clipboardKind(_ source: String) -> DocumentFormat? {
        guard source.utf8.count <= 200_000 else { return nil }
        var text = source[...]
        while true {
            text = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            if text.hasPrefix("/*"), let end = text.range(of: "*/") {
                text = text[end.upperBound...]
            } else if text.hasPrefix("/'"), let end = text.range(of: "'/") {
                text = text[end.upperBound...]
            } else if text.hasPrefix("//") || text.hasPrefix("'") || text.hasPrefix("#") {
                guard let end = text.firstIndex(of: "\n") else { return nil }
                // A Markdown heading is not a DOT preprocessor directive.
                if text.hasPrefix("#"), text.dropFirst().first?.isNumber != true { break }
                text = text[end...]
            } else {
                break
            }
        }
        if text.range(of: #"^@start[a-zA-Z]+\b"#, options: .regularExpression) != nil { return .plantuml }
        guard
            let header = text.range(
                of: #"^(?:strict\s+)?(?:digraph|graph)\s*(?:[\p{L}_][\p{L}\p{N}_]*|\"(?:\\.|[^\"\\])*\"|[0-9]+)?\s*\{"#,
                options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let tail = Array(text[header.upperBound...])
        var depth = 1
        var index = 0
        var quoted = false
        var htmlDepth = 0
        while index < tail.count {
            let c = tail[index]
            let next: Character? = index + 1 < tail.count ? tail[index + 1] : nil
            if quoted {
                if c == "\\" { index += 1 } else if c == "\"" { quoted = false }
            } else if c == "\"" {
                quoted = true
            } else if c == "/", next == "/" || next == "*" {
                let block = next == "*"
                index += 2
                while index < tail.count {
                    if !block && tail[index] == "\n" { break }
                    if block && tail[index] == "*" && index + 1 < tail.count && tail[index + 1] == "/" {
                        index += 1
                        break
                    }
                    index += 1
                }
            } else if c == "<" {
                htmlDepth += 1
            } else if c == ">", htmlDepth > 0 {
                htmlDepth -= 1
            } else if htmlDepth == 0 {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return tail[(index + 1)...].allSatisfy(\.isWhitespace) ? .graphviz : nil
                    }
                }
            }
            index += 1
        }
        return nil
    }
}

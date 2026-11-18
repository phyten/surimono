import Foundation

/// Count fence characters so an example containing a shorter fence stays a single static listing.
struct ComputationalFence {
    let marker: Substring
    let info: String

    init?(_ line: String) {
        guard let match = line.wholeMatch(of: /^ {0,3}(`{3,}|~{3,})(.*)$/) else { return nil }
        marker = match.1
        info = match.2.trimmingCharacters(in: .whitespaces)
    }

    func closes(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.count >= marker.count && text.allSatisfy { $0 == marker.first }
    }

    var chunk: ComputationalChunk? {
        guard info.first == "{", info.last == "}" else { return nil }
        return ComputationalChunk(String(info.dropFirst().dropLast()))
    }
}

struct ComputationalChunk {
    let language: String
    var options: [String: String]
    let isStatic: Bool
    let knitr: Bool

    init?(_ info: String) {
        guard let match = info.wholeMatch(of: /^(\.?)([a-zA-Z][\w.+-]*)(.*)$/) else { return nil }
        language = String(match.2).lowercased()
        isStatic = !match.1.isEmpty
        knitr = match.3.contains(",")
        let arguments = ComputationalMetadata.items(String(match.3))
        var result: [String: String] = [:]
        for argument in arguments where !argument.isEmpty {
            if let match = argument.wholeMatch(of: /^([\w.-]+)\s*=\s*(.+)$/) {
                result[String(match.1)] = ComputationalMetadata.scalar(String(match.2))
            } else if result["label"] == nil {
                result["label"] = argument
            }
        }
        options = result
    }

    static func option(_ line: String) -> (String, String)? {
        guard let match = line.firstMatch(of: /^\s*(?:#|\/\/|--|%%)\|\s*(.*)$/) else { return nil }
        return ComputationalMetadata.pair(String(match.1))
    }

    /// Only accept a complete literal statement. A call in a string, comment or conditional cannot change defaults.
    static func setupDefaults(_ source: String) -> [String: String] {
        var defaults: [String: String] = [:]
        var statement = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for line in source.components(separatedBy: "\n") {
            for char in line {
                if quote == nil && char == "#" { break }
                statement.append(char)
                if escaped {
                    escaped = false
                } else if quote != nil && char == "\\" {
                    escaped = true
                } else if char == quote {
                    quote = nil
                } else if quote == nil {
                    if ["'", "\"", "`"].contains(char) {
                        quote = char
                    } else if "([{".contains(char) {
                        depth += 1
                    } else if ")]}".contains(char) {
                        depth = max(0, depth - 1)
                    }
                }
            }
            statement.append("\n")
            guard depth == 0 && quote == nil else { continue }
            let complete = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            if complete.wholeMatch(of: /(?s)(?:if|for|while)\s*\(.*\)/) != nil { continue }
            statement = ""
            guard let match = complete.wholeMatch(of: /knitr::opts_chunk\$set\(([^()]*)\)\s*;?/) else { continue }
            var options: [String: String] = [:]
            for item in ComputationalMetadata.items(String(match.1)) {
                guard let literal = item.wholeMatch(of: /^([\w.]+)\s*=\s*(TRUE|FALSE|'hide'|"hide")$/) else {
                    options.removeAll()
                    break
                }
                options[String(literal.1)] = ComputationalMetadata.scalar(String(literal.2))
            }
            defaults.merge(options) { _, value in value }
        }
        return defaults
    }
}

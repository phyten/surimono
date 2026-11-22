import Foundation

/// References can precede their definitions, even when the definition is in a later included file.
/// Keep identities separate from the visible label (especially for automatic and symbolic notes).
final class RSTReferences {
    enum Target {
        case address(String)
        case indirect(String)
    }

    enum Token {
        case link(name: String, label: String, source: String)
        case substitution(String, suffix: Int)
        case noteUse(String)
        case noteReference(Int)
        case note(Int)
        case targetNotes
    }

    struct Note {
        let name: String
        let id: String
        var label: String
        var body = ""
        var citation: Bool { Self.isCitation(name) }

        static func isCitation(_ name: String) -> Bool {
            name.first != "#" && name != "*" && !name.allSatisfy(\.isNumber)
        }
    }

    struct NoteRef {
        let name: String
        let id: String
        var definition: Int?
    }

    struct Substitution {
        let kind: String
        let value: String
        let options: [String: String]
        let html: String?
    }

    let prefix = "\u{E003}rst" + UUID().uuidString + ":"
    lazy var pattern = try? NSRegularExpression(pattern: prefix + #"([0-9]+);"#)
    var tokens: [Token] = []
    var targets: [String: Target] = [:]
    var substitutions: [String: Substitution] = [:]
    var foldedSubstitutions: [String: String] = [:]
    var notes: [Note] = []
    var noteRefs: [NoteRef] = []
    var customRoles: [String: String] = [:]
    var defaultRole = "title-reference"
    var checkingReplacement = false
    var invalidReplacement = false
    var idCounts: [String: Int] = [:]
    var usedIDs: Set<String> = []
    var anonymousTargets = 0
    var anonymousReferences = 0
    var pendingTargets: [String] = []
    var headingContent: [String: String] = [:]
    var renderedLinks: [Int] = []
    var targetNoteRefs: [Int: Int] = [:]
    var targetNoteDefinitions: [Int] = []

    static func name(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    func substitutionKey(_ name: String) -> String {
        let exact = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return substitutions[exact] != nil ? exact : foldedSubstitutions[exact.lowercased()] ?? exact
    }

    func next(_ kind: String) -> Int {
        idCounts[kind, default: 0] += 1
        return idCounts[kind, default: 0]
    }

    func id(_ text: String, kind: String) -> String {
        let ascii = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        let parts = ascii.split { !$0.isASCII || !($0.isLetter || $0.isNumber) }
        let slug = String(parts.joined(separator: "-").drop(while: { !$0.isLetter }))
        if !slug.isEmpty, usedIDs.insert(slug).inserted { return slug }
        var newID: String
        repeat {
            newID = "\(kind)-\(next(kind))"
        } while !usedIDs.insert(newID).inserted
        return newID
    }

    func mark(_ token: Token) -> String {
        if checkingReplacement {
            switch token {
            case .noteUse, .link(name: "\u{0}anon", label: _, source: _): invalidReplacement = true
            default: break
            }
        }
        tokens.append(token)
        return prefix + String(tokens.count - 1) + ";"
    }

    func destination(_ key: String) -> String? {
        var name = Self.name(key)
        var seen: Set<String> = []
        while seen.count < 64, seen.insert(name).inserted, let target = targets[name] {
            switch target {
            case .address(let url): return url
            case .indirect(let another): name = Self.name(another)
            }
        }
        return nil
    }

    func addNoteRef(_ name: String) -> Int {
        let kind = Note.isCitation(name) ? "citation-reference" : "footnote-reference"
        let index = noteRefs.count
        noteRefs.append(NoteRef(name: name, id: id("", kind: kind)))
        return index
    }

    func addNote(_ name: String) -> Int {
        let citation = Note.isCitation(name)
        let key = name.hasPrefix("#") ? String(name.dropFirst()) : citation ? name : ""
        let index = notes.count
        notes.append(Note(name: name, id: id(key, kind: citation ? "citation" : "footnote"), label: name))
        return index
    }

    func numberNotes() -> Int {
        var shortened = 0
        var used = Set(notes.compactMap { Int($0.name) })
        var number = 1
        let signs = ["*", "†", "‡", "§", "¶", "#", "♠", "♥", "♦", "♣"]
        var symbols = 0
        var queues: [String: [Int]] = [:]
        for i in notes.indices {
            let name = notes[i].name
            if name.first == "#" {
                while used.contains(number) { number += 1 }
                notes[i].label = String(number)
                used.insert(number)
                number += 1
            } else if name == "*" {
                // After 320 notes, repeating the same sign makes the label wider than a text column.
                let repeats = 1 + symbols / signs.count
                if repeats <= 32 {
                    notes[i].label = String(repeating: signs[symbols % signs.count], count: repeats)
                } else {
                    notes[i].label = "*\(symbols + 1)"
                    shortened += 1
                }
                symbols += 1
            }
            queues[Self.name(name), default: []].append(i)
        }
        var ordinals: [String: Int] = [:]
        for i in noteRefs.indices {
            let ref = noteRefs[i]
            let name = Self.name(ref.name)
            let index = ordinals[name, default: 0]
            if ref.name == "#" || ref.name == "*" { ordinals[ref.name] = index + 1 }
            guard let queue = queues[name], queue.indices.contains(index) else { continue }
            noteRefs[i].definition = queue[index]
        }
        return shortened
    }
}

extension RSTDocument {
    func rstAttachTargets(_ ids: [String], to html: String) -> String {
        guard let last = ids.last else { return html }
        let spans = ids.dropLast().map { "<span id=\"\($0)\"></span>" }.joined()
        guard html.first == "<", let end = html.firstIndex(of: ">"),
            !html[..<end].contains(" id=\""), html[..<end].firstIndex(of: "/") == nil
        else { return spans + "<span id=\"\(last)\"></span>" + html }
        return String(html[..<end]) + " id=\"\(last)\">" + spans + String(html[html.index(after: end)...])
    }

    func rstLink(_ url: String, label: String) -> String {
        if let scheme = URLComponents(string: url)?.scheme,
            !["http", "https", "mailto", "ftp", "tel"].contains(scheme.lowercased())
        {
            return label
        }
        return "<a href=\"\(HTML.escape(url))\">\(label)</a>"
    }

    func rstNamedLink(_ name: String, label: String, source: String, anonymous: Bool = false) -> String {
        let key = anonymous ? "\u{0}anon" : name
        return references.mark(.link(name: key, label: label, source: source))
    }

    func renderExplicit(_ first: String, body: [String]) -> String? {
        let rest: String
        if first == "__" || first.hasPrefix("__ ") {
            rest = "__: " + first.dropFirst(3)
        } else if first == ".." || first.hasPrefix(".. ") {
            rest = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }
        if let (name, initial) = rstTargetDefinition(rest) {
            let components = ([initial] + body).map { $0.trimmingCharacters(in: .whitespaces) }
            let value = components.joined(separator: components.last?.last == "_" ? " " : "")
                .trimmingCharacters(in: .whitespaces)
            var key = RSTReferences.name(name)
            if name == "_" {
                references.anonymousTargets += 1
                key = "\u{0}anon\(references.anonymousTargets)"
            }
            if value.isEmpty {
                let id = references.id(name, kind: "target")
                references.targets[key] = .address("#" + id)
                references.pendingTargets.append(id)
                return ""
            }
            references.targets[key] = rstTarget(value)
            return ""
        }
        if rest.first == "[", let end = rest.firstIndex(of: "]") {
            let name = String(rest.dropFirst().prefix(while: { $0 != "]" }))
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return nil }
            let start = rest[rest.index(after: end)...].trimmingCharacters(in: .whitespaces)
            let i = references.addNote(name)
            let content = blocks((start.isEmpty ? [] : [start]) + body)
            references.notes[i].body = content
            return references.mark(.note(i))
        }
        if rest.first == "|", let end = rest.dropFirst().firstIndex(of: "|") {
            let key = String(rest[rest.index(after: rest.startIndex)..<end])
            let definition = rest[rest.index(after: end)...].trimmingCharacters(in: .whitespaces)
            if let separator = definition.range(of: "::") {
                let kind = definition[..<separator.lowerBound].lowercased()
                let firstValue = definition[separator.upperBound...].trimmingCharacters(in: .whitespaces)
                var value = firstValue
                var options: [String: String] = [:]
                for line in body {
                    if line.first == ":", let colon = line.dropFirst().firstIndex(of: ":") {
                        options[String(line[line.index(after: line.startIndex)..<colon])] =
                            line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    } else if !line.isEmpty {
                        value += (value.isEmpty ? "" : " ") + line
                    }
                }
                if ["replace", "date", "unicode", "image"].contains(kind) {
                    // A replacement uses the roles and resource directory of its definition. A target
                    // cannot be copied into several uses without duplicating its identity.
                    var html: String?
                    if kind == "replace" {
                        references.checkingReplacement = true
                        references.invalidReplacement = false
                        html = inline(value)
                        references.checkingReplacement = false
                        if references.invalidReplacement {
                            issueCount += 1
                            return "<pre>\(HTML.escape(([first] + body).joined(separator: "\n")))</pre>"
                        }
                    } else if kind == "image" {
                        html = rstImage(value, options: options)
                    }
                    let exact = key.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    references.foldedSubstitutions[exact.lowercased()] = exact
                    references.substitutions[exact] = .init(
                        kind: kind, value: value, options: options, html: html)
                    return ""
                }
            }
        }
        if let sep = rest.range(of: "::") {
            let value = rest[sep.upperBound...].trimmingCharacters(in: .whitespaces)
            switch rest[..<sep.lowerBound].lowercased() {
            case "role":
                let parts = value.split(separator: "(", maxSplits: 1)
                if let name = parts.first {
                    references.customRoles[name.lowercased()] =
                        parts.count == 2 ? String(parts[1].prefix(while: { $0 != ")" })).lowercased() : "span"
                }
                return ""
            case "default-role":
                references.defaultRole = value.isEmpty ? "title-reference" : value.lowercased()
                return ""
            case "target-notes": return references.mark(.targetNotes)
            default: return nil
            }
        }
        return ""
    }

    private func rstTargetDefinition(_ text: String) -> (String, String)? {
        guard text.first == "_" else { return nil }
        var quoted = false
        var escaped = false
        var i = text.index(after: text.startIndex)
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "`" {
                quoted.toggle()
            } else if c == ":", !quoted, next == text.endIndex || text[next].isWhitespace {
                let name = text[text.index(after: text.startIndex)..<i].trimmingCharacters(
                    in: CharacterSet(charactersIn: "`"))
                return (Self.rstUnescape(name), String(text[next...]))
            }
            i = next
        }
        return nil
    }

    func rstTarget(_ value: String) -> RSTReferences.Target {
        if value.last == "_", !value.contains("://") {
            return .indirect(
                String(value.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "`")))
        }
        return .address(value)
    }
}

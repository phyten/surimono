import Foundation

struct WikiReferences {
    private struct Group {
        var names: [String: Int] = [:]
        var entries: [String?] = []
        var seen: [Int: Int] = [:]
    }
    private var groups: [String: Group] = [:]
    private var order: [String] = []
    private var placed: Set<String> = []

    private func suffix(_ group: String, _ number: Int) -> String {
        group.isEmpty ? "\(number)" : "g\(Data(group.utf8).base64EncodedString())-\(number)"
    }

    mutating func add(_ content: String?, name: String?, group: String) -> String {
        if groups[group] == nil {
            groups[group] = Group()
            order.append(group)
        }
        let number: Int
        if let name, let existing = groups[group]?.names[name] {
            number = existing
            if let content, groups[group]?.entries[number - 1] == nil { groups[group]?.entries[number - 1] = content }
        } else {
            groups[group]?.entries.append(content)
            number = groups[group]?.entries.count ?? 1
            if let name { groups[group]?.names[name] = number }
        }
        let occurrence = groups[group]?.seen[number] ?? 0
        groups[group]?.seen[number] = occurrence + 1
        let id = suffix(group, number)
        let label = (group.isEmpty ? "" : HTML.escape(group) + " ") + String(number)
        let ref = id + (occurrence == 0 ? "" : "-\(occurrence + 1)")
        return "<sup class=\"footnote-ref\"><a href=\"#fn-\(id)\" id=\"fnref-\(ref)\">\(label)</a></sup>"
    }

    mutating func place(_ group: String) -> Bool { placed.insert(group).inserted }

    func list(_ key: String) -> String {
        guard let group = groups[key] else { return "" }
        let entries = group.entries.enumerated().map {
            "<li id=\"fn-\(suffix(key, $0.offset + 1))\">\($0.element ?? "…")</li>"
        }.joined()
        let label = key.isEmpty ? "" : "<p>\(HTML.escape(key))</p>"
        return "<section class=\"footnotes\">\(label)<ol>\(entries)</ol></section>"
    }
    func remainder() -> String { order.filter { !placed.contains($0) }.map(list).joined() }
}

extension WikiReader {
    func referenceList(_ group: String) -> String {
        guard references.place(group) else { return "" }
        referencePlaces.append(group)
        return "\u{E002}\(nonce)r\(referencePlaces.count - 1)\u{E003}"
    }
}

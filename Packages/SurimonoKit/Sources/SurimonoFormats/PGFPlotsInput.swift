import Foundation

enum PGFPlotsInput {
    static func list(_ source: String) throws -> [String] {
        var items = try TikZScanner.split(source, at: ",")
        if items.last == "" { items.removeLast() }
        guard items.count <= 2_000 else { throw TikZError("pgfplots: list") }
        return items
    }

    struct Option {
        let key: String
        let value: String?
        let original: String
    }

    static func options(_ text: String) throws -> [Option] {
        try list(text).map { option in
            let pair = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = pair.first, !name.isEmpty else { throw TikZError("pgfplots: option") }
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.dropFirst().first.map { String($0).tikzUnbraced }
            return Option(key: key, value: value, original: option)
        }
    }

    static func dictionary(_ text: String, allowed: Set<String>) throws -> [String: String] {
        var values: [String: String] = [:]
        var unknown: [String] = []
        for option in try options(text) {
            if allowed.contains(option.key) {
                values[option.key] = option.value ?? "true"
            } else {
                unknown.append(option.key)
            }
        }
        guard unknown.isEmpty else { throw TikZError(unknown.prefix(16).joined(separator: ", ")) }
        return values
    }

    static func number(_ value: String) throws -> Double {
        let raw = value.tikzUnbraced
        if let n = Double(raw), n.isFinite { return n }
        return try PGFMath.evaluate(raw)
    }

    static func length(_ value: String) throws -> Double {
        for (suffix, scale) in [
            ("cm", 72.27 / 2.54), ("mm", 72.27 / 25.4), ("pt", 1.0), ("bp", 72.27 / 72), ("in", 72.27),
        ] where value.hasSuffix(suffix) {
            let n = try number(String(value.dropLast(suffix.count))) * scale
            guard n.isFinite, n > 0, n <= 10_000 else { throw TikZError(value) }
            return n
        }
        throw TikZError(value)
    }
}

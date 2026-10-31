import Foundation

/// Language identifiers shared by the UI and resource catalogs. Chinese scripts stay distinct.
public enum UILanguage {
    public static let supported = ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"]

    public static func candidates(for identifier: String) -> [String] {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-")
        guard let base = parts.first else { return ["en"] }
        if base == "zh" {
            let script = parts.dropFirst().first { $0 == "Hans" || $0 == "Hant" }
            return [normalized] + (script.map { ["zh-\($0)"] } ?? []) + ["en"]
        }
        return [normalized, String(base), "en"]
    }

    public static func name(_ names: [String: String], language: String, english: String) -> String {
        for candidate in candidates(for: language) {
            if let name = names[candidate], !name.isEmpty { return name }
        }
        return english
    }

    public static func names(english: String, japanese: String?, localized: [String: String]?) -> [String: String] {
        var names = localized ?? [:]
        names["en"] = names["en"] ?? english
        if let japanese { names["ja"] = names["ja"] ?? japanese }
        return names
    }

    public static func label(for identifier: String, in language: String) -> String {
        let translated = Locale(identifier: language).localizedString(forIdentifier: identifier) ?? identifier
        let native = Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
        return translated == native ? native : "\(translated) \(native)"
    }
}

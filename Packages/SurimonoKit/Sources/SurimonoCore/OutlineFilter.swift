import Foundation

public enum OutlineFilter: Sendable {
    public static func matches(in entries: [OutlineEntry], query: String) -> [Int] {
        let words = query.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
        guard !words.isEmpty else { return Array(entries.indices) }
        return entries.indices.filter { index in
            let title = normalized(entries[index].title)
            return words.allSatisfy { title.contains($0) }
        }
    }

    private static func normalized(_ text: String) -> String {
        let compatible = text.decomposedStringWithCompatibilityMapping
        let kana = compatible.applyingTransform(.hiraganaToKatakana, reverse: false) ?? compatible
        return kana.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

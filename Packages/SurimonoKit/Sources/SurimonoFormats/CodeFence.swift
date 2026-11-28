import Foundation

/// A fenced code block's info string: the language word, and a file name written with it.
///
/// cmark hands over the whole info string. Its first word names the language; a `title="…"` attribute
/// (MkDocs, Docusaurus) or a `lang:name` suffix (Qiita, Zenn) names the file shown above the code.
struct CodeFence: Equatable {
    var language: String?
    var title: String?

    init(_ info: String?) {
        let info = (info ?? "").trimmingCharacters(in: .whitespaces)
        let word = info.prefix { !$0.isWhitespace }
        var language = word.isEmpty ? nil : String(word)
        if let colon = word.firstIndex(of: ":"), colon != word.startIndex, word.index(after: colon) != word.endIndex {
            language = String(word[..<colon])
            title = String(word[word.index(after: colon)...])
        }
        self.language = language
        if let match = info.dropFirst(word.count).firstMatch(
            of: /(?:^|\s)title\s*=\s*(?:"([^"]*)"|'([^']*)'|(\S+))/)
        {
            let value = String(match.1 ?? match.2 ?? match.3 ?? "")
            if !value.isEmpty { title = value }
        }
    }
}

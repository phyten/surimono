import Foundation

/// Class options that change the printed text block or the choice of a built-in style.
/// Other options (paper stock, two columns, etc.) remain under Surimono's print settings.
public struct LaTeXDocumentClassInfo: Sendable, Equatable {
    public let isJapanese: Bool
    public let hasChapters: Bool
    public internal(set) var styleVariables = ""
    public internal(set) var localFontFaces = ""
    public let pointSize: Int
    public internal(set) var mainLanguage: String
    let name: String
    let usesTraditionalJapaneseNames: Bool

    init(name: String = "article", options: String? = nil) {
        self.name = name
        let options = (options ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // English journal classes such as jmlr also start with j. Recognise the Japanese class
        // families and the traditional horizontal/vertical classes instead of the first letter.
        let japanese = [
            "jlreq", "jarticle", "jreport", "jbook", "ujarticle", "ujreport", "ujbook",
            "utarticle", "utreport", "utbook", "tarticle", "treport", "tbook",
        ]
        isJapanese = japanese.contains(name) || ["js", "ltjs", "bxjs"].contains { name.hasPrefix($0) }
        usesTraditionalJapaneseNames = japanese.contains(name) && name != "jlreq"
        if isJapanese {
            mainLanguage = options.contains("english") ? "en" : "ja"
        } else if ["ctexart", "ctexrep", "ctexbook"].contains(name) {
            mainLanguage = options.contains("traditional") ? "zh-Hant" : "zh-Hans"
        } else {
            mainLanguage = name == "oblivoir" ? "ko" : "en"
        }
        let chapterClasses = [
            "report", "book", "jreport", "jbook", "jsreport", "jsbook", "ltjsbook", "ltjsreport", "bxjsbook",
            "bxjsreport", "memoir", "scrbook", "scrreprt", "ujreport", "ujbook", "amsbook", "ctexrep", "ctexbook",
            "utreport", "utbook", "treport", "tbook",
        ]
        hasChapters =
            chapterClasses.contains(name)
            || name == "jlreq" && !Set(options).isDisjoint(with: ["book", "report"])
        pointSize =
            options.last(where: { ["10pt", "11pt", "12pt"].contains($0) })
            .flatMap { Int($0.dropLast(2)) } ?? 10
    }
}

extension LaTeXConverter {
    /// Read the preamble, including language options following the class declaration. Reuse the reader's handling of comments, definitions,
    /// and untaken branches so a quoted example of a Japanese class cannot select that style for an article.
    public static func documentClassInfo(
        _ text: String, documentURL: URL? = nil, readFile: @escaping (URL) -> Data? = { _ in nil },
        fileIdentity: @escaping (URL) -> URL = { $0.standardizedFileURL }
    ) -> LaTeXDocumentClassInfo {
        let document = LaTeXDocument()
        if documentURL != nil || text.contains("\\") {
            document.mainURL = documentURL
            document.directory = documentURL?.deletingLastPathComponent()
            document.readFile = readFile
            document.fileIdentity = fileIdentity
            let reader = LaTeXReader(TextDecoding.normalizeNewlines(text), document: document, isBlock: false)
            reader.readPreamble()
        }
        return document.typesettingInfo
    }
}

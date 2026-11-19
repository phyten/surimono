import Foundation

/// Class options that change the printed text block or the choice of a built-in style.
/// The app still chooses the output stock. The document's stock determines its intended margins.
public struct LaTeXDocumentClassInfo: Sendable, Equatable {
    public let isJapanese: Bool
    let hidesTitlePageNumber: Bool
    public let hasChapters: Bool
    public internal(set) var styleVariables = ""
    public internal(set) var localFontFaces = ""
    public internal(set) var pageNumbers = LaTeXPageNumbers()
    public internal(set) var mainFontName: String?
    public internal(set) var columns: Int
    public let hasSeparateTitlePage: Bool?
    public let usesJSChapterSpacing: Bool
    public let pointSize: Int
    public internal(set) var mainLanguage: String
    var resolvedPageBox: LaTeXPageBox?
    public var pageBox: LaTeXPageBox { resolvedPageBox ?? LaTeXPageSettings().pageBox(for: self) }
    public internal(set) var usesNativeCJKHeadings: Bool
    package var isJSArticle: Bool { name == "jsarticle" || name == "ltjsarticle" || name == "bxjsarticle" }
    package let name: String
    package let journalStyle: LaTeXJournalStyle?
    let publication: LaTeXPublicationLayout?
    var bookStyle = LaTeXBookStyle()
    let isKOMA: Bool
    let usesTraditionalJapaneseNames: Bool

    init(name: String = "article", options: String? = nil) {
        self.name = name
        let options = (options ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        isKOMA = ["scrartcl", "scrreprt", "scrbook"].contains(name)
        if isKOMA { bookStyle.readOptions(options) }
        journalStyle = LaTeXJournalStyle(name: name, options: options)
        publication = LaTeXPublicationLayout(name: name, options: options)
        pageNumbers = LaTeXPageNumbers(name: name, options: options)
        // These classes select their own first-page style at maketitle, independently of the running style.
        hidesTitlePageNumber =
            ["elsarticle", "llncs"].contains(name) || name == "IEEEtran" && options.contains("conference")
        let jsClasses = [
            "jsarticle", "ltjsarticle", "bxjsarticle", "jsreport", "ltjsreport", "bxjsreport", "jsbook", "ltjsbook",
            "bxjsbook",
        ]
        usesJSChapterSpacing = jsClasses.contains(name) && !name.hasSuffix("article")
        if ["article", "report", "book"].contains(name) || jsClasses.contains(name) {
            hasSeparateTitlePage =
                options.last(where: { $0 == "titlepage" || $0 == "notitlepage" }).map { $0 == "titlepage" }
                ?? !name.hasSuffix("article")
        } else if name == "scrartcl" {
            let titlePages = ["titlepage", "titlepage=true", "titlepage=firstiscover"]
            hasSeparateTitlePage =
                options.last { titlePages.contains($0) || $0 == "notitlepage" || $0 == "titlepage=false" }
                .map { titlePages.contains($0) } ?? false
        } else {
            hasSeparateTitlePage = nil
        }
        let usesTwoColumns =
            name == "IEEEtran" || publication == .sigconf || publication == .elsevierFive
            || name.hasPrefix("revtex") && options.contains("reprint")
            || name.lowercased().hasPrefix("icml")
        columns =
            (options.last { ["onecolumn", "twocolumn"].contains($0) }).map { $0 == "twocolumn" ? 2 : 1 }
            ?? (usesTwoColumns ? 2 : 1)
        // These two production layouts fix the grid after article has processed its options.
        if publication == .elsevierOne { columns = 1 }
        if publication == .elsevierFive { columns = 2 }
        // English journal classes such as jmlr also start with j. Recognise the Japanese class
        // families and the traditional horizontal/vertical classes instead of the first letter.
        let japanese = [
            "jlreq", "jarticle", "jreport", "jbook", "ltjarticle", "ltjreport", "ltjbook", "ujarticle", "ujreport",
            "ujbook",
            "utarticle", "utreport", "utbook", "tarticle", "treport", "tbook",
        ]
        isJapanese = japanese.contains(name) || ["js", "ltjs", "bxjs"].contains { name.hasPrefix($0) }
        usesNativeCJKHeadings = isJapanese || ["ctexart", "ctexrep", "ctexbook", "oblivoir"].contains(name)
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
            "utreport", "utbook", "treport", "tbook", "ltjreport", "ltjbook",
        ]
        hasChapters =
            chapterClasses.contains(name)
            || name == "jlreq" && !Set(options).isDisjoint(with: ["book", "report"])
        let keyedSize = isKOMA
        pointSize =
            options.map { keyedSize && $0.hasPrefix("fontsize=") ? String($0.dropFirst(9)) : $0 }
            .last(where: { ["10pt", "11pt", "12pt"].contains($0) })
            .flatMap { Int($0.dropLast(2)) }
            ?? (publication == .aps && options.contains("preprint")
                ? 12 : isKOMA || name == "moderncv" ? 11 : 10)
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

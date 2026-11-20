import Foundation

/// Class options that change the printed text block or the choice of a built-in style.
/// The app still chooses the output stock. The document's stock determines its intended margins.
public struct LaTeXDocumentClassInfo: Sendable, Equatable {
    package let profile: LaTeXClassProfile
    public var isJapanese: Bool { profile.typography.usesJapaneseStyle }
    var usesAMSA4Layout: Bool { profile.page.usesAMSA4Layout }
    var hidesTitlePageNumber: Bool { profile.pageStyle.hidesTitlePageNumber }
    public var hasChapters: Bool { profile.structure.hasChapters }
    public internal(set) var styleVariables = ""
    public internal(set) var localFontFaces = ""
    public internal(set) var pageNumbers: LaTeXPageNumbers
    public internal(set) var mainFontName: String?
    public internal(set) var columns: Int
    public var hasSeparateTitlePage: Bool? { profile.structure.titlePage.isSeparate }
    public var usesJSChapterSpacing: Bool { profile.structure.usesJSChapterSpacing }
    package var jsMagnification: Double? { profile.typography.jsMagnification }
    package var japaneseMainFontName: String?
    package var headerStrutDepth: Double = 0
    // setspace indexes its compensation by @ptsize, which jsclasses holds at zero for all magnifications.
    var spacingPointSize: Int { jsMagnification == nil ? pointSize : 10 }
    public var pointSize: Int { profile.typography.pointSize }
    public internal(set) var mainLanguage: String
    var resolvedPageBox: LaTeXPageBox?
    public var pageBox: LaTeXPageBox { resolvedPageBox ?? LaTeXPageSettings().pageBox(for: self) }
    public internal(set) var usesNativeCJKHeadings: Bool
    package var isJSArticle: Bool { profile.structure.usesJSArticleHeadings }
    package var name: String { profile.name }
    package var journalStyle: LaTeXJournalStyle? { profile.journalStyle }
    var publication: LaTeXPublicationLayout? { profile.page.publication }
    var bookStyle: LaTeXBookStyle
    var isKOMA: Bool { profile.page.usesTypeArea }
    var usesTraditionalJapaneseNames: Bool { profile.structure.usesTraditionalJapaneseNames }

    init(name: String = "article", options: String? = nil) {
        let request = LaTeXClassRequest(name: name, options: (options ?? "").split(separator: ",").map(String.init))
        profile = LaTeXClassRegistry.resolve(request)
        bookStyle = profile.initialBookStyle
        pageNumbers = LaTeXPageNumbers(profile.pageStyle)
        columns = profile.structure.columns
        mainLanguage = profile.typography.mainLanguage
        usesNativeCJKHeadings = profile.structure.usesNativeCJKHeadings
    }

    // Equality describes the current typesetting state. Later commands can erase differences between class options.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.isJapanese == rhs.isJapanese && lhs.usesAMSA4Layout == rhs.usesAMSA4Layout
            && lhs.hidesTitlePageNumber == rhs.hidesTitlePageNumber && lhs.hasChapters == rhs.hasChapters
            && lhs.styleVariables == rhs.styleVariables && lhs.localFontFaces == rhs.localFontFaces
            && lhs.pageNumbers == rhs.pageNumbers && lhs.mainFontName == rhs.mainFontName && lhs.columns == rhs.columns
            && lhs.hasSeparateTitlePage == rhs.hasSeparateTitlePage
            && lhs.usesJSChapterSpacing == rhs.usesJSChapterSpacing
            && lhs.jsMagnification == rhs.jsMagnification && lhs.japaneseMainFontName == rhs.japaneseMainFontName
            && lhs.headerStrutDepth == rhs.headerStrutDepth && lhs.pointSize == rhs.pointSize
            && lhs.mainLanguage == rhs.mainLanguage && lhs.resolvedPageBox == rhs.resolvedPageBox
            && lhs.usesNativeCJKHeadings == rhs.usesNativeCJKHeadings && lhs.journalStyle == rhs.journalStyle
            && lhs.publication == rhs.publication && lhs.bookStyle == rhs.bookStyle && lhs.isKOMA == rhs.isKOMA
            && lhs.usesTraditionalJapaneseNames == rhs.usesTraditionalJapaneseNames
    }
}

extension LaTeXConverter {
    /// Read the preamble, including language options following the class declaration. Reuse the reader's handling of comments, definitions,
    /// and untaken branches so a quoted example of a Japanese class cannot select that style for an article.
    public static func documentClassInfo(
        _ text: String, fontIndex: InstalledFontIndex = .system, documentURL: URL? = nil,
        readFile: @escaping (URL) -> Data? = { _ in nil },
        fileIdentity: @escaping (URL) -> URL = { $0.standardizedFileURL }
    ) -> LaTeXDocumentClassInfo {
        let document = LaTeXDocument(fontIndex: fontIndex)
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

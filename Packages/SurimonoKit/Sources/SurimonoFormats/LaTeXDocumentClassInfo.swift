import Foundation

public enum LaTeXComposition: String, CaseIterable, Codable, Sendable {
    case document, twoColumn, proof

    package static let notesMarginMM = 40.0
}

public enum LaTeXRecognition: Equatable, Sendable {
    public enum Mode: String, Sendable { case submission, final, preprint, rebuttal, draft }

    public struct Name: Equatable, Sendable {
        private let standard: String
        private let japanese: String?

        init(_ standard: String, japanese: String? = nil) {
            self.standard = standard
            self.japanese = japanese
        }

        public func text(japanese: Bool) -> String {
            japanese ? self.japanese ?? standard : standard
        }
    }

    case recognised(name: Name, detail: Mode?, source: String)
    case substituted(requestedClass: String)
}

/// Class options that change the printed text block or the choice of a built-in style.
/// The app still chooses the output stock. The document's stock determines its intended margins.
public struct LaTeXDocumentClassInfo: Sendable, Equatable {
    package let profile: LaTeXClassProfile
    package var resolvedStyle: LaTeXResolvedStyle?
    public internal(set) var offersCompositionChoice = false
    public internal(set) var composition = LaTeXComposition.document
    var classDeclaration: String?
    var styleDeclaration: String?

    public var recognition: LaTeXRecognition? {
        if let style = resolvedStyle, let source = styleDeclaration {
            return .recognised(name: .init(style.displayName), detail: style.mode, source: source)
        }
        guard let source = classDeclaration else { return nil }
        guard let name = profile.displayName else { return .substituted(requestedClass: profile.name) }
        return .recognised(name: name, detail: nil, source: source)
    }

    var initialLineParameters = ""
    package var latinLineAttributes: String {
        guard profile.body.composesLatinParagraphs else { return "" }
        let family = resolvedStyle == nil ? "cm" : "times"
        var contexts = profile.body.lineContexts
        if let resolvedStyle {
            // The conference stylesheet already supplies the mark box and the note's indentation.
            contexts?.footnote.fontSizePt = resolvedStyle.noteSize
            contexts?.footnote.firstIndentEm = nil
        }
        let glue = resolvedStyle?.usesNewTimesGlue == true ? " data-latex-context-glue=\"newtx\"" : ""
        return " data-latex-line-breaking=\"\(family)\"" + initialLineParameters + (contexts?.attribute ?? "") + glue
    }
    public var isJapanese: Bool { profile.typography.usesJapaneseStyle }
    var usesAMSA4Layout: Bool { profile.page.usesAMSA4Layout }
    var hidesTitlePageNumber: Bool { resolvedStyle?.firstPageNotice != nil || profile.pageStyle.hidesTitlePageNumber }
    public var hasChapters: Bool { profile.structure.hasChapters }
    public internal(set) var styleVariables = ""
    public internal(set) var localFontFaces = ""
    public internal(set) var pageNumbers: LaTeXPageNumbers
    public internal(set) var mainFontName: String?
    public internal(set) var columns: Int
    public var hasSeparateTitlePage: Bool? { profile.structure.titlePage.isSeparate }
    package var usesNaturalTableCaptionHeight: Bool { profile.body.naturalTableCaptionHeight && resolvedStyle == nil }
    public var usesJSChapterSpacing: Bool { profile.structure.usesJSChapterSpacing }
    package var jsMagnification: Double? { profile.typography.jsMagnification }
    package var japaneseFurnitureScale: Double { LaTeXLabelMetrics(self).japaneseScale ?? 1 }
    package var japaneseMainFontName: String?
    package var normalStrutDepth: Double { 0.3 * LaTeXLabelMetrics(self).baselines[4] * 72 / 72.27 }
    package var headerStrutDepth: Double = 0
    // setspace indexes its compensation by @ptsize, which jsclasses holds at zero for all magnifications.
    var spacingPointSize: Int { profile.typography.spacingDesignSize ?? pointSize }
    public var pointSize: Int { resolvedStyle?.pointSize ?? profile.typography.pointSize }
    public internal(set) var mainLanguage: String
    var resolvedPageBox: LaTeXPageBox?
    public var pageBox: LaTeXPageBox { resolvedPageBox ?? LaTeXPageSettings().pageBox(for: self) }
    public internal(set) var usesNativeCJKHeadings: Bool
    package var isJSArticle: Bool { profile.structure.usesJSArticleHeadings }
    package var name: String { profile.name }
    package var journalStyle: LaTeXJournalStyle? { profile.journalStyle }
    package var publicationGridStyle: String? { profile.titleBlock.societyLayout?.rawValue }
    package var usesPublicationGrid: Bool { profile.page.fixedGrid != nil }
    package var raggedColumns: Bool
    var publication: LaTeXPublicationLayout? { profile.page.publication }
    var bookStyle: LaTeXBookStyle
    var isKOMA: Bool { profile.page.usesTypeArea }
    var usesTraditionalJapaneseNames: Bool { profile.structure.usesTraditionalJapaneseNames }

    // Each document gets its own mutable settings; the default class resolves only once.
    static let article = Self(
        profile: LaTeXClassRegistry.resolve(.init(name: LaTeXClassID.article.rawValue, options: [])))

    init() { self = Self.article }

    init(name: String, options: String? = nil) {
        let request = LaTeXClassRequest(name: name, options: (options ?? "").split(separator: ",").map(String.init))
        if request.isDefaultArticle {
            self = Self.article
        } else {
            self.init(profile: LaTeXClassRegistry.resolve(request))
        }
    }

    private init(profile: LaTeXClassProfile) {
        self.profile = profile
        bookStyle = profile.initialBookStyle
        pageNumbers = LaTeXPageNumbers(profile.pageStyle)
        columns = profile.structure.columns
        raggedColumns = profile.page.fixedGrid?.raggedColumns ?? false
        mainLanguage = profile.typography.mainLanguage
        usesNativeCJKHeadings = profile.structure.usesNativeCJKHeadings
    }

    // Equality describes the current typesetting state. Later commands can erase differences between class options.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.composition == .proof) == (rhs.composition == .proof) && lhs.resolvedStyle == rhs.resolvedStyle
            && lhs.profile.structure.bookOpening == rhs.profile.structure.bookOpening
            && lhs.initialLineParameters == rhs.initialLineParameters
            && lhs.profile.headings.endDots == rhs.profile.headings.endDots
            && lhs.raggedColumns == rhs.raggedColumns && lhs.name == rhs.name && lhs.isJapanese == rhs.isJapanese
            && lhs.usesAMSA4Layout == rhs.usesAMSA4Layout
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
        _ text: String, composition: LaTeXComposition = .document, fontIndex: InstalledFontIndex = .system,
        documentURL: URL? = nil,
        readFile: @escaping (URL) -> Data? = { _ in nil },
        fileIdentity: @escaping (URL) -> URL = { $0.standardizedFileURL }
    ) -> LaTeXDocumentClassInfo {
        let document = LaTeXDocument(fontIndex: fontIndex)
        document.requestedComposition = composition
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

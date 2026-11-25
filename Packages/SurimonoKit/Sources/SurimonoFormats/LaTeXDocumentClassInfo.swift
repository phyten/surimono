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
    public var beamerPageSize: CGSize? { profile.page.slideSize }
    public var beamerFontSize: Double { profile.page.slideFontSize }
    public internal(set) var unsupportedBeamerTheme: String?
    public internal(set) var unreadableBeamerFrames = 0
    public internal(set) var beamerUsesSerifText = false
    public internal(set) var beamerSections: [BeamerSection] = []
    var beamerUsesSerifMath = false
    package var isVertical: Bool { profile.structure.isVertical }
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
    package var declaredPaperSize: CGSize?
    package var linksReferences = false
    package var pageBackReferences = false
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
        lhs.sameSlides(as: rhs) && lhs.sameComposition(as: rhs) && lhs.samePageStyle(as: rhs)
            && lhs.sameTypography(as: rhs) && lhs.samePublication(as: rhs)
    }

    private func sameSlides(as rhs: Self) -> Bool {
        self.beamerPageSize == rhs.beamerPageSize
            && self.beamerFontSize == rhs.beamerFontSize
            && self.unsupportedBeamerTheme == rhs.unsupportedBeamerTheme
            && self.unreadableBeamerFrames == rhs.unreadableBeamerFrames
            && self.beamerSections == rhs.beamerSections
            && self.beamerUsesSerifText == rhs.beamerUsesSerifText
            && self.beamerUsesSerifMath == rhs.beamerUsesSerifMath
            && self.profile.page.handout == rhs.profile.page.handout
            && self.profile.page.slideAlignment == rhs.profile.page.slideAlignment
    }

    private func sameComposition(as rhs: Self) -> Bool {
        (self.composition == .proof) == (rhs.composition == .proof)
            && self.resolvedStyle == rhs.resolvedStyle
            && self.isVertical == rhs.isVertical
            && self.profile.structure.declaredOpening == rhs.profile.structure.declaredOpening
            && self.profile.structure.bookOpening == rhs.profile.structure.bookOpening
            && self.declaredPaperSize == rhs.declaredPaperSize
            && self.linksReferences == rhs.linksReferences
            && self.pageBackReferences == rhs.pageBackReferences
            && self.initialLineParameters == rhs.initialLineParameters
            && self.profile.headings.endDots == rhs.profile.headings.endDots
    }

    private func samePageStyle(as rhs: Self) -> Bool {
        self.raggedColumns == rhs.raggedColumns
            && self.name == rhs.name
            && self.isJapanese == rhs.isJapanese
            && self.usesAMSA4Layout == rhs.usesAMSA4Layout
            && self.hidesTitlePageNumber == rhs.hidesTitlePageNumber
            && self.hasChapters == rhs.hasChapters
            && self.styleVariables == rhs.styleVariables
            && self.localFontFaces == rhs.localFontFaces
            && self.pageNumbers == rhs.pageNumbers
            && self.mainFontName == rhs.mainFontName
            && self.columns == rhs.columns
    }

    private func sameTypography(as rhs: Self) -> Bool {
        self.hasSeparateTitlePage == rhs.hasSeparateTitlePage
            && self.usesJSChapterSpacing == rhs.usesJSChapterSpacing
            && self.jsMagnification == rhs.jsMagnification
            && self.japaneseMainFontName == rhs.japaneseMainFontName
            && self.headerStrutDepth == rhs.headerStrutDepth
            && self.pointSize == rhs.pointSize
    }

    private func samePublication(as rhs: Self) -> Bool {
        self.mainLanguage == rhs.mainLanguage
            && self.resolvedPageBox == rhs.resolvedPageBox
            && self.usesNativeCJKHeadings == rhs.usesNativeCJKHeadings
            && self.journalStyle == rhs.journalStyle
            && self.publication == rhs.publication
            && self.bookStyle == rhs.bookStyle
            && self.isKOMA == rhs.isKOMA
            && self.usesTraditionalJapaneseNames == rhs.usesTraditionalJapaneseNames
    }
}

extension LaTeXConverter {
    /// Read the preamble, including language options following the class declaration. Reuse the reader's handling of comments, definitions,
    /// and untaken branches so a quoted example of a Japanese class cannot select that style for an article.
    /// The callbacks run on the converter's own thread while the caller waits for it (`StackSpace.onLargeStack`):
    /// they must not need the caller's thread or actor, and do not see its task-local values.
    public static func documentClassInfo(
        _ text: String, composition: LaTeXComposition = .document, fontIndex: InstalledFontIndex = .system,
        documentURL: URL? = nil,
        readFile: @escaping @Sendable (URL) -> Data? = { _ in nil },
        fileIdentity: @escaping @Sendable (URL) -> URL = { $0.standardizedFileURL }
    ) -> LaTeXDocumentClassInfo {
        StackSpace.onLargeStack {
            readClassPreamble(
                text, composition: composition, fontIndex: fontIndex, documentURL: documentURL, readFile: readFile,
                fileIdentity: fileIdentity
            ).typesettingInfo
        }
    }

    /// Document and proof read the same preamble. Two-column can change class options while reading it.
    package static func classInfos(
        _ text: String, composition: LaTeXComposition, documentURL: URL?,
        readFile: @escaping @Sendable (URL) -> Data?, fileIdentity: @escaping @Sendable (URL) -> URL
    ) -> (requested: LaTeXDocumentClassInfo, related: [LaTeXComposition: LaTeXDocumentClassInfo]) {
        StackSpace.onLargeStack {
            let document = readClassPreamble(
                text, composition: composition, fontIndex: .system, documentURL: documentURL, readFile: readFile,
                fileIdentity: fileIdentity)
            let info = document.typesettingInfo
            if composition == .twoColumn { return (info, [:]) }
            let other: LaTeXComposition = composition == .proof ? .document : .proof
            document.requestedComposition = other
            return (info, [other: info.offersCompositionChoice ? document.typesettingInfo : info])
        }
    }

    private static func readClassPreamble(
        _ text: String, composition: LaTeXComposition, fontIndex: InstalledFontIndex, documentURL: URL?,
        readFile: @escaping (URL) -> Data?, fileIdentity: @escaping (URL) -> URL
    ) -> LaTeXDocument {
        let document = LaTeXDocument(fontIndex: fontIndex)
        document.requestedComposition = composition
        if documentURL != nil || text.contains("\\") {
            document.mainURL = documentURL
            document.directory = documentURL?.deletingLastPathComponent()
            document.readFile = readFile
            document.fileIdentity = fileIdentity
            let reader = LaTeXReader(classifying: text, document: document)
            reader.readPreamble()
        }
        return document
    }
}

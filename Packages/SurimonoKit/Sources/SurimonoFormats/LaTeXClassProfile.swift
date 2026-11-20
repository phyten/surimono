import Foundation

package struct LaTeXClassRequest: Equatable, Sendable {
    let name: String
    let options: [String]

    init(name: String, options: [String]) {
        self.name = name
        self.options = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

// Body commands can change the working column count, language and furniture independently of the class line.
package struct LaTeXClassProfile: Equatable, Sendable {
    enum TitlePage: Equatable, Sendable {
        case inline, separate, unmodelled

        var isSeparate: Bool? {
            switch self {
            case .inline: false
            case .separate: true
            case .unmodelled: nil
            }
        }
    }

    struct Structure: Equatable, Sendable {
        var hasChapters = false
        var titlePage = TitlePage.unmodelled
        // Differs from journalStyle today; kept apart until each consumer is checked against real LaTeX.
        var columns = 1
        // Differs from typography.usesJapaneseStyle today; kept apart until each consumer is checked against real LaTeX.
        var contents = ContentsStyle.plain
        var usesJSArticleHeadings: Bool { contents == .sectionTitle }
        var usesJSChapterSpacing: Bool { contents == .chapterMarks }
        var usesNativeCJKHeadings = false
        var usesTraditionalJapaneseNames = false
    }

    enum ChapterLabel: Equatable, Sendable {
        case localized, bareNumber, spacedJapaneseNumber
    }

    enum BibliographyHeading: Equatable, Sendable {
        case inherited, section, chapter, rule, none
    }

    enum ContentsStyle: Equatable, Sendable {
        case plain, sectionTitle, chapterMarks
    }

    struct Headings: Equatable, Sendable {
        var chapterLabel = ChapterLabel.localized
        var readsParagraphMark = false
        // Chapter classes read the mark but supply no default glyph; kept apart until each consumer is checked against real LaTeX.
        var defaultParagraphMark: String?
        var labelsAppendixSection = false
        var wrapsChapterTitle = false
        // Chapter labels also apply to chapterless jlreq; kept apart until each consumer is checked against real LaTeX.
        var emptyPartPage = false
        // AMS and jlreq mark headings without enabling grid flow; kept apart until each consumer is checked against real LaTeX.
        var marksHeadingLevel = false
        var smallCapsSections = false
        var navigationOnlySections = false
        var readsElementFonts = false
        var readsChapterStyle = false
        var unprefixedChapterCounters = false
        var bibliography = BibliographyHeading.inherited
    }

    struct TitleBlock: Equatable, Sendable {
        var keywordSeparator = ", "
        // IEEE options may disable the journal style alone; kept apart until each consumer is checked against real LaTeX.
        var defaultKeywordLabel = "Keywords:"
        var usesAffiliationLabels = false
        var readsShortInstitute = false
        // REVTeX accepts supplied dates in journal front matter; kept apart until each consumer is checked against real LaTeX.
        var includesDate = true
        var notesOnVerso = false
        var noteDateLabel = "Received by the editors"
        var writesAuthorMarks = false
        // The title block also requests empty for amsbook; kept apart until each consumer is checked against real LaTeX.
        var pageStyle: String?
    }

    enum Correspondence: Equatable, Sendable {
        case none, letter, curriculumVitae
    }

    enum CaptionSkip: Equatable, Sendable {
        case inherited, fiveScaledPoints, halfBaseline
    }

    enum StandardMeasure: Equatable, Sendable {
        case inherited, doubleColumn, bookOffsets, letterOffsets
    }

    enum LayoutRule: Equatable, Sendable {
        case typeArea, ruledBook
        case ams(footSkip: Double)
        case exam, characterGrid
        case scaledGrid(scale: Double, bookMeasure: Bool, centersFurniture: Bool)
        case standard(StandardMeasure)
    }

    enum BaselineTable: Equatable, Sendable {
        case standard
        case scaled(magnification: Double, smallBelow: Double)
        case characterGrid, ams, traditional
    }

    struct Body: Equatable, Sendable {
        var correspondence = Correspondence.none
        var readsQuestions = false
        var readsFrames = false
        var numbersCaptions = true
        // Both APS modes use a bibliography rule, only preprint sizes figure rules naturally; kept apart until each consumer is checked against real LaTeX.
        var naturalRuleHeight = false
        var usesSizeFileGlue = false
        var usesListingDesignSize = false
        // Unstyled captions consult the body language; kept apart until each consumer is checked against real LaTeX.
        var styledCaptionSeparator: String?
        var untranslatedProofName: String?
        var spacesLinkedCounters = false
        var captionSkip = CaptionSkip.inherited
        var usesScaledTableMetrics = false
        var alignsDisplayRows = false
        var alignsHangingCaptions = false
    }

    enum Paper: String, Equatable, Sendable {
        case a4 = "a4paper"
        case letter = "letterpaper"

        var millimetres: (Double, Double) {
            switch self {
            case .a4: (210, 297)
            case .letter: (215.9, 279.4)
            }
        }
    }

    enum PaperOptions: Equatable, Sendable {
        case standard, keyed, japanese
    }

    struct Page: Equatable, Sendable {
        var layoutRule = LayoutRule.standard(.inherited)
        var paperOptions = PaperOptions.standard
        var defaultPaper = Paper.letter
        var forcedPaper: Paper?
        // Differs from pageStyle.twoSidedFields today; kept apart until each consumer is checked against real LaTeX.
        var twoSidedBox = false
        var usesFixedClassOrigin = false
        var usesTypeArea: Bool { layoutRule == .typeArea }
        // Differs from forcedPaper today; kept apart until each consumer is checked against real LaTeX.
        var usesAMSA4Layout = false
        var publication: LaTeXPublicationLayout?
    }

    struct Typography: Equatable, Sendable {
        var usesJapaneseStyle = false
        var mainLanguage = "en"
        var pointSize = 10
        var baselineTable = BaselineTable.standard
        var selectsParagraphPitch = false
        // Heading faces extend to prefix-only classes, unlike the scaled body face; kept apart until each consumer is checked against real LaTeX.
        var selectsGothicHeadings = false
        var prefersHiraginoSansW4 = false
        var usesScaledBodyFont = false
        var spacingDesignSize: Int?
        var jsMagnification: Double?
    }

    enum RunningStyle: Equatable, Sendable {
        case plain
        case ams(fontSize: Double)
        case exam, empty, runningHeads
    }

    struct PageStyle: Equatable, Sendable {
        var running = RunningStyle.plain
        var japanesePlain = false
        // Differs from page.twoSidedBox today; kept apart until each consumer is checked against real LaTeX.
        var twoSidedFields = false
        // Differs from twoSidedFields today; kept apart until each consumer is checked against real LaTeX.
        var twoSidedNumbers = false
        var hidesTitlePageNumber = false
    }

    enum FrontMatter: Equatable, Sendable {
        case standard, journal
    }

    package enum Style: Equatable, Sendable {
        case japanese, chaptered, sectioned
    }

    package var defaultStyle: Style {
        if typography.usesJapaneseStyle { return .japanese }
        return structure.hasChapters ? .chaptered : .sectioned
    }

    let name: String
    let id: LaTeXClassID
    let headings: Headings
    let titleBlock: TitleBlock
    let body: Body
    // Prefix matches select Japanese typography without the grid flow; kept apart until each consumer is checked against real LaTeX.
    package let usesGridFlow: Bool
    let structure: Structure
    let page: Page
    let typography: Typography
    let pageStyle: PageStyle
    // Differs from frontMatter and page.publication today; kept apart until each consumer is checked against real LaTeX.
    let journalStyle: LaTeXJournalStyle?
    let frontMatter: FrontMatter
    let classCommands: Set<String>
    let initialBookStyle: LaTeXBookStyle
}

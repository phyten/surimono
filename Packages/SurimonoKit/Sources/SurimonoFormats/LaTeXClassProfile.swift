import Foundation

package struct LaTeXClassRequest: Equatable, Sendable {
    let name: String
    let options: [String]

    init(name: String, options: [String]) {
        self.name = name
        self.options = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

package enum LaTeXClassID: String, CaseIterable, Sendable {
    case article, report, book, letter, amsart, amsbook, amsproc
    case ieeetran = "IEEEtran"
    case llncs, acmart, elsarticle
    case revtex42 = "revtex4-2"
    case scrartcl, scrreprt, scrbook, memoir, exam, moderncv, beamer
    case jsarticle, jsreport, jsbook, ltjsarticle, ltjsreport, ltjsbook, bxjsarticle, bxjsreport, bxjsbook
    case jlreq, jarticle, jreport, jbook, ltjarticle, ltjreport, ltjbook, ujarticle, ujreport, ujbook
    case utarticle, utreport, utbook, tarticle, treport, tbook, ctexart, ctexrep, ctexbook, oblivoir
    case unknown
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
        var usesJSArticleHeadings = false
        var usesJSChapterSpacing = false
        var usesNativeCJKHeadings = false
        var usesTraditionalJapaneseNames = false
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
        var paperOptions = PaperOptions.standard
        var defaultPaper = Paper.letter
        var forcedPaper: Paper?
        // Differs from pageStyle.twoSidedFields today; kept apart until each consumer is checked against real LaTeX.
        var twoSidedBox = false
        var usesFixedClassOrigin = false
        var usesTypeArea = false
        // Differs from forcedPaper today; kept apart until each consumer is checked against real LaTeX.
        var usesAMSA4Layout = false
        var publication: LaTeXPublicationLayout?
    }

    struct Typography: Equatable, Sendable {
        var usesJapaneseStyle = false
        var mainLanguage = "en"
        var pointSize = 10
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

    let name: String
    let id: LaTeXClassID
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

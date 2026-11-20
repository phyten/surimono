import Foundation

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

enum LaTeXClassRegistry {
    private enum Match: Sendable {
        case names([LaTeXClassID])
        case prefix(String)
        case lowercasePrefix(String)

        func matches(_ name: String) -> Bool {
            switch self {
            case .names(let ids): ids.contains { $0.rawValue == name }
            case .prefix(let prefix): name.hasPrefix(prefix)
            case .lowercasePrefix(let prefix): name.lowercased().hasPrefix(prefix)
            }
        }
    }

    private struct Rule: Sendable {
        let match: Match
        let build: @Sendable (LaTeXClassRequest) -> LaTeXClassProfile

        init(_ match: Match, _ configure: @escaping @Sendable (inout Builder) -> Void) {
            self.match = match
            build = { request in
                var builder = Builder(request: request)
                configure(&builder)
                return builder.resolve()
            }
        }
    }

    static var registeredNames: [String] {
        rules.flatMap { rule -> [String] in
            guard case .names(let ids) = rule.match else { return [] }
            return ids.map(\.rawValue)
        }
    }

    static func resolve(_ request: LaTeXClassRequest) -> LaTeXClassProfile {
        if let rule = rules.first(where: { $0.match.matches(request.name) }) { return rule.build(request) }
        // The article metrics also serve unknown names, whose title-page convention is unmodelled.
        var fallback = Builder(request: request)
        return fallback.resolve()
    }

    // Prefix-only matches retain unknown identity. Exact JS and REVTeX definitions must take precedence.
    private static let rules: [Rule] = [
        Rule(.names([.article, .report, .book])) { builder in
            builder.structure.hasChapters = builder.id != .article
            builder.setStandardTitlePage(separate: builder.structure.hasChapters)
            builder.setBookSides(builder.id == .book)
            builder.headings.wrapsChapterTitle = builder.structure.hasChapters
            builder.page.layoutRule = .standard(builder.id == .book ? .bookOffsets : .doubleColumn)
            builder.body.usesSizeFileGlue = true
            builder.body.usesListingDesignSize = true
        },
        Rule(.names([.amsart, .amsproc, .amsbook])) { builder in
            builder.structure.contentsMeasure = .init(
                dotSeparationMu: nil, pageNumberWidth: "1.6em", rightMargin: "2.6em")
            builder.structure.hasChapters = builder.id == .amsbook
            builder.journal(.ams, commands: Commands.ams)
            let book = builder.id == .amsbook
            builder.page.layoutRule = .ams(footSkip: book ? 18 : 12)
            builder.typography.baselineTable = .ams
            builder.headings.marksHeadingLevel = true
            builder.headings.smallCapsSections = builder.id == .amsart
            if builder.id == .amsproc {
                builder.titleBlock.uprightClassificationYear = true
                builder.body.proceedingsTheoremStyle = true
                builder.page.usesFixedClassOrigin = true
                builder.body.equationNumberOnLeft = builder.options.last { $0 == "leqno" || $0 == "reqno" } != "reqno"
            }
            builder.headings.unprefixedChapterCounters = book
            builder.titleBlock.notesOnVerso = book
            builder.titleBlock.writesAuthorMarks = !book
            builder.titleBlock.includesDate = false
            builder.titleBlock.pageStyle = book ? "empty" : "plain"
            if builder.id == .amsart { builder.titleBlock.noteDateLabel = "Date:" }
            builder.page.usesAMSA4Layout = builder.options.contains("a4paper")
            builder.page.forcedPaper = .letter
            builder.page.twoSidedBox = true
            // AMS installs its running heads after the fancy field order has been selected.
            builder.pageStyle.running = .ams(fontSize: Double((builder.explicitSize ?? 10) - 3))
            builder.pageStyle.twoSidedNumbers = true
        },
        Rule(.names([.ieeetran])) { builder in
            let conference = builder.options.contains("conference")
            builder.titleBlock.includesDate = false
            builder.titleBlock.defaultKeywordLabel = "Index Terms—"
            let ieeeStyle = Set(builder.options).isDisjoint(with: ["compsoc", "transmag"])
            builder.journal(ieeeStyle ? .ieee : nil, commands: Commands.ieee)
            builder.page.publication = conference ? .ieeeConference : .ieeeJournal
            builder.structure.columns = 2
            builder.pageStyle.hidesTitlePageNumber = conference
            builder.pageStyle.running = conference ? .empty : .plain
        },
        Rule(.names([.llncs])) { builder in
            builder.structure.contentsMeasure = .init(dotSeparationMu: 2, pageNumberWidth: "2em", rightMargin: "3.5em")
            builder.journal(.lncs, commands: Commands.lncs)
            builder.page.publication = .lncs
            builder.titleBlock.includesDate = false
            builder.titleBlock.keywordSeparator = " · "
            builder.page.usesFixedClassOrigin = true
            builder.pageStyle.hidesTitlePageNumber = true
            builder.pageStyle.twoSidedFields = true
            builder.pageStyle.twoSidedNumbers = true
            builder.pageStyle.running = builder.options.contains("runningheads") ? .runningHeads : .empty
        },
        Rule(.names([.acmart])) { builder in
            builder.structure.contentsMeasure = .init(
                dotSeparationMu: nil, pageNumberWidth: "1.6em", rightMargin: "2.6em")
            builder.journal(nil, commands: Commands.acm)
            builder.titleBlock.includesDate = false
            let formats = [
                "manuscript", "acmsmall", "acmlarge", "acmtog", "sigconf", "siggraph", "sigplan", "sigchi", "sigchi-a",
                "acmengage", "acmcp",
            ]
            let format = builder.options.map { $0.hasPrefix("format=") ? String($0.dropFirst(7)) : $0 }.last(
                where: formats.contains)
            if format == nil || format == "manuscript" || format == "sigconf" {
                builder.page.publication = format == "sigconf" ? .sigconf : .manuscript
                builder.structure.columns = format == "sigconf" ? 2 : 1
                builder.page.twoSidedBox = true
                builder.page.forcedPaper = .letter
            }
        },
        Rule(.names([.elsarticle])) { builder in
            builder.journal(.elsevier, commands: Commands.elsevier)
            builder.titleBlock.includesDate = false
            builder.titleBlock.usesAffiliationLabels = true
            builder.body.naturalRuleHeight = true
            builder.pageStyle.hidesTitlePageNumber = true
            switch builder.options.last(where: { ["1p", "3p", "5p", "preprint"].contains($0) }) {
            case "1p": builder.page.publication = .elsevierOne
            case "3p": builder.page.publication = .elsevierThree
            case "5p": builder.page.publication = .elsevierFive
            default: break
            }
            if builder.page.publication?.usesA4 == true {
                builder.page.defaultPaper = .a4
                builder.page.forcedPaper = .a4
            }
        },
        Rule(.names([.revtex42])) { builder in
            builder.revtex()
            if Set(builder.options).isDisjoint(with: ["aip", "aapm", "sor"]) {
                let mode = builder.options.last { $0 == "preprint" || $0 == "reprint" }
                builder.journalStyle = mode == "preprint" ? .apsPreprint : .aps
                builder.headings.bibliography = .rule
                builder.body.naturalRuleHeight = mode == "preprint"
            }
            builder.page.publication = .aps
            builder.page.usesFixedClassOrigin = true
            if builder.options.contains("preprint") { builder.typography.pointSize = 12 }
        },
        Rule(.names([.scrartcl, .scrreprt, .scrbook])) { builder in
            builder.structure.hasChapters = builder.id != .scrartcl
            builder.setBookSides(builder.id == .scrbook)
            if builder.id == .scrbook {
                builder.setBookOpening(numberInHead: false)
                builder.headings.runningNumberSeparator = "\u{2002}"
                builder.bookStyle.fonts["pagehead"] = LaTeXElementFont(shape: "oblique")
                builder.structure.readsMatterOptions = true
                builder.structure.backMatterOpensRight = builder.structure.bookOpening == .left
                switch builder.options.last(where: { $0.hasPrefix("numbers=") }) {
                case "numbers=enddot", "numbers=endperiod", "numbers=withenddot", "numbers=withendperiod",
                    "numbers=periodatend", "numbers=dotatend":
                    builder.headings.endDots = .always
                case "numbers=noenddot", "numbers=noendperiod", "numbers=noperiodatend", "numbers=nodotatend": break
                default: builder.headings.endDots = .automatic
                }
            }
            builder.page.paperOptions = .keyed
            builder.page.defaultPaper = .a4
            builder.typography.pointSize = 11
            builder.keyedSize = true
            builder.classCommands = Commands.koma
            builder.bookStyle.readOptions(builder.options)
            builder.headings.chapterLabel = .bareNumber
            builder.headings.readsElementFonts = true
            builder.page.layoutRule = .typeArea
            builder.body.naturalRuleHeight = true
            if builder.id == .scrartcl || builder.id == .scrbook {
                let separate = ["titlepage", "titlepage=true", "titlepage=firstiscover"]
                let selected = builder.options.last {
                    separate.contains($0) || $0 == "notitlepage" || $0 == "titlepage=false"
                }
                builder.structure.titlePage =
                    (selected.map(separate.contains) ?? (builder.id == .scrbook)) ? .separate : .inline
            }
        },
        Rule(.names([.memoir])) { builder in
            builder.structure.hasChapters = true
            builder.setBookSides(true)
            builder.classCommands = Commands.memoir
            builder.page.layoutRule = .ruledBook
            builder.headings.readsChapterStyle = true
            builder.body.captionSkip = .halfBaseline
            builder.body.naturalRuleHeight = true
        },
        Rule(.names([.letter])) { builder in
            builder.page.usesFixedClassOrigin = true
            builder.classCommands = Commands.letter
            builder.body.correspondence = .letter
            builder.page.layoutRule = .standard(.letterOffsets)
        },
        Rule(.names([.exam])) { builder in
            builder.page.usesFixedClassOrigin = true
            builder.pageStyle.running = .exam
            builder.classCommands = Commands.exam
            builder.body.readsQuestions = true
            builder.page.layoutRule = .exam
        },
        Rule(.names([.moderncv])) { builder in
            builder.page.defaultPaper = .a4
            builder.typography.pointSize = 11
            builder.classCommands = Commands.moderncv
            builder.body.correspondence = .curriculumVitae
        },
        Rule(.names([.beamer])) { builder in
            builder.classCommands = Commands.beamer
            builder.titleBlock.readsShortInstitute = true
            builder.headings.bibliography = .none
            builder.headings.navigationOnlySections = true
            builder.body.readsFrames = true
            builder.body.numbersCaptions = false
        },
        Rule(
            .names([
                .jsarticle, .ltjsarticle, .bxjsarticle, .jsreport, .ltjsreport, .bxjsreport, .jsbook, .ltjsbook,
                .bxjsbook,
            ])
        ) { builder in
            builder.japanese()
            let article = [.jsarticle, .ltjsarticle, .bxjsarticle].contains(builder.id)
            builder.structure.hasChapters = !article
            builder.setStandardTitlePage(separate: !article)
            let book = [.jsbook, .ltjsbook, .bxjsbook].contains(builder.id)
            builder.setBookSides(book)
            if book {
                builder.setBookOpening(numberInHead: true, ruled: true)
                builder.structure.contentsDepth = 1
                builder.structure.formatsContentsChapterNames = true
            }
            builder.pageStyle.japanesePlain = true
            let bx = [.bxjsarticle, .bxjsreport, .bxjsbook].contains(builder.id)
            let scale = magnification(builder.options, bx: bx)
            builder.typography.jsMagnification = scale
            builder.typography.baselineTable = .scaled(magnification: scale, smallBelow: bx ? 1 : 0.92)
            builder.typography.spacingDesignSize = 10
            builder.typography.usesScaledBodyFont = true
            builder.typography.selectsParagraphPitch = true
            builder.page.layoutRule = .scaledGrid(scale: scale, bookMeasure: book, centersFurniture: bx)
            builder.body.asteriskFootnotes = true
            builder.headings.chapterLabel = article ? .localized : .spacedJapaneseNumber
            builder.headings.marksHeadingLevel = true
            builder.headings.wrapsChapterTitle = !article
            builder.headings.emptyPartPage = !article
            builder.structure.contents = article ? .sectionTitle : .chapterMarks
            builder.headings.readsParagraphMark = true
            builder.headings.defaultParagraphMark = article ? "■" : nil
            builder.headings.labelsAppendixSection = article
            builder.headings.bibliography = article ? .section : .chapter
            builder.usesGridFlow = true
            builder.body.captionSkip = .fiveScaledPoints
            builder.body.usesScaledTableMetrics = true
            builder.body.alignsDisplayRows = true
            builder.body.alignsHangingCaptions = true
            builder.body.naturalRuleHeight = true
        },
        Rule(.names([.jlreq])) { builder in
            builder.structure.contentsMeasure = .init(dotSeparationMu: 2, pageNumberWidth: "2ic")
            builder.japanese()
            builder.keyedSize = true
            builder.structure.hasChapters = builder.options.contains("book") || builder.options.contains("report")
            builder.page.layoutRule = .characterGrid
            builder.typography.baselineTable = .characterGrid
            builder.headings.chapterLabel = .spacedJapaneseNumber
            builder.headings.emptyPartPage = builder.structure.hasChapters
            builder.headings.marksHeadingLevel = true
        },
        Rule(
            .names([
                .jarticle, .ltjarticle, .ujarticle, .utarticle, .tarticle, .jreport, .ltjreport, .ujreport, .utreport,
                .treport, .jbook, .ltjbook, .ujbook, .utbook, .tbook,
            ])
        ) { builder in
            builder.japanese()
            builder.structure.usesTraditionalJapaneseNames = true
            builder.typography.baselineTable = .traditional
            if [.ltjarticle, .jarticle, .ltjbook, .jbook].contains(builder.id) {
                let book = builder.id == .ltjbook || builder.id == .jbook
                builder.page.layoutRule = .standard(book ? .traditionalBook : .traditionalArticle)
                builder.setStandardTitlePage(separate: book)
                builder.setBookSides(book)
                builder.body.captionSeparator = ":\u{2002}"
                if book { builder.headings.chapterLabel = .traditionalJapaneseNumber }
                builder.headings.marksHeadingLevel = true
                builder.typography.selectsParagraphPitch = true
                if book {
                    builder.setBookOpening(numberInHead: true)
                    builder.structure.formatsContentsChapterNames = true
                }
            }
            builder.structure.hasChapters = ![.jarticle, .ltjarticle, .ujarticle, .utarticle, .tarticle].contains(
                builder.id)
        },
        Rule(.names([.ctexart, .ctexrep, .ctexbook])) { builder in
            builder.structure.hasChapters = builder.id != .ctexart
            builder.structure.usesNativeCJKHeadings = true
            builder.typography.mainLanguage = builder.options.contains("traditional") ? "zh-Hant" : "zh-Hans"
        },
        Rule(.names([.oblivoir])) { builder in
            builder.structure.usesNativeCJKHeadings = true
            builder.typography.mainLanguage = "ko"
        },
        Rule(.prefix("js")) { $0.japanese() },
        Rule(.prefix("ltjs")) { $0.japanese() },
        Rule(.prefix("bxjs")) { $0.japanese() },
        Rule(.prefix("revtex")) { $0.revtex() },
        Rule(.lowercasePrefix("icml")) { $0.structure.columns = 2 },
    ]

    private struct Builder: Sendable {
        let request: LaTeXClassRequest
        var id: LaTeXClassID { LaTeXClassID(rawValue: request.name) ?? .unknown }
        var options: [String] { request.options }
        var structure = LaTeXClassProfile.Structure()
        var page = LaTeXClassProfile.Page()
        var typography = LaTeXClassProfile.Typography()
        var headings = LaTeXClassProfile.Headings()
        var titleBlock = LaTeXClassProfile.TitleBlock()
        var body = LaTeXClassProfile.Body()
        var usesGridFlow = false
        var pageStyle = LaTeXClassProfile.PageStyle()
        var journalStyle: LaTeXJournalStyle?
        var frontMatter = LaTeXClassProfile.FrontMatter.standard
        var classCommands: Set<String> = []
        var bookStyle = LaTeXBookStyle()
        var keyedSize = false

        var explicitSize: Int? {
            options.lazy.map { keyedSize && $0.hasPrefix("fontsize=") ? String($0.dropFirst(9)) : $0 }
                .last(where: { ["10pt", "11pt", "12pt"].contains($0) }).flatMap { Int($0.dropLast(2)) }
        }

        mutating func setStandardTitlePage(separate: Bool) {
            let selected = options.last { $0 == "titlepage" || $0 == "notitlepage" }
            structure.titlePage = (selected.map { $0 == "titlepage" } ?? separate) ? .separate : .inline
        }

        mutating func setBookSides(_ twoSided: Bool) {
            page.twoSidedBox = twoSided
            pageStyle.twoSidedNumbers = twoSided
            pageStyle.twoSidedFields = twoSided
        }

        mutating func setBookOpening(numberInHead: Bool, ruled: Bool = false) {
            let opening = options.last {
                ["openright", "openleft", "openany", "open=right", "open=left", "open=any"].contains($0)
            }
            let twoSided = options.last { $0 == "oneside" || $0 == "twoside" } != "oneside"
            if !twoSided || opening == "openany" || opening == "open=any" {
                structure.bookOpening = .any
            } else {
                structure.bookOpening = opening == "openleft" || opening == "open=left" ? .left : .right
            }
            pageStyle.running = .markedBook(numberInHead: numberInHead, ruled: ruled)
        }

        mutating func japanese() {
            page.paperOptions = .japanese
            typography.usesJapaneseStyle = true
            typography.selectsGothicHeadings = true
            typography.prefersHiraginoSansW4 = true
            body.styledCaptionSeparator = ": "
            body.untranslatedProofName = "Proof"
            body.usesJapanesePunctuationMetrics = true
            body.spacesLinkedCounters = true
            typography.mainLanguage = options.contains("english") ? "en" : "ja"
            structure.usesNativeCJKHeadings = true
            page.defaultPaper = .a4
        }

        mutating func journal(_ style: LaTeXJournalStyle?, commands: Set<String>) {
            frontMatter = .journal
            journalStyle = style
            classCommands = commands
        }

        mutating func revtex() {
            journal(nil, commands: Commands.revtex)
            structure.columns = options.contains("reprint") ? 2 : 1
        }

        mutating func resolve() -> LaTeXClassProfile {
            if let size = explicitSize { typography.pointSize = size }
            if let side = options.last(where: { $0 == "twoside" || $0 == "oneside" }) {
                pageStyle.twoSidedFields = side == "twoside"
                pageStyle.twoSidedNumbers = side == "twoside"
            }
            if let columns = options.last(where: { $0 == "onecolumn" || $0 == "twocolumn" }) {
                structure.columns = columns == "twocolumn" ? 2 : 1
            }
            // These production grids override even an explicit column count.
            if page.publication == .elsevierOne { structure.columns = 1 }
            if page.publication == .elsevierFive { structure.columns = 2 }
            if pageStyle.hidesTitlePageNumber { titleBlock.pageStyle = "empty" }
            return LaTeXClassProfile(
                name: request.name, id: id, headings: headings, titleBlock: titleBlock, body: body,
                usesGridFlow: usesGridFlow, structure: structure, page: page, typography: typography,
                pageStyle: pageStyle, journalStyle: journalStyle, frontMatter: frontMatter,
                classCommands: classCommands, initialBookStyle: bookStyle)
        }
    }
}

private enum Commands {
    static let ams: Set<String> = ["address", "curraddr", "urladdr", "email", "keywords", "subjclass"]
    static let ieee: Set<String> = [
        "IEEEauthorblockN", "IEEEauthorblockA", "IEEEauthorrefmark", "IEEEkeywords", "IEEEcompsocitemizethanks",
    ]
    static let beamer: Set<String> = [
        "institute", "subtitle", "frame", "titlepage", "frametitle", "framesubtitle", "setbeamertemplate",
    ]
    static let lncs: Set<String> = ["institute", "inst", "email", "orcidID", "keywords"]
    static let acm: Set<String> = [
        "subtitle", "affiliation", "institution", "city", "country", "orcid", "email", "authornote",
        "authornotemark", "keywords", "ccsdesc",
    ]
    static let elsevier: Set<String> = [
        "affiliation", "address", "ead", "corref", "cortext", "fnref", "fntext", "tnoteref", "tnotetext", "sep",
    ]
    static let koma: Set<String> = [
        "subtitle", "publishers", "minisec", "addsec", "addchap", "setkomafont", "addtokomafont",
    ]
    static let memoir: Set<String> = ["epigraph", "chapterstyle"]
    static let exam: Set<String> = [
        "questions", "parts", "subparts", "choices", "oneparchoices", "checkboxes",
        "solution", "solutionorbox", "solutionorlines", "solutionordottedlines",
        "addpoints", "printanswers", "noprintanswers", "numquestions", "numpoints", "gradetable",
        "pointtable", "fillin", "makeemptybox", "fillwithlines", "fillwithdottedlines",
        "linefillheight", "dottedlinefillheight", "linefillthickness",
        "header", "footer", "firstpageheader", "firstpagefooter", "runningheader", "runningfooter",
    ]
    static let letter: Set<String> = [
        "letter", "name", "address", "signature", "opening", "closing", "ps", "cc", "encl",
    ]
    static let moderncv: Set<String> = [
        "moderncvstyle", "moderncvcolor", "name", "address", "phone", "social", "email", "homepage",
        "extrainfo", "photo", "makecvtitle", "cventry", "cvitem", "cvitemwithcomment", "cvdoubleitem",
        "cvlistitem", "cvlistdoubleitem",
    ]
    static let revtex: Set<String> = ["affiliation", "altaffiliation", "email", "keywords"]
}

extension LaTeXClassRegistry {
    // jsclasses magnifies a single design, including the Q and Japanese point-size options.
    // BXjs instead resolves jbase as a physical Japanese size before scaling its Latin design.
    private static func magnification(_ options: [String], bx: Bool) -> Double {
        let sizes: [String: Double] = [
            "8pt": bx ? 0.8 : 0.833, "9pt": bx ? 0.9 : 0.913, "10pt": 1, "11pt": 1.095,
            "12pt": 1.2, "14pt": 1.44, "17pt": 1.728, "20pt": 2, "21pt": 2.074, "25pt": 2.488,
            "30pt": 2.986, "36pt": 3.583, "43pt": 4.3, "12Q": 0.923, "14Q": 1.077,
            "10ptj": 1.085, "10.5ptj": 1.139, "11ptj": 1.194, "12ptj": 1.302,
        ]
        var scale = 1.0
        for option in options {
            if let value = sizes[option] { scale = value }
            let japanese = [
                "12Q": "12Q", "14Q": "14Q", "10ptj": "10pt", "10.5ptj": "10.5pt", "11ptj": "11pt", "12ptj": "12pt",
            ]
            if bx, let value = option.hasPrefix("jbase=") ? String(option.dropFirst(6)) : japanese[option] {
                let mm =
                    value.hasSuffix("Q")
                    ? Double(value.dropLast()).map { $0 / 4 }
                    : LaTeXPageSettings.millimetres(value)
                if let mm {
                    let factor = mm * 72.27 / 25.4 / 9.24715
                    if (0.2...10).contains(factor) { scale = floor((factor + 0.0001) * 1_000) / 1_000 }
                }
            }
        }
        return scale
    }
}

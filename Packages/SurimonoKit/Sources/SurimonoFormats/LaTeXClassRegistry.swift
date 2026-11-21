import Foundation

package enum LaTeXClassID: String, CaseIterable, Sendable {
    case article, report, book, letter, amsart, amsbook, amsproc
    case ieeetran = "IEEEtran"
    case llncs, acmart, elsarticle, ipsj, ieicej, ieice
    case revtex42 = "revtex4-2"
    case scrartcl, scrreprt, scrbook, memoir, exam, moderncv, beamer
    case jsarticle, jsreport, jsbook, ltjsarticle, ltjsreport, ltjsbook, bxjsarticle, bxjsreport, bxjsbook
    case jlreq, jarticle, jreport, jbook, ltjarticle, ltjreport, ltjbook, ujarticle, ujreport, ujbook
    case utarticle, utreport, utbook, tarticle, treport, tbook, ctexart, ctexrep, ctexbook, oblivoir
    case unknown
}

extension LaTeXClassRequest {
    var isDefaultArticle: Bool { name == LaTeXClassID.article.rawValue && options.isEmpty }
}

enum LaTeXClassRegistry {
    private static let knownIDs = LaTeXClassID.allCases.filter { $0 != .unknown }
    static let registeredNames = knownIDs.map(\.rawValue)
    private static let idsByName = Dictionary(uniqueKeysWithValues: knownIDs.map { ($0.rawValue, $0) })

    static func resolve(_ request: LaTeXClassRequest) -> LaTeXClassProfile {
        let builder = Builder(request: request, id: idsByName[request.name] ?? .unknown)
        switch builder.id {
        case .article, .report, .book: standard(builder)
        case .amsart, .amsproc, .amsbook: ams(builder)
        case .ieeetran: ieee(builder)
        case .llncs: lncs(builder)
        case .acmart: acm(builder)
        case .elsarticle: elsevier(builder)
        case .revtex42: aps(builder)
        case .ipsj: informationProcessingJournal(builder)
        case .ieicej: japaneseTransactions(builder)
        case .ieice: englishTransactions(builder)
        case .scrartcl, .scrreprt, .scrbook: koma(builder)
        case .memoir: memoir(builder)
        case .letter: letter(builder)
        case .exam: exam(builder)
        case .moderncv: modernCV(builder)
        case .beamer: beamer(builder)
        case .jsarticle, .jsreport, .jsbook, .ltjsarticle, .ltjsreport, .ltjsbook, .bxjsarticle, .bxjsreport, .bxjsbook:
            scaledJapanese(builder)
        case .jlreq: japaneseLayout(builder)
        case .jarticle, .jreport, .jbook, .ltjarticle, .ltjreport, .ltjbook, .ujarticle, .ujreport, .ujbook,
            .utarticle, .utreport, .utbook, .tarticle, .treport, .tbook:
            traditionalJapanese(builder)
        case .ctexart, .ctexrep, .ctexbook: chinese(builder)
        case .oblivoir: korean(builder)
        case .unknown: applyFamilyPrefix(builder)
        }
        return builder.resolve()
    }

    // An unregistered name can inherit family defaults without acquiring the identity of an exact match.
    private static func applyFamilyPrefix(_ builder: Builder) {
        let name = builder.request.name
        if name.hasPrefix("js") || name.hasPrefix("ltjs") || name.hasPrefix("bxjs") {
            builder.japanese()
        } else if name.hasPrefix("revtex") {
            builder.revtex()
        } else if name.lowercased().hasPrefix("icml") {
            builder.structure.columns = 2
        }
    }

    private static func standard(_ builder: Builder) {
        builder.structure.hasChapters = builder.id != .article
        builder.setStandardTitlePage(separate: builder.structure.hasChapters)
        builder.setBookSides(builder.id == .book)
        builder.headings.wrapsChapterTitle = builder.structure.hasChapters
        builder.page.layoutRule = .standard(builder.id == .book ? .bookOffsets : .doubleColumn)
        builder.body.composesLatinParagraphs = true
        builder.body.usesSizeFileGlue = true
        builder.body.usesListingDesignSize = true
    }

    private static func ams(_ builder: Builder) {
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
    }

    private static func ieee(_ builder: Builder) {
        let conference = builder.options.contains("conference")
        builder.titleBlock.includesDate = false
        builder.titleBlock.defaultKeywordLabel = "Index Terms—"
        let ieeeStyle = Set(builder.options).isDisjoint(with: ["compsoc", "transmag"])
        builder.journal(ieeeStyle ? .ieee : nil, commands: Commands.ieee)
        builder.page.publication = conference ? .ieeeConference : .ieeeJournal
        builder.structure.columns = 2
        builder.pageStyle.hidesTitlePageNumber = conference
        builder.pageStyle.running = conference ? .empty : .plain
    }

    private static func lncs(_ builder: Builder) {
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
    }

    private static func acm(_ builder: Builder) {
        builder.structure.contentsMeasure = .init(
            dotSeparationMu: nil, pageNumberWidth: "1.6em", rightMargin: "2.6em")
        builder.journal(nil, commands: Commands.acm)
        builder.titleBlock.includesDate = false
        let format = builder.options.map { $0.hasPrefix("format=") ? String($0.dropFirst(7)) : $0 }.last(
            where: ClassOptions.acmFormats.contains)
        if format == nil || format == "manuscript" || format == "sigconf" {
            builder.page.publication = format == "sigconf" ? .sigconf : .manuscript
            builder.structure.columns = format == "sigconf" ? 2 : 1
            builder.page.twoSidedBox = true
            builder.page.forcedPaper = .letter
        }
    }

    private static func elsevier(_ builder: Builder) {
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
    }

    private static func aps(_ builder: Builder) {
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
    }

    private static func koma(_ builder: Builder) {
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
    }

    private static func memoir(_ builder: Builder) {
        builder.structure.hasChapters = true
        builder.setBookSides(true)
        builder.classCommands = Commands.memoir
        builder.page.layoutRule = .ruledBook
        builder.headings.readsChapterStyle = true
        builder.body.captionSkip = .halfBaseline
        builder.body.naturalRuleHeight = true
    }

    private static func letter(_ builder: Builder) {
        builder.page.usesFixedClassOrigin = true
        builder.classCommands = Commands.letter
        builder.body.correspondence = .letter
        builder.page.layoutRule = .standard(.letterOffsets)
    }

    private static func exam(_ builder: Builder) {
        builder.page.usesFixedClassOrigin = true
        builder.pageStyle.running = .exam
        builder.classCommands = Commands.exam
        builder.body.readsQuestions = true
        builder.page.layoutRule = .exam
    }

    private static func modernCV(_ builder: Builder) {
        builder.page.defaultPaper = .a4
        builder.typography.pointSize = 11
        builder.classCommands = Commands.moderncv
        builder.body.correspondence = .curriculumVitae
    }

    private static func beamer(_ builder: Builder) {
        builder.classCommands = Commands.beamer
        builder.titleBlock.readsShortInstitute = true
        builder.headings.bibliography = .none
        builder.headings.navigationOnlySections = true
        builder.body.readsFrames = true
        builder.body.numbersCaptions = false
    }

    private static func scaledJapanese(_ builder: Builder) {
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
    }

    private static func japaneseLayout(_ builder: Builder) {
        builder.structure.contentsMeasure = .init(dotSeparationMu: 2, pageNumberWidth: "2ic")
        builder.japanese()
        builder.keyedSize = true
        builder.structure.hasChapters = builder.options.contains("book") || builder.options.contains("report")
        builder.page.layoutRule = .characterGrid
        builder.typography.baselineTable = .characterGrid
        builder.headings.chapterLabel = .spacedJapaneseNumber
        builder.headings.emptyPartPage = builder.structure.hasChapters
        builder.headings.marksHeadingLevel = true
    }

    private static func traditionalJapanese(_ builder: Builder) {
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
    }

    private static func chinese(_ builder: Builder) {
        builder.structure.hasChapters = builder.id != .ctexart
        builder.structure.usesNativeCJKHeadings = true
        builder.typography.mainLanguage = builder.options.contains("traditional") ? "zh-Hant" : "zh-Hans"
    }

    private static func korean(_ builder: Builder) {
        builder.structure.usesNativeCJKHeadings = true
        builder.typography.mainLanguage = "ko"
    }

    // Class resolution may run on a rendering task with a small stack. Keep its working state on the heap;
    // callers receive only the completed value and never share the mutable builder.
    fileprivate final class Builder {
        let request: LaTeXClassRequest
        let id: LaTeXClassID

        init(request: LaTeXClassRequest, id: LaTeXClassID) {
            self.request = request
            self.id = id
        }

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
            options.lazy.map { self.keyedSize && $0.hasPrefix("fontsize=") ? String($0.dropFirst(9)) : $0 }
                .last(where: { ["10pt", "11pt", "12pt"].contains($0) }).flatMap { Int($0.dropLast(2)) }
        }

        func setStandardTitlePage(separate: Bool) {
            let selected = options.last { $0 == "titlepage" || $0 == "notitlepage" }
            structure.titlePage = (selected.map { $0 == "titlepage" } ?? separate) ? .separate : .inline
        }

        func setBookSides(_ twoSided: Bool) {
            page.twoSidedBox = twoSided
            pageStyle.twoSidedNumbers = twoSided
            pageStyle.twoSidedFields = twoSided
        }

        func setBookOpening(numberInHead: Bool, ruled: Bool = false) {
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

        func japanese() {
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

        func journal(_ style: LaTeXJournalStyle?, commands: Set<String>) {
            frontMatter = .journal
            journalStyle = style
            classCommands = commands
        }

        func revtex() {
            journal(nil, commands: Commands.revtex)
            structure.columns = options.contains("reprint") ? 2 : 1
        }

        func resolve() -> LaTeXClassProfile {
            if let size = explicitSize { typography.pointSize = size }
            if let side = options.last(where: { $0 == "twoside" || $0 == "oneside" }) {
                pageStyle.twoSidedFields = side == "twoside"
                pageStyle.twoSidedNumbers = side == "twoside"
            }
            if let columns = options.last(where: { $0 == "onecolumn" || $0 == "twocolumn" }) {
                structure.columns = columns == "twocolumn" ? 2 : 1
            }
            // The standard class files call \sloppy when starting their two-column body.
            body.usesSloppyLineBreaking = body.composesLatinParagraphs && structure.columns == 2
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
    static let transactions: Set<String> = [
        "authorlist", "authorentry", "MembershipNumber", "affiliate", "paffiliate", "field",
        "vol", "no", "jalcdoi", "received", "revised", "finalreceived", "onlinefirst", "publicized", "titlenote",
    ]
    static let informationProcessing: Set<String> = [
        "etitle", "affiliate", "paffiliate", "received", "accepted", "rereceived", "rerereceived",
        "受付", "再受付", "再再受付", "採録",
    ]
    static let japaneseTransactions: Set<String> = transactions.union([
        "jtitle", "etitle", "typeofletter", "jsubtitle", "esubtitle", "MailAddress", "tecrepyear",
    ])
    static let englishTransactions: Set<String> = transactions.union([
        "SpecialSection", "SpecialIssue", "theme", "breakauthorline", "titleadj",
    ])

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

private enum ClassOptions {
    static let englishJournals: Set<String> = ["english", "JIP", "preprint", "CVA", "TBIO", "SLDM"]
    static let journalJapanese: [String: String] = [
        "PRO": "プログラミング", "ACS": "コンピューティングシステム", "TOD": "データベース",
        "TOM": "数理モデル化と応用", "CDS": "コンシューマ・デバイス＆システム",
        "DC": "デジタルコンテンツ", "DCON": "デジタルコンテンツ", "TCE": "教育とコンピュータ",
    ]
    static let journalEnglish: [String: String] = [
        "PRO": "Programming", "ACS": "Advanced Computing Systems", "TOD": "Databases",
        "TOM": "Mathematical Modeling and Its Applications", "CDS": "Consumer Devices & Systems",
        "DC": "Digital Content", "DCON": "Digital Content", "TCE": "Computers and Education",
        "CVA": "Computer Vision and Applications", "TBIO": "Bioinformatics",
        "SLDM": "System LSI Design Methodology",
    ]
    static let yearOffsets: [String: Int] = [
        "JIP": 1992, "EEE": 1992, "PRO": 2007, "ACS": 2007, "TOD": 2007, "TOM": 2007, "TBIO": 2007,
        "SLDM": 2007, "CVA": 2008, "CDS": 2010, "DC": 2012, "DCON": 2012, "TCE": 2014,
    ]
    static let doiNames: [String: String] = [
        "JIP": "ipsjjip", "TBIO": "ipsjtbio", "CVA": "ipsjtcva", "SLDM": "ipsjtsldm",
    ]
    static let paperTypes: [String: (english: String, japanese: String)] = [
        "technote": ("Technical Note", "テクニカルノート"),
        "invited": ("Invited Paper", "招待論文"),
        "sigrecommended": ("Recommended Paper", "推薦論文"),
        "Short": ("Short Paper", "ショートペーパー"),
        "Practice": ("Practice Paper", "産業論文"), "Content": ("Content Paper", "作品論文"),
    ]
    static let japanesePaperTypes: [String: String] = [
        "letter": "研究速報", "electronicsletter": "レター", "invited": "招待論文",
        "comment": "解説論文", "survey": "サーベイ論文", "technicalreport": "技術研究報告",
    ]
    static let englishPaperTypes: [String: String] = [
        "invited": "INVITED PAPER", "position": "POSITION PAPER", "survey": "SURVEY PAPER",
        "review": "REVIEW PAPER", "tutorial": "TUTORIAL PAPER", "letter": "LETTER", "brief": "BRIEF PAPER",
        "invitedreview": "INVITED REVIEW PAPER", "invitedsurvey": "INVITED SURVEY PAPER",
    ]

    static let acmFormats: Set<String> = [
        "manuscript", "acmsmall", "acmlarge", "acmtog", "sigconf", "siggraph", "sigplan", "sigchi", "sigchi-a",
        "acmengage", "acmcp",
    ]
}

extension LaTeXClassRegistry {
    private static let jsSizes: [String: Double] = [
        "8pt": 0.833, "9pt": 0.913, "10pt": 1, "11pt": 1.095,
        "12pt": 1.2, "14pt": 1.44, "17pt": 1.728, "20pt": 2, "21pt": 2.074, "25pt": 2.488,
        "30pt": 2.986, "36pt": 3.583, "43pt": 4.3, "12Q": 0.923, "14Q": 1.077,
        "10ptj": 1.085, "10.5ptj": 1.139, "11ptj": 1.194, "12ptj": 1.302,
    ]
    private static let bxSizes = jsSizes.merging(["8pt": 0.8, "9pt": 0.9]) { _, bx in bx }
    private static let japaneseSizeNames = [
        "12Q": "12Q", "14Q": "14Q", "10ptj": "10pt", "10.5ptj": "10.5pt", "11ptj": "11pt", "12ptj": "12pt",
    ]

    // jsclasses magnifies a single design, including the Q and Japanese point-size options.
    // BXjs instead resolves jbase as a physical Japanese size before scaling its Latin design.
    private static func magnification(_ options: [String], bx: Bool) -> Double {
        let sizes = bx ? bxSizes : jsSizes
        var scale = 1.0
        for option in options {
            if let value = sizes[option] { scale = value }
            if bx, let value = option.hasPrefix("jbase=") ? String(option.dropFirst(6)) : japaneseSizeNames[option] {
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

extension LaTeXClassRegistry.Builder {
    fileprivate func optionValue<Value>(_ values: [String: Value]) -> Value? {
        for option in options.reversed() {
            if let value = values[option] { return value }
        }
        return nil
    }

    fileprivate func journalArticle(
        title: LaTeXClassProfile.SocietyTitle, paper: LaTeXClassProfile.Paper, japanese: Bool
    ) {
        structure.columns = 2
        page.defaultPaper = paper
        page.forcedPaper = paper
        titleBlock.societyLayout = title
        titleBlock.includesDate = false
        typography.usesJapaneseStyle = japanese
        typography.mainLanguage = japanese ? "ja" : "en"
        body.hangsPlainCaptions = japanese
        typography.selectsGothicHeadings = japanese
        structure.usesNativeCJKHeadings = japanese
        headings.displayParagraphs = true
        headings.marksHeadingLevel = true
        headings.numberingDepth = 5
        headings.sectionDot = true
        body.citationListSeparator = ", "
        body.captionSeparator = ""
        pageStyle.twoSidedFields = true
        pageStyle.twoSidedNumbers = true
    }
}

extension LaTeXClassRegistry {
    private static let millimetre = 72.27 / 25.4
    private static let quarterMillimetre = millimetre / 4

    private static func informationProcessingJournal(_ builder: Builder) {
        let english = builder.options.contains(where: ClassOptions.englishJournals.contains)
        builder.journalArticle(title: .bilingualJournal, paper: .a4, japanese: !english)
        builder.classCommands = Commands.informationProcessing
        let mm = Self.millimetre
        let q = Self.quarterMillimetre
        let size = english ? 13 * q : 13 * 0.7392507
        let pitch = (english ? 18 : 21) * q
        builder.page.fixedGrid = .init(
            width: floor(177 * mm), height: english ? floor(55 * pitch + 7.47 + 0.4 * mm) : 710,
            top: 72.27 - 2.5 * mm, headHeight: 5 * mm, headSep: 9.5 * mm, footSkip: 11.7 * mm,
            columnGap: 8 * mm, bodySize: size, pitch: pitch, characterWidth: english ? nil : 13 * q,
            charactersPerColumn: english ? nil : 26, indent: 13 * q, topSkip: 7.47, noteSize: 11 * 0.7392507,
            notePitch: 14 * q,
            noteSkip: 9, floatStretch: 0.75 * pitch, floatShrink: 0.25 * pitch,
            floatSize: .footnotesize, floatPitch: 18 * q, ruleWidth: 0.4, displaySkip: 8, tagInset: 3 * mm,
            floatSkip: pitch, textFloatSkip: pitch)
        builder.headings.numberingDepth = 3
        builder.headings.groupsParagraphsAtThirdLevel = true
        builder.body.asteriskFootnotes = true
        builder.body.enumLabels = .parentheses
        if english { builder.body.figName = "Fig." }
        builder.pageStyle.running = .journalIssueLine
        let type = builder.optionValue(ClassOptions.paperTypes)
        builder.titleBlock.paperTypeLabel = (english ? type?.english : type?.japanese) ?? ""
        builder.titleBlock.yearOffset = builder.optionValue(ClassOptions.yearOffsets) ?? (english ? 1992 : 1959)
        builder.pageStyle.journalDOIPrefix = builder.optionValue(ClassOptions.doiNames).map { "10.2197/" + $0 }
        if builder.options.contains("techrep") {
            builder.titleBlock.journalName = english ? "IPSJ SIG Technical Report" : "情報処理学会研究報告"
            builder.pageStyle.running = .journalReportTitle(bilingual: !english)
        } else if english {
            builder.titleBlock.journalName =
                builder.options.contains("JIP")
                ? "Journal of Information Processing"
                : builder.optionValue(ClassOptions.journalEnglish).map { "IPSJ Transactions on " + $0 }
                    ?? "IPSJ Journal"
        } else {
            builder.titleBlock.journalName =
                "情報処理学会論文誌" + (builder.optionValue(ClassOptions.journalJapanese).map { " " + $0 } ?? "")
        }
    }

    private static func japaneseTransactions(_ builder: Builder) {
        let technical = builder.options.contains("technicalreport")
        builder.journalArticle(title: .insetBilingual, paper: technical ? .a4 : .jisB5, japanese: true)
        let mm = Self.millimetre
        let q = Self.quarterMillimetre
        builder.classCommands = Commands.japaneseTransactions
        let zw = technical ? 9.0 : 12 * q
        let pitch = (technical ? 20.5 : 19) * q
        let topSkip = 0.88 * zw
        let height = (technical ? 49 : 43) * pitch + topSkip + 0.15 * mm
        let head = technical ? 0 : 3 * mm
        let sep = technical ? 0 : 6.25 * mm
        let foot = (technical ? 9.5 : 7.5) * mm
        builder.page.fixedGrid = .init(
            width: technical ? 57 * zw : 151.5 * mm, height: height,
            top: ((technical ? 297 : 257) * mm - height + head + sep - foot) / 2 - 1.25 * mm,
            headHeight: head, headSep: sep, footSkip: foot, columnGap: technical ? 2 * zw : 7.5 * mm,
            bodySize: 9, pitch: pitch, characterWidth: zw, raggedColumns: technical,
            charactersPerColumn: technical ? nil : 24,
            japaneseScales: technical
                ? nil
                : .init(
                    title: 18 * q / 12, author: 15 * q / 10.95, abstract: 11 * q / 8, note: 9 * q / 6,
                    caption: 10 * q / 7),
            indent: zw,
            topSkip: topSkip,
            noteSize: technical ? 7 : 6, notePitch: (technical ? 16 : 13) * q,
            noteSkip: pitch, noteStretch: 0.9 * pitch, noteShrink: 0.3 * pitch, floatStretch: 0.75 * pitch,
            floatShrink: 0.25 * pitch,
            floatSize: .small, floatPitch: (technical ? 18 : 13) * q, ruleWidth: 0.1 * mm, displaySkip: 9,
            tagInset: 3 * mm,
            floatSkip: pitch, textFloatSkip: 1.5 * pitch)
        builder.headings.distributesShortTitles = true
        builder.headings.counterForm = .spacedHierarchy
        builder.body.footnoteForm = .japaneseNote
        builder.body.enumLabels = .wideParentheses
        builder.body.referenceName = "文献"
        builder.body.citationListSeparator = ","
        builder.body.citationRangeSeparator = "〜"
        let letter = !Set(builder.options).isDisjoint(with: ["letter", "electronicsletter"])
        builder.titleBlock.inColumn = builder.options.contains("letter")
        builder.titleBlock.datesAtEnd = letter
        builder.titleBlock.englishInTitle = technical
        if letter { builder.pageStyle.runningArticleType = "レター" }
        builder.titleBlock.omitsEnglishSupplement = builder.options.contains("cameraready")
        builder.titleBlock.paperTypeLabel = builder.optionValue(ClassOptions.japanesePaperTypes) ?? "論文"
        builder.pageStyle.running = technical ? .technicalReportNotice : .ruledArticleType
    }

    private static func englishTransactions(_ builder: Builder) {
        builder.journalArticle(title: .framedPaper, paper: .journalTrim, japanese: false)
        builder.typography.defaultMainFont = "Times New Roman"
        let mm = Self.millimetre
        builder.classCommands = Commands.englishTransactions
        let referee = builder.options.contains("referee")
        if referee { builder.structure.columns = 1 }
        builder.page.fixedGrid = .init(
            width: 500, height: 668, top: 72.27 - 28 + 12.5 * mm, headHeight: 3 * mm, headSep: 9.5 * mm,
            footSkip: 0, columnGap: 8 * mm, bodySize: 10, pitch: 4.125 * mm * (referee ? 1.2 : 1),
            characterWidth: nil, raggedColumns: referee, indent: 7 * mm, topSkip: 10, noteSize: 9, notePitch: 3.5 * mm,
            noteSkip: 9, floatStretch: 4 * mm, floatShrink: 3 * mm,
            floatSize: .footnotesize, floatPitch: 3.375 * mm, ruleWidth: 0.4, displaySkip: 9, tagInset: 0,
            floatSkip: 7 * mm, textFloatSkip: 7 * mm)
        builder.headings.counterForm = .parenthesizedParagraph
        builder.body.figName = "Fig."
        builder.body.footnoteForm = .repeatedStar
        builder.body.enumLabels = .periods
        builder.body.citationRangeSeparator = "–"
        builder.titleBlock.paperTypeLabel = builder.optionValue(ClassOptions.englishPaperTypes) ?? "PAPER"
        if ["LETTER", "BRIEF PAPER"].contains(builder.titleBlock.paperTypeLabel) {
            builder.pageStyle.runningArticleType = builder.titleBlock.paperTypeLabel
        }
        builder.pageStyle.running = .outerHeadNumber
    }
}

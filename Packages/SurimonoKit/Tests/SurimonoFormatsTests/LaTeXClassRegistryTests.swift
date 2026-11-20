import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXClassRegistryTests {
    struct Defaults: Sendable {
        let names: [String]
        var chapters = false
        var title = LaTeXClassProfile.TitlePage.unmodelled
        var columns = 1
        var size = 10
        var language = "en"
        var nativeHeadings = false
        var traditionalNames = false
        var jsScale: Double?
        var jsArticle = false
        var jsChapters = false
        var typeArea = false
        var paper = LaTeXClassProfile.Paper.letter
        var forcedPaper: LaTeXClassProfile.Paper?
        var boxSides = false
        var fieldSides = false
        var numberSides = false
        var fixedOrigin = false
        var publication: LaTeXPublicationLayout?
        var running = LaTeXClassProfile.RunningStyle.plain
        var hiddenTitleNumber = false
        var journal: LaTeXJournalStyle?
        var journalFront = false
        var unknown = false
    }

    static let defaults: [Defaults] = [
        .init(names: ["article"], title: .inline),
        .init(names: ["report"], chapters: true, title: .separate),
        .init(names: ["book"], chapters: true, title: .separate, boxSides: true, fieldSides: true, numberSides: true),
        .init(names: ["letter"], fixedOrigin: true),
        .init(
            names: ["amsproc"], forcedPaper: .letter, boxSides: true, numberSides: true, fixedOrigin: true,
            running: .ams(fontSize: 7), journal: .ams, journalFront: true),
        .init(
            names: ["amsart"], forcedPaper: .letter, boxSides: true, numberSides: true,
            running: .ams(fontSize: 7), journal: .ams, journalFront: true),
        .init(
            names: ["amsbook"], chapters: true, forcedPaper: .letter, boxSides: true, numberSides: true,
            running: .ams(fontSize: 7), journal: .ams, journalFront: true),
        .init(names: ["IEEEtran"], columns: 2, publication: .ieeeJournal, journal: .ieee, journalFront: true),
        .init(
            names: ["llncs"], fieldSides: true, numberSides: true, fixedOrigin: true, publication: .lncs,
            running: .empty, hiddenTitleNumber: true, journal: .lncs, journalFront: true),
        .init(names: ["acmart"], forcedPaper: .letter, boxSides: true, publication: .manuscript, journalFront: true),
        .init(names: ["elsarticle"], hiddenTitleNumber: true, journal: .elsevier, journalFront: true),
        .init(names: ["revtex4-2"], fixedOrigin: true, publication: .aps, journal: .aps, journalFront: true),
        .init(names: ["scrartcl"], title: .inline, size: 11, typeArea: true, paper: .a4),
        .init(names: ["scrreprt"], chapters: true, size: 11, typeArea: true, paper: .a4),
        .init(
            names: ["scrbook"], chapters: true, title: .separate, size: 11, typeArea: true, paper: .a4,
            boxSides: true, fieldSides: true, numberSides: true, running: .markedBook(numberInHead: false, ruled: false)
        ),
        .init(names: ["memoir"], chapters: true, boxSides: true, fieldSides: true, numberSides: true),
        .init(names: ["exam"], fixedOrigin: true, running: .exam),
        .init(names: ["moderncv"], size: 11, paper: .a4),
        .init(names: ["beamer"]),
        .init(
            names: ["jsarticle", "ltjsarticle", "bxjsarticle"], title: .inline, language: "ja", nativeHeadings: true,
            jsScale: 1, jsArticle: true, paper: .a4),
        .init(
            names: ["jsreport", "ltjsreport", "bxjsreport"], chapters: true, title: .separate,
            language: "ja", nativeHeadings: true, jsScale: 1, jsChapters: true, paper: .a4),
        .init(
            names: ["jsbook", "ltjsbook", "bxjsbook"], chapters: true, title: .separate, language: "ja",
            nativeHeadings: true, jsScale: 1, jsChapters: true, paper: .a4, boxSides: true, fieldSides: true,
            numberSides: true, running: .markedBook(numberInHead: true, ruled: true)),
        .init(names: ["jlreq"], language: "ja", nativeHeadings: true, paper: .a4),
        .init(
            names: ["jarticle", "ltjarticle"], title: .inline, language: "ja",
            nativeHeadings: true, traditionalNames: true, paper: .a4),
        .init(
            names: ["jbook", "ltjbook"], chapters: true, title: .separate, language: "ja", nativeHeadings: true,
            traditionalNames: true, paper: .a4, boxSides: true, fieldSides: true, numberSides: true,
            running: .markedBook(numberInHead: true, ruled: false)),
        .init(
            names: ["ujarticle", "utarticle", "tarticle"], language: "ja",
            nativeHeadings: true, traditionalNames: true, paper: .a4),
        .init(
            names: [
                "jreport", "ltjreport", "ujreport", "utreport", "treport", "ujbook", "utbook",
                "tbook",
            ],
            chapters: true, language: "ja", nativeHeadings: true, traditionalNames: true, paper: .a4),
        .init(names: ["ctexart"], language: "zh-Hans", nativeHeadings: true),
        .init(names: ["ctexrep", "ctexbook"], chapters: true, language: "zh-Hans", nativeHeadings: true),
        .init(names: ["oblivoir"], language: "ko", nativeHeadings: true),
        .init(
            names: ["foo", "jmlr", "scrlttr2", "ieeetran", "ARTICLE", "JSarticle", "REVTeX4-2", " article "],
            unknown: true),
        .init(
            names: ["jsarticle-extra", "ltjs", "bxjsCustom"], language: "ja", nativeHeadings: true, paper: .a4,
            unknown: true),
        .init(names: ["revtex4-1", "revtex"], journalFront: true, unknown: true),
        .init(names: ["icml", "ICML2024"], columns: 2, unknown: true),
    ]

    @Test("全クラスの既定値は表題・言語・組版・ノンブルの従来の組み合わせになる", arguments: defaults)
    func defaultProfile(row: Defaults) {
        for name in row.names {
            let p = LaTeXClassRegistry.resolve(.init(name: name, options: []))
            #expect(p.name == name)
            #expect(p.id.rawValue == (row.unknown ? "unknown" : name))
            #expect(p.structure.hasChapters == row.chapters)
            #expect(p.structure.titlePage == row.title)
            #expect(p.structure.columns == row.columns)
            #expect(p.typography.pointSize == row.size)
            #expect(p.typography.mainLanguage == row.language)
            #expect(p.typography.usesJapaneseStyle == (row.language == "ja"))
            #expect(p.structure.usesNativeCJKHeadings == row.nativeHeadings)
            #expect(p.structure.usesTraditionalJapaneseNames == row.traditionalNames)
            #expect(p.typography.jsMagnification == row.jsScale)
            #expect(p.structure.usesJSArticleHeadings == row.jsArticle)
            #expect(p.structure.usesJSChapterSpacing == row.jsChapters)
            #expect(p.page.usesTypeArea == row.typeArea)
            #expect(p.page.defaultPaper == row.paper)
            #expect(p.page.forcedPaper == row.forcedPaper)
            #expect(p.page.twoSidedBox == row.boxSides)
            #expect(p.pageStyle.twoSidedFields == row.fieldSides)
            #expect(p.pageStyle.twoSidedNumbers == row.numberSides)
            #expect(p.page.usesFixedClassOrigin == row.fixedOrigin)
            #expect(p.page.publication == row.publication)
            #expect(p.pageStyle.running == row.running)
            #expect(p.pageStyle.japanesePlain == (row.jsScale != nil))
            #expect(p.pageStyle.hidesTitlePageNumber == row.hiddenTitleNumber)
            #expect(p.journalStyle == row.journal)
            #expect(p.frontMatter == (row.journalFront ? .journal : .standard))
        }
    }

    @Test("全クラスでオプションの順序と適用範囲を保つ", arguments: defaults)
    func commonOptions(row: Defaults) {
        for name in row.names {
            let p = LaTeXClassRegistry.resolve(
                .init(
                    name: name,
                    options: [
                        "12pt", " 11pt ", "onecolumn", "twocolumn", "notitlepage", "titlepage", "a4paper", "english",
                        "traditional",
                        "oneside", "twoside",
                    ]))
            #expect(p.typography.pointSize == 11)
            #expect(p.structure.columns == 2)
            #expect(p.structure.titlePage == (row.title == .unmodelled ? .unmodelled : .separate))
            #expect(p.page.usesAMSA4Layout == (row.journal == .ams))
            #expect(p.pageStyle.twoSidedFields && p.pageStyle.twoSidedNumbers)
            #expect(
                p.typography.mainLanguage
                    == (row.language == "zh-Hans" ? "zh-Hant" : row.language == "ko" ? "ko" : "en"))
            let reversed = LaTeXDocumentClassInfo(
                name: name, options: "twocolumn, onecolumn, 11pt,12pt,titlepage,notitlepage,twoside,oneside"
            ).profile
            #expect(reversed.typography.pointSize == 12)
            #expect(reversed.structure.columns == 1)
            #expect(reversed.structure.titlePage == (row.title == .unmodelled ? .unmodelled : .inline))
            #expect(!reversed.pageStyle.twoSidedFields && !reversed.pageStyle.twoSidedNumbers)
            let keyed = LaTeXDocumentClassInfo(name: name, options: "fontsize=12pt,book").profile
            #expect(keyed.typography.pointSize == (row.typeArea || name == "jlreq" ? 12 : row.size))
            #expect(keyed.structure.hasChapters == (row.chapters || name == "jlreq"))
        }
    }

    @Test("登録名は重複せず全識別子に到達できる")
    func registration() {
        let names = LaTeXClassRegistry.registeredNames
        #expect(names.count == Set(names).count)
        #expect(Set(names) == Set(Self.defaults.filter { !$0.unknown }.flatMap(\.names)))
        let ids = names.map { LaTeXClassRegistry.resolve(.init(name: $0, options: [])).id }
        #expect(Set(ids) == Set(LaTeXClassID.allCases.filter { $0 != .unknown }))
    }

    struct Publication: Sendable {
        let name: String
        let options: String
        let layout: LaTeXPublicationLayout?
        let style: LaTeXJournalStyle?
        let columns: Int
        var size = 10
        var paper: LaTeXClassProfile.Paper?
    }

    @Test(
        "出版クラスの段数・級数・用紙・雑誌スタイルはそれぞれの指定に従う",
        arguments: [
            Publication(name: "IEEEtran", options: "conference", layout: .ieeeConference, style: .ieee, columns: 2),
            .init(name: "IEEEtran", options: "conference,compsoc", layout: .ieeeConference, style: nil, columns: 2),
            .init(name: "IEEEtran", options: "transmag,onecolumn", layout: .ieeeJournal, style: nil, columns: 1),
            .init(name: "revtex4-2", options: "preprint,reprint", layout: .aps, style: .aps, columns: 2, size: 12),
            .init(
                name: "revtex4-2", options: "reprint,preprint", layout: .aps, style: .apsPreprint, columns: 2, size: 12),
            .init(name: "revtex4-2", options: "aip,reprint", layout: .aps, style: nil, columns: 2),
            .init(name: "revtex4-2", options: "aapm,preprint,11pt", layout: .aps, style: nil, columns: 1, size: 11),
            .init(name: "revtex4-2", options: "sor", layout: .aps, style: nil, columns: 1),
            .init(name: "revtex4-1", options: "preprint,reprint", layout: nil, style: nil, columns: 2),
            .init(
                name: "acmart", options: "manuscript,format=sigconf", layout: .sigconf, style: nil, columns: 2,
                paper: .letter),
            .init(
                name: "acmart", options: "sigconf,manuscript", layout: .manuscript, style: nil, columns: 1,
                paper: .letter),
            .init(name: "acmart", options: "sigconf,acmlarge", layout: nil, style: nil, columns: 1),
            .init(
                name: "elsarticle", options: "5p,1p,twocolumn", layout: .elsevierOne, style: .elsevier, columns: 1,
                paper: .a4),
            .init(
                name: "elsarticle", options: "3p,twocolumn", layout: .elsevierThree, style: .elsevier, columns: 2,
                paper: .a4),
            .init(name: "elsarticle", options: "3p", layout: .elsevierThree, style: .elsevier, columns: 1, paper: .a4),
            .init(
                name: "elsarticle", options: "1p,5p,onecolumn", layout: .elsevierFive, style: .elsevier, columns: 2,
                paper: .a4),
            .init(name: "elsarticle", options: "5p,preprint", layout: nil, style: .elsevier, columns: 1),
        ])
    func publication(row: Publication) {
        let p = LaTeXDocumentClassInfo(name: row.name, options: row.options).profile
        #expect(p.frontMatter == .journal)
        #expect(p.page.publication == row.layout)
        #expect(p.journalStyle == row.style)
        #expect(p.structure.columns == row.columns)
        #expect(p.typography.pointSize == row.size)
        #expect(p.page.forcedPaper == row.paper)
    }

    @Test("和文の倍率と章、KOMA の表題と版面指定を個別に読む")
    func classOptions() {
        for (name, options, scale) in [
            ("jsarticle", "8pt", 0.833), ("ltjsbook", "11pt,jbase=11pt", 1.095),
            ("bxjsreport", "8pt", 0.8), ("bxjsreport", "11pt,jbase=11pt", 1.189),
            ("bxjsarticle", "jbase=11pt,12pt", 1.2),
        ] {
            #expect(LaTeXDocumentClassInfo(name: name, options: options).jsMagnification == scale)
        }
        #expect(LaTeXDocumentClassInfo(name: "jlreq", options: "report").hasChapters)
        let koma = LaTeXDocumentClassInfo(
            name: "scrartcl",
            options: "titlepage=false,titlepage=firstiscover,DIV=12,BCOR=1in,headinclude,footinclude=false")
        #expect(koma.hasSeparateTitlePage == true)
        #expect(koma.bookStyle.division == "12")
        #expect(abs(koma.bookStyle.binding - 72.27) < 0.00001)
        #expect(koma.bookStyle.includeHead && !koma.bookStyle.includeFoot)
        #expect(
            LaTeXDocumentClassInfo(name: "scrartcl", options: "titlepage,titlepage=false").hasSeparateTitlePage == false
        )
        #expect(
            LaTeXDocumentClassInfo(name: "llncs", options: "runningheads").profile.pageStyle.running == .runningHeads)
        let conference = LaTeXDocumentClassInfo(name: "IEEEtran", options: "conference,compsoc")
        #expect(conference.hidesTitlePageNumber && conference.profile.pageStyle.running == .empty)
    }

    @Test("版面は値付きの両面指定を読み、ノンブルは単独の指定だけを読む")
    func sidedOptions() {
        for (name, option, mirrored, numbers) in [
            ("article", "twoside=false", false, false), ("article", "oneside=false", true, false),
            ("book", "twoside=false", false, true), ("llncs", "oneside", false, false),
            ("amsart", "oneside", false, false), ("acmart", "twoside", true, true),
        ] {
            let source = "\\documentclass[\(option)]{\(name)}"
            let info = LaTeXConverter.documentClassInfo(source)
            #expect(info.pageBox.mirrorsSides == mirrored)
            #expect(info.profile.pageStyle.twoSidedNumbers == numbers)
        }
    }

    @Test("本文で段数を揃えた文書の組版情報は等しい")
    func equalityAfterColumnChange() {
        var two = LaTeXDocumentClassInfo(name: "article", options: "twocolumn")
        two.columns = 1
        #expect(two == LaTeXDocumentClassInfo())
    }

    @Test("クラスが定義するコマンドは完全一致と REVTeX の前方一致に従う")
    func classCommands() {
        let commands: [([String], Set<String>)] = [
            (["amsart", "amsproc", "amsbook"], ["address", "curraddr", "urladdr", "email", "keywords", "subjclass"]),
            (
                ["IEEEtran"],
                [
                    "IEEEauthorblockN", "IEEEauthorblockA", "IEEEauthorrefmark", "IEEEkeywords",
                    "IEEEcompsocitemizethanks",
                ]
            ),
            (
                ["beamer"],
                ["institute", "subtitle", "frame", "titlepage", "frametitle", "framesubtitle", "setbeamertemplate"]
            ),
            (["llncs"], ["institute", "inst", "email", "orcidID", "keywords"]),
            (
                ["acmart"],
                [
                    "subtitle", "affiliation", "institution", "city", "country", "orcid", "email", "authornote",
                    "authornotemark", "keywords", "ccsdesc",
                ]
            ),
            (
                ["elsarticle"],
                [
                    "affiliation", "address", "ead", "corref", "cortext", "fnref", "fntext", "tnoteref", "tnotetext",
                    "sep",
                ]
            ),
            (
                ["scrartcl", "scrreprt", "scrbook"],
                ["subtitle", "publishers", "minisec", "addsec", "addchap", "setkomafont", "addtokomafont"]
            ),
            (["memoir"], ["epigraph", "chapterstyle"]),
            (
                ["exam"],
                [
                    "questions", "parts", "subparts", "choices", "oneparchoices", "checkboxes",
                    "solution", "solutionorbox", "solutionorlines", "solutionordottedlines",
                    "addpoints", "printanswers", "noprintanswers", "numquestions", "numpoints", "gradetable",
                    "pointtable", "fillin", "makeemptybox", "fillwithlines", "fillwithdottedlines",
                    "linefillheight", "dottedlinefillheight", "linefillthickness",
                    "header", "footer", "firstpageheader", "firstpagefooter", "runningheader", "runningfooter",
                ]
            ),
            (["letter"], ["letter", "name", "address", "signature", "opening", "closing", "ps", "cc", "encl"]),
            (
                ["moderncv"],
                [
                    "moderncvstyle", "moderncvcolor", "name", "address", "phone", "social", "email", "homepage",
                    "extrainfo", "photo", "makecvtitle", "cventry", "cvitem", "cvitemwithcomment", "cvdoubleitem",
                    "cvlistitem", "cvlistdoubleitem",
                ]
            ),
            (["revtex4-2", "revtex4-1", "revtex"], ["affiliation", "altaffiliation", "email", "keywords"]),
        ]
        let expected = Dictionary(
            uniqueKeysWithValues: commands.flatMap { names, commands in names.map { ($0, commands) } })
        for name in Self.defaults.flatMap(\.names) {
            let info = LaTeXDocumentClassInfo(name: name)
            #expect(info.profile.classCommands == (expected[name] ?? []))
        }
    }

    @Test("章・目次・参考文献の出力形式を登録名と未知の接頭辞ごとに保つ", arguments: defaults)
    func headingRules(row: Defaults) {
        for name in row.names {
            let profile = LaTeXDocumentClassInfo(name: name).profile
            let headings = profile.headings
            let scaled = row.jsArticle || row.jsChapters
            let label: LaTeXClassProfile.ChapterLabel =
                row.typeArea
                ? .bareNumber
                : ["ltjbook", "jbook"].contains(name)
                    ? .traditionalJapaneseNumber
                    : row.jsChapters || name == "jlreq" ? .spacedJapaneseNumber : .localized
            #expect(headings.chapterLabel == label)
            #expect(headings.runningNumberSeparator == (name == "scrbook" ? "\u{2002}" : " "))
            let measure = profile.structure.contentsMeasure
            switch name {
            case "amsart", "amsproc", "amsbook", "acmart":
                #expect(measure == .init(dotSeparationMu: nil, pageNumberWidth: "1.6em", rightMargin: "2.6em"))
            case "llncs":
                #expect(measure == .init(dotSeparationMu: 2, pageNumberWidth: "2em", rightMargin: "3.5em"))
            case "jlreq":
                #expect(measure == .init(dotSeparationMu: 2, pageNumberWidth: "2ic"))
            default:
                #expect(
                    measure.dotSeparationMu == 4.5 && measure.pageNumberWidth == "1.55em"
                        && measure.rightMargin == "2.55em")
            }
            #expect(profile.structure.contentsDepth == (["jsbook", "ltjsbook", "bxjsbook"].contains(name) ? 1 : nil))
            #expect(
                profile.structure.formatsContentsChapterNames
                    == (["jsbook", "ltjsbook", "bxjsbook", "jbook", "ltjbook"].contains(name)))
            #expect(profile.structure.readsMatterOptions == (name == "scrbook"))
            #expect(headings.endDots == (name == "scrbook" ? .automatic : .never))
            #expect(
                profile.structure.bookOpening
                    == (["scrbook", "jsbook", "ltjsbook", "bxjsbook", "jbook", "ltjbook"].contains(name) ? .right : nil)
            )
            #expect(
                profile.structure.contents == (row.jsArticle ? .sectionTitle : row.jsChapters ? .chapterMarks : .plain))
            #expect(headings.readsParagraphMark == scaled)
            #expect(headings.defaultParagraphMark == (row.jsArticle ? "■" : nil))
            #expect(headings.labelsAppendixSection == row.jsArticle)
            #expect(headings.wrapsChapterTitle == (row.jsChapters || ["report", "book"].contains(name)))
            #expect(headings.emptyPartPage == row.jsChapters)
            #expect(
                headings.marksHeadingLevel
                    == (["ltjarticle", "ltjbook", "jarticle", "jbook"].contains(name) || scaled || name == "jlreq"
                        || row.journal == .ams))
            #expect(headings.smallCapsSections == (name == "amsart"))
            #expect(headings.navigationOnlySections == (name == "beamer"))
            #expect(headings.readsElementFonts == row.typeArea)
            #expect(headings.readsChapterStyle == (name == "memoir"))
            #expect(headings.unprefixedChapterCounters == (name == "amsbook"))
            let bib: LaTeXClassProfile.BibliographyHeading
            switch name {
            case "beamer": bib = .none
            case "revtex4-2": bib = .rule
            default: bib = row.jsChapters ? .chapter : row.jsArticle ? .section : .inherited
            }
            #expect(headings.bibliography == bib)
        }
    }

    @Test("表題の所属・キーワード・日付・柱はクラスごとの組み合わせを保つ", arguments: defaults)
    func titleRules(row: Defaults) {
        for name in row.names {
            let title = LaTeXDocumentClassInfo(name: name).profile.titleBlock
            #expect(title.keywordSeparator == (name == "llncs" ? " · " : ", "))
            #expect(title.defaultKeywordLabel == (name == "IEEEtran" ? "Index Terms—" : "Keywords:"))
            #expect(title.usesAffiliationLabels == (name == "elsarticle"))
            #expect(title.readsShortInstitute == (name == "beamer"))
            let omitDate = ["amsart", "amsproc", "amsbook", "IEEEtran", "llncs", "acmart", "elsarticle"]
            #expect(title.includesDate == !omitDate.contains(name))
            #expect(title.notesOnVerso == (name == "amsbook"))
            #expect(title.noteDateLabel == (name == "amsart" ? "Date:" : "Received by the editors"))
            #expect(title.writesAuthorMarks == ["amsart", "amsproc"].contains(name))
            let style: String? =
                switch name {
                case "amsbook", "llncs", "elsarticle": "empty"
                case "amsart", "amsproc": "plain"
                default: nil
                }
            #expect(title.pageStyle == style)
        }
    }

    @Test("本文のコマンド・罫線・行送り・余白を全クラスで保つ", arguments: defaults)
    func bodyRules(row: Defaults) {
        for name in row.names {
            let profile = LaTeXDocumentClassInfo(name: name).profile
            let body = profile.body
            let scaled = row.jsArticle || row.jsChapters
            let standard = ["article", "report", "book"].contains(name)
            #expect(body.correspondence == (name == "letter" ? .letter : name == "moderncv" ? .curriculumVitae : .none))
            #expect(body.readsQuestions == (name == "exam"))
            #expect(body.readsFrames == (name == "beamer"))
            #expect(body.numbersCaptions == (name != "beamer"))
            #expect(body.naturalRuleHeight == (scaled || row.typeArea || ["memoir", "elsarticle"].contains(name)))
            #expect(body.usesSizeFileGlue == standard)
            #expect(body.usesListingDesignSize == standard)
            #expect(body.captionSkip == (scaled ? .fiveScaledPoints : name == "memoir" ? .halfBaseline : .inherited))
            let japanese = row.language == "ja"
            #expect(body.equationNumberOnLeft == (name == "amsproc"))
            #expect(
                body.captionSeparator
                    == (["ltjarticle", "ltjbook", "jarticle", "jbook"].contains(name) ? ":\u{2002}" : nil))
            #expect(body.styledCaptionSeparator == (japanese ? ": " : nil))
            #expect(body.untranslatedProofName == (japanese ? "Proof" : nil))
            #expect(body.spacesLinkedCounters == japanese)
            #expect(body.usesJapanesePunctuationMetrics == japanese)
            #expect(body.asteriskFootnotes == scaled)
            #expect(body.proceedingsTheoremStyle == (name == "amsproc"))
            #expect(profile.titleBlock.uprightClassificationYear == (name == "amsproc"))
            #expect(profile.typography.selectsGothicHeadings == japanese)
            #expect(profile.typography.prefersHiraginoSansW4 == japanese)
            #expect(body.usesScaledTableMetrics == scaled)
            #expect(body.alignsDisplayRows == scaled)
            #expect(body.alignsHangingCaptions == scaled)
            #expect(
                profile.typography.selectsParagraphPitch
                    == (scaled || ["ltjarticle", "ltjbook", "jarticle", "jbook"].contains(name)))
            #expect(profile.typography.usesScaledBodyFont == scaled)
            #expect(profile.typography.spacingDesignSize == (scaled ? 10 : nil))
            #expect(profile.usesGridFlow == scaled)
            #expect(profile.defaultStyle == (row.language == "ja" ? .japanese : row.chapters ? .chaptered : .sectioned))
        }
    }

    @Test("版面と級数表を全クラスで個別に選ぶ", arguments: defaults)
    func layoutRules(row: Defaults) {
        for name in row.names {
            let p = LaTeXDocumentClassInfo(name: name).profile
            let layout: LaTeXClassProfile.LayoutRule
            let baselines: LaTeXClassProfile.BaselineTable
            switch name {
            case "scrartcl", "scrreprt", "scrbook": (layout, baselines) = (.typeArea, .standard)
            case "memoir": (layout, baselines) = (.ruledBook, .standard)
            case "amsart", "amsproc": (layout, baselines) = (.ams(footSkip: 12), .ams)
            case "amsbook": (layout, baselines) = (.ams(footSkip: 18), .ams)
            case "exam": (layout, baselines) = (.exam, .standard)
            case "jlreq": (layout, baselines) = (.characterGrid, .characterGrid)
            case "article", "report": (layout, baselines) = (.standard(.doubleColumn), .standard)
            case "book": (layout, baselines) = (.standard(.bookOffsets), .standard)
            case "ltjarticle", "jarticle": (layout, baselines) = (.standard(.traditionalArticle), .traditional)
            case "ltjbook", "jbook": (layout, baselines) = (.standard(.traditionalBook), .traditional)
            case "letter": (layout, baselines) = (.standard(.letterOffsets), .standard)
            default:
                if row.jsScale != nil {
                    layout = .scaledGrid(
                        scale: 1, bookMeasure: name.hasSuffix("book"), centersFurniture: name.hasPrefix("bx"))
                    baselines = .scaled(magnification: 1, smallBelow: name.hasPrefix("bx") ? 1 : 0.92)
                } else {
                    layout = .standard(.inherited)
                    baselines = row.traditionalNames ? .traditional : .standard
                }
            }
            #expect(p.page.layoutRule == layout)
            #expect(p.typography.baselineTable == baselines)
        }
    }

    @Test("クラスオプションによる罫線・表題・部見出しの違いを保つ")
    func optionDependentRules() {
        for (options, heading, rule) in [
            ("reprint,preprint", LaTeXClassProfile.BibliographyHeading.rule, true),
            ("preprint,reprint", .rule, false), ("preprint,aip", .inherited, false),
        ] {
            let p = LaTeXDocumentClassInfo(name: "revtex4-2", options: options).profile
            #expect(p.headings.bibliography == heading)
            #expect(p.body.naturalRuleHeight == rule)
        }
        let ieee = LaTeXDocumentClassInfo(name: "IEEEtran", options: "conference,compsoc").profile
        #expect(ieee.titleBlock.pageStyle == "empty")
        #expect(ieee.titleBlock.defaultKeywordLabel == "Index Terms—")
        #expect(!ieee.titleBlock.includesDate)
        #expect(LaTeXDocumentClassInfo(name: "jlreq", options: "report").profile.headings.emptyPartPage)
        let scaled = LaTeXDocumentClassInfo(name: "bxjsbook", options: "oneside,8pt").profile
        #expect(scaled.page.layoutRule == .scaledGrid(scale: 0.8, bookMeasure: true, centersFurniture: true))
        #expect(scaled.typography.baselineTable == .scaled(magnification: 0.8, smallBelow: 1))
    }

    @Test("クラス名と学会パッケージ名のリテラルは各レジストリだけに置く")
    func classNameLiterals() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources").standardizedFileURL
        let names = LaTeXClassRegistry.registeredNames.map(NSRegularExpression.escapedPattern(for:))
        let literal = try NSRegularExpression(
            pattern: "\"" + "(?:"
                + (names + [
                    "neurips(?:_[0-9]{0,4})?", "iclr(?:[0-9]{4}(?:_conference)?)?", "_conference",
                    "icml(?:[0-9]{4})?", "cvpr", "acl", "aaai(?:[0-9]{4})?",
                ]).joined(
                    separator: "|") + ")\"")
        // Each excerpt exempts one occurrence so another comparison in the same file still fails.
        let exceptions: [String: [String]] = [
            // These are HTML element names used to identify block boundaries.
            "FragmentChanges.swift": [#""header", "article", "main""#],
            "ClipboardMarkupScanners.swift": [#""section", "article", "aside""#],
            // The bundled cleanup preset is named for the content it keeps.
            "HTMLCleanupPreset.swift": [#""clean", "article", "print""#],
            // CSS accepts letter as a paper size.
            "PageRule.swift": [#""jis-b4", "letter", "legal""#],
            // BibTeX entry types are independent of the document class.
            "LaTeXBibliography.swift": [
                #"["book", "inbook"].contains(type)"#, #"["book", "inbook", "manual""#,
                #"case "article":"#, #"case "book", "inbook":"#,
            ],
            // The memoir chapterstyle command also accepts a style called article.
            "LaTeXBookStyle.swift": [#""section", "article"].contains(style)"#],
            // The letter environment can only open inside a document supporting correspondence.
            "LaTeXReader.swift": [#"case "letter" where document.classInfo.profile.body.correspondence == .letter:"#],
            // These selectors are JavaScript embedded in the pagination source.
            "LaTeXPageReferences.swift": [
                #"[data-latex-class="amsart"]"#, #"[data-latex-class="amsproc"]"#, #"[data-latex-class="amsbook"]"#,
            ],
        ]
        for module in ["SurimonoFormats", "SurimonoCore", "SurimonoRendering"] {
            let folder = sources.appendingPathComponent(module)
            let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            var scanned = 0
            for case let file as URL in files where file.pathExtension == "swift" {
                if ["LaTeXClassRegistry.swift", "LaTeXStylePackageRegistry.swift"].contains(file.lastPathComponent) {
                    continue
                }
                scanned += 1
                var source = try String(contentsOf: file, encoding: .utf8)
                for excerpt in exceptions[file.lastPathComponent] ?? [] {
                    if let range = source.range(of: excerpt) { source.replaceSubrange(range, with: "") }
                }
                let match = literal.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))
                if let match, let range = Range(match.range, in: source) {
                    let line = source[..<range.lowerBound].utf8.filter { $0 == 10 }.count + 1
                    Issue.record("\(file.lastPathComponent):\(line) クラス名 \(source[range])")
                }
            }
            #expect(scanned > 0, "\(module)")
        }
    }
}

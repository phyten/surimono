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
            names: ["amsart", "amsproc"], forcedPaper: .letter, boxSides: true, numberSides: true,
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
            names: ["scrbook"], chapters: true, size: 11, typeArea: true, paper: .a4,
            boxSides: true, fieldSides: true, numberSides: true),
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
            numberSides: true),
        .init(names: ["jlreq"], language: "ja", nativeHeadings: true, paper: .a4),
        .init(
            names: ["jarticle", "ltjarticle", "ujarticle", "utarticle", "tarticle"], language: "ja",
            nativeHeadings: true, traditionalNames: true, paper: .a4),
        .init(
            names: [
                "jreport", "ltjreport", "ujreport", "utreport", "treport", "jbook", "ltjbook", "ujbook", "utbook",
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
                ["subtitle", "publishers", "addsec", "addchap", "setkomafont", "addtokomafont"]
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
}

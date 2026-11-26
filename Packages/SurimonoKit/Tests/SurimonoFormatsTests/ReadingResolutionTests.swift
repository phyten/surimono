import Testing

@testable import SurimonoFormats

struct ReadingResolutionTests {
    @Test("Org の旧優先順と継承値・出典を、保存値と原稿指定と許可の全組み合わせで保つ")
    func orgCompatibility() throws {
        let location = ReadingInstructionSource(fileName: "a.org", lineNumber: 4, rawText: "toc:2")
        for permission in [false, true] {
            for choice: OrgReadingDefaults.Depth? in [nil, .off, .levels(2)] {
                for hasFile in [false, true] {
                    var file = OrgFileInstructions()
                    if hasFile { file.record(.levels(2), for: .tableOfContents, source: location) }
                    var org = OrgReadingSettings()
                    org.defaults.tableOfContents = .all
                    if let choice { org.set(choice, for: .tableOfContents, file: .init()) }
                    org.setAllowsFileChanges(permission, file: file)
                    let row = org.resolve(.tableOfContents, file: file)
                    let inherited: OrgReadingDefaults.Depth = hasFile ? .levels(2) : .all
                    let effectiveChoice = !hasFile || permission ? choice : nil
                    #expect(row.inherited == inherited && row.value == (effectiveChoice ?? inherited))
                    #expect(row.layer == (effectiveChoice == nil ? (hasFile ? .file : .app) : .document))
                    #expect(row.source == (hasFile ? location : nil))
                    #expect(row.isLocked == (hasFile && !permission))
                    #expect(org.document.changedCount(file: file) == (effectiveChoice == nil ? 0 : 1))
                }
            }
        }
    }

    @Test("原稿で隠れた保存値は点に数えず、原稿指定がなくなると元の選択に戻る")
    func hiddenChoices() throws {
        var org = OrgReadingSettings()
        org.set(.levels(3), for: .tableOfContents, file: .init())
        let file = try #require(OrgConverter.convert("#+OPTIONS: toc:1").orgInstructions)
        #expect(org.document.changedCount(file: file) == 0)
        #expect(org.document.changedCount(file: .init()) == 1)
        #expect(org.resolve(.tableOfContents, file: .init()).value == .levels(3))
        org.setAllowsFileChanges(true, file: file)
        org.set(.all, for: .tableOfContents, file: file)
        #expect(org.document.changedCount(file: file) == 1)
    }

    @Test(
        "目次の有無だけを固定した原稿では、なしを選べず深さだけを文書に保存できる",
        arguments: [DocumentFormat.markdown, .quarto])
    func partialLock(format: DocumentFormat) throws {
        let line = ReadingInstructionSource(fileName: "sample", lineNumber: 2, rawText: "toc: true")
        let file = ReadingFileInstructions(present: .init(true, source: line))
        var document = FormatReadingChoices()
        document.set(.outline(present: false, depth: .all), for: .tableOfContents, format: format, file: file)
        #expect(document.isEmpty)
        document.set(.outline(present: true, depth: .levels(1)), for: .tableOfContents, format: format, file: file)
        guard case .outline(let present, let depth) = document.resolve(.tableOfContents, for: format, file: file)
        else {
            Issue.record("目次がない")
            return
        }
        #expect(present.value && present.isLocked && present.layer == .file && present.source == line)
        #expect(depth.value == .levels(1) && !depth.isLocked && depth.layer == .document && depth.source == nil)
        #expect(depth.inherited == .levels(3))
        document.set(.outline(present: true, depth: .levels(3)), for: .tableOfContents, format: format, file: file)
        #expect(document.isEmpty)
    }

    @Test("原稿が有無と深さを決めた場合はそれぞれ出典を保ち、許可中の編集だけが優先する")
    func fullLock() {
        let first = ReadingInstructionSource(fileName: nil, lineNumber: 2, rawText: "toc: true")
        let second = ReadingInstructionSource(fileName: nil, lineNumber: 3, rawText: "toc-depth: 1")
        var file = ReadingFileInstructions(enabledTo: .levels(1), source: second)
        #expect(file.present?.source == second)
        file.present = .init(true, source: first)
        var document = FormatReadingChoices()
        document.set(.outline(present: true, depth: .all), for: .tableOfContents, format: .quarto, file: file)
        #expect(document.isEmpty)
        document.set(
            .outline(present: true, depth: .all), for: .tableOfContents, format: .quarto, file: file,
            allowsFileChanges: true)
        guard
            case .outline(let presence, let depth) = document.resolve(
                .tableOfContents, for: .quarto, file: file,
                allowsFileChanges: true)
        else {
            Issue.record("目次がない")
            return
        }
        #expect(presence.layer == .file && presence.source == first && !presence.isLocked)
        #expect(depth.layer == .document && depth.source == second && depth.inherited == .levels(1))
        document.set(
            .outline(present: true, depth: .levels(1)), for: .tableOfContents, format: .quarto, file: file,
            allowsFileChanges: true)
        #expect(document.isEmpty)
    }

    @Test("深さだけを固定した原稿では、違う深さへの変更を丸ごと断り、同じ深さでの有無の切り替えは通す")
    func depthOnlyLock() {
        let line = ReadingInstructionSource(fileName: nil, lineNumber: 3, rawText: "toc-depth: 1")
        let file = ReadingFileInstructions(depth: .init(.levels(1), source: line))
        func set(_ doc: inout FormatReadingChoices, _ on: Bool, _ depth: ReadingDepth, allows: Bool = false) {
            doc.set(
                .outline(present: on, depth: depth), for: .tableOfContents, format: .quarto, file: file,
                allowsFileChanges: allows)
        }
        func state(_ doc: FormatReadingChoices, allows: Bool = false) -> (Bool, ReadingDepth)? {
            guard
                case .outline(let present, let depth) = doc.resolve(
                    .tableOfContents, for: .quarto, file: file, allowsFileChanges: allows)
            else { return nil }
            return (present.value, depth.value)
        }
        var doc = FormatReadingChoices()
        set(&doc, true, .levels(2))
        #expect(doc.isEmpty)
        set(&doc, true, .levels(1))
        #expect(state(doc)?.0 == true && state(doc)?.1 == .levels(1))
        set(&doc, false, .levels(1))
        #expect(doc.isEmpty)
        set(&doc, true, .levels(2), allows: true)
        #expect(state(doc, allows: true)?.0 == true && state(doc, allows: true)?.1 == .levels(2))
    }

    @Test("深さだけを選び直しても、保存していた有無は全体既定が後から一致していても消えない")
    func depthEditKeepsPresence() throws {
        var app = FormatReadingChoices()
        var doc = FormatReadingChoices()
        doc.set(.outline(present: true, depth: .levels(1)), for: .tableOfContents, format: .quarto)
        app.set(.outline(present: true, depth: .levels(3)), for: .tableOfContents, format: .quarto)
        doc.set(.outline(present: true, depth: .levels(2)), for: .tableOfContents, format: .quarto, defaults: app)
        // The app default returns to "absent": the document must still show its contents.
        guard case .outline(let present, let depth) = doc.resolve(.tableOfContents, for: .quarto)
        else {
            Issue.record("目次がない")
            return
        }
        #expect(present.value && present.layer == .document && depth.value == .levels(2))
        doc.set(.outline(present: false, depth: .levels(2)), for: .tableOfContents, format: .quarto)
        guard case .outline(let off, let kept) = doc.resolve(.tableOfContents, for: .quarto)
        else {
            Issue.record("目次がない")
            return
        }
        #expect(!off.value && kept.value == .levels(2))
    }

    @Test("全体既定が後から一致しても記録を保ち、利用者が継承値を選び直したときだけ消す")
    func changedDefaults() {
        var app = FormatReadingChoices()
        var doc = FormatReadingChoices()
        doc.set(.toggle(true), for: .preserveBreaks, format: .markdown)
        app.set(.toggle(true), for: .preserveBreaks, format: .markdown)
        guard case .toggle(let row) = doc.resolve(.preserveBreaks, for: .markdown, defaults: app)
        else {
            Issue.record("改行の項目がない")
            return
        }
        #expect(row.layer == .document && row.inherited)
        doc.set(.toggle(true), for: .preserveBreaks, format: .markdown, defaults: app)
        #expect(doc.isEmpty)
    }

    @Test("同じ目次の全体既定は形式をまたがず、原稿と文書が指定しない成分だけを補う")
    func isolatedDefaults() {
        var app = FormatReadingChoices()
        app.set(.outline(present: true, depth: .levels(1)), for: .tableOfContents, format: .quarto)
        let document = FormatReadingChoices()
        guard
            case .outline(let quarto, let quartoDepth) = document.resolve(.tableOfContents, for: .quarto, defaults: app),
            case .outline(let markdown, let markdownDepth) = document.resolve(
                .tableOfContents, for: .markdown, defaults: app)
        else {
            Issue.record("目次がない")
            return
        }
        #expect(quarto.value && quarto.layer == .app && quartoDepth.value == .levels(1))
        #expect(!markdown.value && markdown.layer == .app && markdownDepth.value == .levels(3))
    }

    @Test("目録は Org の識別子と表示順、各形式の対象項目を保つ")
    func catalogue() {
        let expected: [ReadingSettingID] = [
            .sectionNumbers, .tableOfContents, .headlineLevels, .tags, .title, .author, .date, .scripts,
            .preserveBreaks, .emphasis, .math, .planning, .clocks, .priority, .todo, .statistics, .tasks,
            .drawers, .properties, .timestamps, .footnotes, .tables, .fixedWidth, .archived,
        ]
        #expect(ReadingCatalogue.rows(for: .org).map(\.id) == expected)
        #expect(Set(expected) == Set(OrgSettingID.allCases))
        #expect(OrgSettingID.sectionNumbers.rawValue == "org.num" && OrgSettingID.tableOfContents.rawValue == "org.toc")
        for format in DocumentFormat.allCases where format != .org {
            let ids: [ReadingSettingID] =
                switch format {
                case .markdown: [.sectionNumbers, .tableOfContents, .preserveBreaks]
                case .quarto, .rMarkdown, .rst, .asciidoc: [.sectionNumbers, .tableOfContents]
                case .mediawiki: [.tableOfContents]
                default: []
                }
            #expect(ReadingCatalogue.rows(for: format).map(\.id) == ids)
        }
    }
}

import Testing

@testable import SurimonoFormats

struct OrgReadingSettingsTests {
    @Test("すべての行を戻してもファイルの指定を変更する許可は残る")
    func resetRowsKeepsPermission() {
        var settings = OrgReadingSettings()
        settings.setAllowsFileChanges(true, file: .init())
        settings.set(.all, for: .sectionNumbers, file: .init())
        var document = settings.document
        document.resetValues()
        #expect(document.changedCount == 0 && document.optionsLine == nil)
        #expect(document.allowsFileChanges)
    }

    @Test("原稿で最後に指定した値と行が勝ち、見本のブロックは設定にならない")
    func fileSource() throws {
        let source = """
            #+OPTIONS: num:t toc:nil
            #+begin_src org
            #+OPTIONS: ^:nil num:nil
            #+end_src
            #+OPTIONS: unknown:"toc:8" ToC:#x2
            * One
            """
        let file = try #require(OrgConverter.convert(source, fileName: "原稿.org").orgInstructions)
        let settings = OrgReadingSettings()
        let toc = settings.resolve(.tableOfContents, file: file)
        #expect(toc.value == .levels(2))
        #expect(toc.layer == .file)
        let location = try #require(toc.source)
        #expect(location.fileName == "原稿.org" && location.lineNumber == 5 && location.rawText == "ToC:#x2")
        let excerpt = try #require(location.excerpt)
        #expect(excerpt.previous == "#+end_src" && excerpt.next == "* One")
        #expect(excerpt.line.dropFirst(excerpt.tokenOffset).hasPrefix(location.rawText))
        #expect(settings.resolve(.scripts, file: file).layer == .app)
        #expect(settings.resolve(.sectionNumbers, file: file).value == .all)
    }

    @Test("出典はコピー用に前後の空白を保ち、引用に同じ語があっても実際の指定を強調する")
    func excerptKeepsExactToken() throws {
        let prefix = "  #+OpTiOnS:  x:\"前 toc:2\" "
        let line = prefix + "toc:2 y:\"toc:2\"  "
        let file = try #require(OrgConverter.convert(line + "\r\n* 次").orgInstructions)
        let source = try #require(OrgReadingSettings().resolve(.tableOfContents, file: file).source)
        let excerpt = try #require(source.excerpt)
        #expect(source.lineNumber == 1 && source.fileName == nil)
        #expect(excerpt.previous == nil && excerpt.line == line && excerpt.next == "* 次")
        #expect(excerpt.tokenOffset == prefix.count && source.rawText == "toc:2")
    }

    @Test("外部の設定の出典は原稿順に五行まで残し、再走査しても残りの件数が増えない")
    func externalSettingsSources() throws {
        let directives = [
            "#+SETUPFILE: local.org", "  #+SetupFile: \"two words.org\"  ", "#+sEtUpFiLe: https://example.org/a",
            "#+iNcLuDe: \"chapter.org\" :lines \"2-8\"", "#+INCLUDE: chapter.org",
        ]
        let lines = directives + Array(repeating: "#+setupfile: local.org", count: 100) + ["* Hidden :noexport:"]
        let file = try #require(
            OrgConverter.convert(lines.joined(separator: "\r\n"), fileName: "親.org").orgInstructions)
        #expect(file.externalSettingsSources.map(\.lineNumber) == [1, 2, 3, 4, 5])
        #expect(file.externalSettingsSources.allSatisfy { $0.fileName == "親.org" })
        #expect(file.externalSettingsSources.compactMap(\.excerpt?.line) == directives)
        #expect(file.additionalExternalSettingsCount == 100)
        let quoted = try #require(file.externalSettingsSources.dropFirst().first)
        #expect(quoted.excerpt?.previous == directives[0] && quoted.excerpt?.next == directives[2])
        #expect(quoted.excerpt?.tokenOffset == 2)
    }

    @Test("ブロックやプロパティ内の外部指定と本文中の類似文字列は注記にならない")
    func ignoresLiteralExternalSettings() throws {
        let directives = "#+SETUPFILE: example.org\n#+INCLUDE: other.org"
        let blocks = ["src", "example", "export", "comment", "quote"].map {
            "#+begin_\($0)\n\(directives)\n#+end_\($0)"
        }
        let text = (blocks + ["* 見出し", ":PROPERTIES:", directives, ":END:", "本文 #+SETUPFILE: x", "#+INCLUDES: y"])
            .joined(separator: "\n")
        let file = try #require(OrgConverter.convert(text).orgInstructions)
        #expect(file.externalSettingsSources.isEmpty && file.additionalExternalSettingsCount == 0)
    }

    @Test("別のファイルの指定は本文・設定の変更件数・固定に影響しない")
    func externalSettingsDoNotChangeReading() throws {
        let body = "* One\n** Two"
        var settings = OrgReadingSettings()
        settings.set(.all, for: .sectionNumbers, file: .init())
        let original = OrgConverter.convert(body, settings: settings)
        let withNote = OrgConverter.convert(
            "#+SETUPFILE: settings.org\n#+INCLUDE: other.org\n" + body, settings: settings)
        let file = try #require(withNote.orgInstructions)
        #expect(withNote.body == original.body && withNote.readingIssues == original.readingIssues)
        #expect(!file.hasWholeDocumentInstructions)
        #expect(!settings.resolve(.sectionNumbers, file: file).isLocked)
        #expect(settings.document.changedCount(file: file) == 1 && settings.fileOverrideCount(file: file) == 0)
        #expect(settings.document.optionsLine == "#+OPTIONS: num:t")
    }

    @Test("見出しと本文位置の指定は注記になり、その項目を固定しない")
    func localNotes() throws {
        let source = "* One\n:PROPERTIES:\n:UNNUMBERED: t\n:END:\n#+TOC: headlines 2 local"
        let file = try #require(OrgConverter.convert(source).orgInstructions)
        let settings = OrgReadingSettings()
        let num = settings.resolve(.sectionNumbers, file: file)
        let toc = settings.resolve(.tableOfContents, file: file)
        #expect(num.notes.map(\.source.lineNumber) == [3])
        #expect(toc.notes.map(\.source.rawText) == ["#+TOC: headlines 2 local"])
        #expect(num.notes.map(\.kind) == [.unnumberedHeading])
        #expect(toc.notes.map(\.kind) == [.bodyContents])
        #expect(num.layer == .app && toc.layer == .app)
    }

    @Test("notoc の除外と本文の目次は別の注記になり、子の見出しも除外件数に含む", arguments: [false, true])
    func excludedHeadings(hasBodyContents: Bool) throws {
        let source = """
            * A
            :PROPERTIES:
            :UNNUMBERED: notoc
            :END:
            ** B
            ** C
            :PROPERTIES:
            :UNNUMBERED: nil
            :END:
            * D
            """ + (hasBodyContents ? "\n#+TOC: headlines" : "")
        let file = try #require(OrgConverter.convert(source).orgInstructions)
        let toc = OrgReadingSettings().resolve(.tableOfContents, file: file)
        #expect(toc.source == nil && toc.layer == .app)
        #expect(file.excludedHeadingCount == 2)
        #expect(toc.notes.filter { $0.kind == .excludedFromContents }.map(\.source.lineNumber) == [3])
        #expect(toc.notes.filter { $0.kind == .bodyContents }.map(\.source.lineNumber) == (hasBodyContents ? [11] : []))
    }

    @Test("上書きする項目だけ原稿に勝ち、実際に継承する値へ戻すと記録を消す")
    func inheritance() throws {
        let file = try #require(OrgConverter.convert("#+OPTIONS: toc:2 num:nil").orgInstructions)
        var settings = OrgReadingSettings()
        settings.set(.off, for: .tableOfContents, file: file)
        #expect(settings.document.changedCount == 0)
        settings.setAllowsFileChanges(true, file: file)
        settings.set(.off, for: .tableOfContents, file: file)
        #expect(settings.document.optionsLine == "#+OPTIONS: toc:nil")
        let row = settings.resolve(.tableOfContents, file: file)
        #expect(row.layer == .document && row.value == .off && row.inherited == .levels(2))
        #expect(row.source?.rawText == "toc:2")
        #expect(settings.resolve(.sectionNumbers, file: file).layer == .file)
        settings.set(.levels(2), for: .tableOfContents, file: file)
        #expect(settings.document.changedCount == 0 && settings.document.optionsLine == nil)
    }

    @Test("上書きの解除で原稿指定のある変更だけを数えて捨てる")
    func discard() throws {
        let source = "#+OPTIONS: toc:1\n* A\na_b"
        let file = try #require(OrgConverter.convert(source).orgInstructions)
        var settings = OrgReadingSettings()
        settings.setAllowsFileChanges(true, file: file)
        settings.set(.off, for: .tableOfContents, file: file)
        settings.set(.all, for: .scripts, file: file)
        settings.defaults.scripts = .all
        #expect(settings.document.changedCount == 2)
        #expect(settings.fileOverrideCount(file: file) == 1)
        #expect(!OrgConverter.convert(source, settings: settings).body.contains("<nav"))
        settings.setAllowsFileChanges(false, file: file)
        #expect(settings.document.optionsLine == "#+OPTIONS: ^:t")
        #expect(settings.resolve(.scripts, file: file).layer == .document)
        #expect(OrgConverter.convert(source, settings: settings).body.contains("<nav"))
    }

    @Test("ファイルの指定が加わると保存済みの値より優先し、解除件数には部分指定を含めない")
    func newFileInstructions() throws {
        var settings = OrgReadingSettings()
        settings.set(.all, for: .sectionNumbers, file: .init())
        settings.set(.levels(3), for: .tableOfContents, file: .init())
        let fragment = OrgConverter.convert(
            "#+OPTIONS: num:nil\n* One\n#+TOC: headlines", settings: settings, fileName: "doc.org")
        let file = try #require(fragment.orgInstructions)
        #expect(!fragment.body.contains("section-number"))
        #expect(settings.resolve(.sectionNumbers, file: file).layer == .file)
        #expect(settings.resolve(.tableOfContents, file: file).layer == .document)
        settings.setAllowsFileChanges(true, file: file)
        #expect(settings.fileOverrideCount(file: file) == 1)
        settings.setAllowsFileChanges(false, file: file)
        #expect(settings.document.optionsLine == "#+OPTIONS: toc:3")
    }

    @Test("番号の深さ・見出し全段の目次・中括弧限定を読み戻せる行にする")
    func copyDepthAndBraces() throws {
        var settings = OrgReadingSettings()
        settings.defaults.scripts = .off
        settings.set(.levels(2), for: .sectionNumbers, file: .init())
        settings.set(.all, for: .tableOfContents, file: .init())
        settings.set(.braces, for: .scripts, file: .init())
        let line = try #require(settings.document.optionsLine)
        #expect(line == "#+OPTIONS: num:2 toc:t ^:{}")
        let file = try #require(OrgConverter.convert(line).orgInstructions)
        let reader = OrgReadingSettings(defaults: .init(sectionNumbers: .off, tableOfContents: .off, scripts: .off))
        let numbers = reader.resolve(.sectionNumbers, file: file)
        let contents = reader.resolve(.tableOfContents, file: file)
        let scripts = reader.resolve(.scripts, file: file)
        #expect(numbers.layer == .file && numbers.value == .levels(2))
        #expect(contents.layer == .file && contents.value == .all)
        #expect(scripts.layer == .file && scripts.value == .braces)
    }

    @Test("既定・文書の変更・原稿の指定を項目ごとに反映し、コピーした行で再現できる")
    func conversionAndCopy() {
        let text = "* A\nx_y x^{2}"
        var settings = OrgReadingSettings()
        settings.defaults.tableOfContents = .levels(1)
        settings.set(.all, for: .sectionNumbers, file: .init())
        settings.set(.off, for: .scripts, file: .init())
        let body = OrgConverter.convert(text, settings: settings).body
        #expect(body.contains("<nav") && body.contains("section-number") && body.contains("x_y x^{2}"))
        #expect(settings.document.optionsLine == "#+OPTIONS: num:t ^:nil")
        #expect(OrgConverter.convert("#+OPTIONS: num:t ^:nil\n" + text, defaults: settings.defaults).body == body)
    }
}

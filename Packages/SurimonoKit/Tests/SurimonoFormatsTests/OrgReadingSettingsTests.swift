import Testing

@testable import SurimonoFormats

struct OrgReadingSettingsTests {
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
        #expect(toc.source == OrgInstructionSource(fileName: "原稿.org", lineNumber: 5, rawText: "ToC:#x2"))
        #expect(settings.resolve(.scripts, file: file).layer == .app)
        #expect(settings.resolve(.sectionNumbers, file: file).value == .all)
    }

    @Test("見出しと本文位置の指定は注記になり、その項目を固定しない")
    func localNotes() throws {
        let source = "* One\n:PROPERTIES:\n:UNNUMBERED: t\n:END:\n#+TOC: headlines 2 local"
        let file = try #require(OrgConverter.convert(source).orgInstructions)
        let settings = OrgReadingSettings()
        let num = settings.resolve(.sectionNumbers, file: file)
        let toc = settings.resolve(.tableOfContents, file: file)
        #expect(num.notes.map(\.lineNumber) == [3])
        #expect(toc.notes.map(\.rawText) == ["#+TOC: headlines 2 local"])
        #expect(num.layer == .app && toc.layer == .app)
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
        #expect(settings.resolve(.sectionNumbers, file: file).value == .levels(2))
        #expect(settings.resolve(.tableOfContents, file: file).value == .all)
        #expect(settings.resolve(.scripts, file: file).value == .braces)
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

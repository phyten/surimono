import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct ReadingPDFExporterTests {
    private func exportState(_ document: PDFDocument, pages: [Int] = [0]) -> String {
        var outline: CGPDFDictionaryRef?
        let raw = document.documentRef?.catalog.map { CGPDFDictionaryGetDictionary($0, "Outlines", &outline) } ?? false
        let entries = PDFOutlineReader.entries(of: document).prefix(6).map { entry in
            entry.pageIndex.map { $0 == NSNotFound ? "foreign" : String($0 + 1) } ?? "nil"
        }
        let links = pages.map { index in
            let targets = (document.page(at: index)?.annotations ?? []).prefix(12).map { annotation in
                guard let dest = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination else {
                    return ((annotation.action as? PDFActionURL)?.url ?? annotation.url)?.scheme ?? "?"
                }
                guard let page = dest.page else { return "nil" }
                let target = document.index(for: page)
                return target == NSNotFound ? "foreign" : String(target + 1)
            }
            return "p\(index + 1)links=\(targets)"
        }
        return "catalog=\(raw) bookmarks=\(entries) " + links.joined(separator: " ")
    }

    @Test(
        "コードと表の後の目次を四つの印刷設定で本文のページに照合する", .timeLimit(.minutes(1)),
        arguments: ["standard", "confetti", "academic", "line-numbers"])
    func printedMarkdownContents(_ variant: String) async throws {
        let file = try #require(
            Bundle.module.url(forResource: "toc-probe", withExtension: "md", subdirectory: "Fixtures"))
        let source = DocumentSource(data: try Data(contentsOf: file), fileURL: file, format: .markdown)
        let themes = try PrintThemeLibrary.load()
        let theme = try #require(themes.first { $0.id == (variant == "line-numbers" ? "standard" : variant) })
        var settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        if variant == "line-numbers" { settings.code.block.lineNumbers = .all }
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let outline = await ReadingPDFExporter.outline(
            of: source, in: prepared.logicalDocument, proof: .shown, includesSourceContents: true)
        let sections = outline.entries.filter { $0.level == 2 }
        #expect(sections.map(\.title) == ["第一節 用紙", "第二節 余白", "第三節 綴じ"])
        #expect(sections.map(\.pageIndex) == [1, 2, 3])
    }

    @Test("読むPDFは論理ページ順と見出しと外部リンクと題名を保存する", .timeLimit(.minutes(1)))
    func markdown() async throws {
        let source = DocumentSource(
            data: Data(
                """
                # First

                [Example](https://example.com/) [Next](#%E5%9B%B3)

                <div style="break-before: page"></div>

                ## 図

                Text.
                """.utf8),
            fileURL: URL(fileURLWithPath: "/reading-export-fixture/source.md"), format: .markdown)
        let settings = RenderSettings(
            layout: .a4BookletA5,
            theme: PrintTheme(id: "test", name: "Test", css: "body { font-size: 12pt; }"),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let entries = DocumentOutline.entries(
            of: try #require(prepared.facts).headings,
            inPageTexts: (0..<prepared.logicalDocument.pageCount).map {
                prepared.logicalDocument.page(at: $0)?.string ?? ""
            })
        #expect(entries.map(\.pageIndex) == [0, 1])
        let output = try await ReadingPDFExporter.document(
            from: prepared.logicalDocument, entries: entries, title: "First",
            headings: try #require(prepared.facts).headings, sourceURL: source.fileURL)
        let before = exportState(output)
        let bytes = try await ReadingPDFExporter.data(from: output)
        let reread = try #require(PDFDocument(data: bytes))
        let detail = "view[\(exportState(prepared.logicalDocument))] export[\(before)] saved[\(exportState(reread))]"
        #expect(reread.pageCount == prepared.logicalDocument.pageCount)
        func targets(in document: PDFDocument) -> [Int] {
            (0..<document.pageCount).flatMap { index in
                (document.page(at: index)?.annotations ?? []).compactMap { annotation in
                    let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
                    return destination?.page.map { document.index(for: $0) }
                }
            }
        }
        #expect(targets(in: reread).contains(1), "\(detail)")
        for index in 0..<reread.pageCount {
            for annotation in try #require(reread.page(at: index)).annotations {
                let url = (annotation.action as? PDFActionURL)?.url ?? annotation.url
                #expect(url?.scheme != "file")
            }
        }

        let first = try #require(reread.outlineRoot?.child(at: 0), "\(detail)")
        #expect(first.label == "First")
        #expect(reread.index(for: try #require(first.destination?.page)) == 0)
        let second = try #require(first.child(at: 0))
        #expect(second.label == "図")
        #expect(reread.index(for: try #require(second.destination?.page)) == 1)
        #expect(reread.page(at: 0)?.annotations.contains { $0.url?.absoluteString == "https://example.com/" } == true)
        #expect(reread.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "First")
        #expect(reread.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String == "Surimono")
    }

    @Test("先頭の目次と見出しの下の目次がある Org の文書でも、しおりとリンクは見出しのページへ行く", .timeLimit(.minutes(1)))
    func orgWithSeveralContents() async throws {
        let source = DocumentSource(
            data: Data(
                """
                #+OPTIONS: toc:t
                * Alpha
                text
                * Beta
                #+TOC: headlines local
                ** Gamma
                text
                """.utf8),
            fileURL: URL(fileURLWithPath: "/reading-export-fixture/source.org"), format: .org)
        // The nested entry comes last so PDFKit can read by indentation or by height in the same order.
        let css = "body { font-size: 12pt; } h1, h2 { break-before: page; }"
        let settings = RenderSettings(
            layout: .a4BookletA5, theme: PrintTheme(id: "test", name: "Test", css: css),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let outline = await ReadingPDFExporter.outline(
            of: source, in: prepared.logicalDocument, proof: .shown, includesSourceContents: true)
        #expect(outline.entries.map(\.title) == ["Alpha", "Beta", "Gamma"])
        #expect(outline.entries.map(\.pageIndex) == [1, 2, 3])
        let output = try await ReadingPDFExporter.document(
            from: prepared.logicalDocument, entries: outline.entries, title: "Org", headings: outline.headings,
            sourceURL: source.fileURL)
        let bytes = try await ReadingPDFExporter.data(from: output)
        let reread = try #require(PDFDocument(data: bytes))
        let detail =
            "view[\(exportState(prepared.logicalDocument, pages: [0, 2]))] export[\(exportState(output, pages: [0, 2]))] saved[\(exportState(reread, pages: [0, 2]))]"
        func targets(onPage index: Int) -> [Int] {
            let annotations: [PDFAnnotation] = reread.page(at: index)?.annotations ?? []
            let pages: [Int] = annotations.compactMap { annotation in
                let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
                return destination?.page.map { reread.index(for: $0) }
            }
            return pages.sorted()
        }
        #expect(targets(onPage: 0) == [1, 2, 3], "\(detail)")
        #expect(targets(onPage: 2) == [3], "\(detail)")
        let first = try #require(reread.outlineRoot?.child(at: 0))
        #expect(reread.index(for: try #require(first.destination?.page)) == 1)
        let second = try #require(reread.outlineRoot?.child(at: 1))
        #expect(reread.index(for: try #require(second.destination?.page)) == 2)
        #expect(reread.index(for: try #require(second.child(at: 0)?.destination?.page)) == 3)
    }

    @Test("タグの付いた Org の見本の見出しも、しおりの題にタグと作業の語を入れずにどれもページを指す", .timeLimit(.minutes(1)))
    func orgHeadingsWithTags() async throws {
        // The tags float to the end of a heading's line; in the page's text they can come after the caption of the
        // table under the heading.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Samples/sample.org")
        let source = DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .org)
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(
            layout: .a4Single, theme: standard, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let outline = await ReadingPDFExporter.outline(
            of: source, in: prepared.logicalDocument, proof: .shown, includesSourceContents: true)
        #expect(
            outline.entries.map(\.title) == [
                "摺物のサンプル", "印刷の準備 [2/4]", "持ち物", "原稿を集める", "表紙の絵", "ページ数を数える",
            ])
        #expect(outline.entries.allSatisfy { $0.pageIndex != nil }, "\(outline.entries)")
    }

    @Test("和文の LaTeX の章と節、数式や脚注を含む見出しも、しおりに本文の題で並び、どれもページを指す", .timeLimit(.minutes(1)))
    func japaneseLaTeXHeadings() async throws {
        // jsbook sets a chapter's label and a section's number on lines of their own in the page's text.
        let tex = """
            \\documentclass{jsbook}
            \\begin{document}
            \\tableofcontents
            \\chapter{返却と予約}
            \\section{開室の識別}
            返却口の資料は配架前として扱う。
            \\section{$x_1 = x_2$ と札の確認}
            札の番号を照らし合わせる。
            \\section{注を含む見出し\\footnote{注の文。}}
            注を付けた見出しの本文。
            \\chapter{所在を探す}
            所在の本文。
            \\end{document}
            """
        let source = DocumentSource(data: Data(tex.utf8), fileURL: nil, format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let outline = await ReadingPDFExporter.outline(
            of: source, in: prepared.logicalDocument, proof: .shown, includesSourceContents: true)
        #expect(
            outline.entries.map(\.title) == [
                "第 1 章 返却と予約", "1.1 開室の識別", "1.2 x_1 = x_2 と札の確認", "1.3 注を含む見出し", "第 2 章 所在を探す",
            ])
        // Every heading points at the body after the contents, in order, each chapter on a page of its own.
        let pages = outline.entries.compactMap(\.pageIndex)
        try #require(pages.count == 5, "\(outline.entries)")
        let document = prepared.logicalDocument
        let contents = try #require(
            (0..<document.pageCount).first { document.page(at: $0)?.string?.contains("返却と予約") == true })
        #expect(pages.allSatisfy { $0 > contents }, "\(outline.entries)")
        #expect(pages == pages.sorted() && pages[4] > pages[0], "\(outline.entries)")
        #expect(document.page(at: pages[0])?.string?.contains("返却口の資料") == true)
        #expect(document.page(at: pages[4])?.string?.contains("所在の本文") == true)
    }

    @Test("スクロールでページをつないだ表示のあとでも、読むための PDF と用紙のどのページも論理ページの大きさのまま", .timeLimit(.minutes(1)))
    func readingPDFAfterJoinedView() async throws {
        // Each section ends high on its page, so the view cuts the unused paper below it.
        let text = "# 一\n\n短い段落。\n\n<!-- pagebreak -->\n\n# 二\n\n短い段落。\n\n<!-- pagebreak -->\n\n# 三\n\n終わり。\n"
        let source = DocumentSource(data: Data(text.utf8), format: .markdown)
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(
            layout: .a4Single, theme: standard, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let renderer = DocumentRenderer()
        let prepared = try await renderer.prepare(source, settings: settings)
        let document = prepared.viewDocument
        try #require(document.pageCount == 3)
        let size = CGSize(width: 595.28, height: 841.89)
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        let margin = 15 * 72 / 25.4
        let sizes = Array(repeating: size, count: 3)
        let base = ViewPageLayout(
            pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false, pageSizes: sizes)
        let bottoms = ViewPageDocument.contentBottoms(of: document, pages: base.trimmableBottomPages, margin: margin)
        let plan = ViewPageLayout(
            pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false, pageSizes: sizes,
            contentBottoms: bottoms)
        let view = try #require(ViewPageDocument.make(document, plan: plan, margin: margin))
        // The view itself is cut well above the bottom margin.
        #expect(try #require(view.page(at: 0)?.bounds(for: .cropBox).height) < size.height / 2)
        func expectLogicalPages(_ bytes: Data?, _ name: String) throws {
            let saved = try #require(bytes.flatMap(PDFDocument.init(data:)), "\(name)")
            for index in 0..<saved.pageCount {
                let page = try #require(saved.page(at: index))
                let crop = page.bounds(for: .cropBox)
                #expect(crop == page.bounds(for: .mediaBox), "\(name) page \(index)")
                #expect(abs(crop.width - size.width) < 0.5 && abs(crop.height - size.height) < 0.5, "\(name) \(crop)")
            }
        }
        try expectLogicalPages(
            try await ReadingPDFExporter.data(from: document, entries: [], title: "T"), "reading PDF")
        let sheets = try await renderer.render(source, settings: settings).sheetDocument
        try expectLogicalPages(sheets.dataRepresentation(), "sheets")
    }

    @Test("本文で目次の項目が別順に現れても、書き出した PDF のしおりは本文のページを指す")
    func trailingOrgContents() async throws {
        let source = DocumentSource(
            data: Data("#+LANGUAGE: ja\n* A\nC\n* B\n* C\n本文\n#+TOC: headlines".utf8), format: .org)
        let logical = try RenderingFixtures.pdf(pages: [["A", "C", "B"], ["C", "本文"], ["目次", "A", "B", "C"]])
        let outline = await ReadingPDFExporter.outline(
            of: source, in: logical, proof: .shown, includesSourceContents: true)
        #expect(outline.entries.map(\.pageIndex) == [0, 0, 1])
        let output = try await ReadingPDFExporter.document(from: logical, entries: outline.entries, title: "Org")
        let data = try await ReadingPDFExporter.data(from: output)
        let reread = try #require(PDFDocument(data: data))
        let root = try #require(reread.outlineRoot)
        var pages: [Int] = []
        for index in 0..<root.numberOfChildren {
            let page = try #require(root.child(at: index)?.destination?.page)
            pages.append(reread.index(for: page))
        }
        #expect(pages == [0, 0, 1])
    }

    @Test("生成した階層しおりと外部リンクは保存して読み直しても残る")
    func generatedOutline() async throws {
        let source = try RenderingFixtures.pdf(count: 2)
        let page = try #require(source.page(at: 0))
        let link = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/reading")
        page.addAnnotation(link)
        let entries = [
            OutlineEntry(level: 1, title: "First", pageIndex: 0),
            OutlineEntry(level: 3, title: "Second", pageIndex: 1),
        ]
        let output = try await ReadingPDFExporter.document(from: source, entries: entries, title: "Reading")
        let before = exportState(output)
        let bytes = try await ReadingPDFExporter.data(from: output)
        let reread = try #require(PDFDocument(data: bytes))
        #expect(reread.pageCount == 2)
        let first = try #require(reread.outlineRoot?.child(at: 0), "export[\(before)] saved[\(exportState(reread))]")
        let second = try #require(first.child(at: 0))
        #expect(first.label == "First")
        #expect(second.label == "Second")
        #expect(reread.index(for: try #require(first.destination?.page)) == 0)
        #expect(reread.index(for: try #require(second.destination?.page)) == 1)
        #expect(reread.page(at: 0)?.annotations.first?.url?.absoluteString == "https://example.com/reading")
        #expect(reread.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Reading")
        #expect(reread.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String == "Surimono")
        #expect(source.outlineRoot == nil)
    }

    @Test("元PDFのしおりとページ間リンクを保ち元文書の属性を変更しない")
    func originalPDF() async throws {
        let point = CGPoint(x: 0, y: 100)
        func checkNavigation(_ document: PDFDocument, stage: String) throws {
            let detail = "\(stage) expected bookmark to p2 and p1 link to p2@\(point); \(exportState(document))"
            let bookmark = try #require(document.outlineRoot?.child(at: 0), "\(detail)")
            #expect(bookmark.label == "Original", "\(detail)")
            let page = try #require(bookmark.destination?.page, "\(detail)")
            #expect(document.index(for: page) == 1, "\(detail)")
            let link = try #require(document.page(at: 0)?.annotations.first, "\(detail)")
            let target = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination, "\(detail)")
            #expect(document.index(for: try #require(target.page, "\(detail)")) == 1, "\(detail)")
            #expect(target.point == point, "\(detail)")
        }
        let source = try #require(PDFDocument(data: try originalPDFData(linkTarget: point)))
        try checkNavigation(source, stage: "view")
        let root = try #require(source.outlineRoot)

        let output = try await ReadingPDFExporter.document(
            from: source, entries: [], title: "After", preservesOutline: true)
        try checkNavigation(output, stage: "export")
        let bytes = try await ReadingPDFExporter.data(from: output)
        let reread = try #require(PDFDocument(data: bytes), "saved")
        try checkNavigation(reread, stage: "saved")
        #expect(reread.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "After")
        #expect(reread.documentAttributes?[PDFDocumentAttribute.authorAttribute] == nil)

        try checkNavigation(source, stage: "view after export")
        #expect(source.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Before")
        #expect(source.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Private author")
        #expect(source.outlineRoot === root)
    }

    // Author the link in the input bytes: a PDFKit action added later can disagree with its backing dictionary.
    private func originalPDFData(linkTarget: CGPoint) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info = [kCGPDFContextTitle as String: "Before", kCGPDFContextAuthor as String: "Private author"]
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary))
        context.beginPDFPage(nil)
        context.setDestination("section" as CFString, for: CGRect(x: 10, y: 10, width: 50, height: 20))
        context.endPDFPage()
        context.beginPDFPage(nil)
        context.addDestination("section" as CFString, at: linkTarget)
        context.endPDFPage()
        let bookmark: [String: Any] = [kCGPDFOutlineTitle as String: "Original", kCGPDFOutlineDestination as String: 2]
        CGPDFContextSetOutline(context, [kCGPDFOutlineChildren as String: [bookmark]] as CFDictionary)
        context.closePDF()
        return data as Data
    }

    @Test("Quartz の別ページへのリンクは柱を足した読む PDF でも同じ座標を指す")
    func namedDestinationWithFurniture() async throws {
        let point = CGPoint(x: 72, y: 400)
        let bytes = try await PDFDrawing.data(pageSize: PaperSize.a4.size) { context in
            context.beginPDFPage(nil)
            context.setDestination("section" as CFString, for: CGRect(x: 20, y: 60, width: 30, height: 10))
            context.endPDFPage()
            context.beginPDFPage(nil)
            context.addDestination("section" as CFString, at: point)
            context.endPDFPage()
        }
        let view = try #require(PDFDocument(data: bytes))
        var options = PrintOptions()
        options.furniture = .name
        let furniture = try #require(
            PDFComposer.furniture(
                onPage: 0, at: 0, pageCount: 2, layout: .a4Single, options: options,
                context: .init(fileName: "Paper.tex")))
        let output = try await ReadingPDFExporter.document(
            from: view, entries: [], title: "Paper", furniture: [0: furniture])
        let savedBytes = try await ReadingPDFExporter.data(from: output)
        let saved = try #require(PDFDocument(data: savedBytes))
        #expect(saved.page(at: 0)?.string?.contains("Paper.tex") == true)
        let stages = "view[\(exportState(view))] export[\(exportState(output))] saved[\(exportState(saved))]"
        for (name, stage) in [("view", view), ("export", output), ("saved", saved)] {
            let annotation = try #require(stage.page(at: 0)?.annotations.first)
            let target = try #require(
                (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination, "\(name): \(stages)")
            #expect(
                stage.index(for: try #require(target.page, "\(name) expected p2@\(point) \(stages)")) == 1, "\(stages)")
            #expect(target.point == point, "\(name) \(stages)")
            #expect((annotation.border?.lineWidth ?? 0) == 0)
        }
    }

    @Test("保存で消えた階層しおりと行先だけを直し、用紙・本文・外部リンク・注釈を保つ")
    func repairsMissingNavigation() async throws {
        func input() throws -> PDFDocument {
            let pdf = try RenderingFixtures.pdf(count: 2)
            let first = try #require(pdf.page(at: 0))
            first.rotation = 90
            let rect = CGRect(x: 11, y: 20, width: 35, height: 8)
            let internalLink = PDFAnnotation(bounds: rect, forType: .link, withProperties: nil)
            internalLink.destination = pdf.destination(on: first, at: .zero)
            first.addAnnotation(internalLink)
            let external = PDFAnnotation(bounds: rect, forType: .link, withProperties: nil)
            external.url = URL(string: "https://example.com/paper")
            first.addAnnotation(external)
            let note = PDFAnnotation(bounds: rect, forType: .text, withProperties: nil)
            note.contents = "Keep these notes (including /Dest [9 0 R] and >>)."
            first.addAnnotation(note)
            return pdf
        }
        let expected = try input()
        let first = try #require(expected.page(at: 0))
        let second = try #require(expected.page(at: 1))
        let target = expected.destination(on: second, at: CGPoint(x: 12, y: 103.25))
        target.zoom = 1.5
        let internalLink = try #require(first.annotations.first)
        internalLink.destination = target
        let root = PDFOutline()
        let parent = PDFOutline()
        parent.label = "First"
        parent.destination = expected.destination(on: first, at: .zero)
        root.insertChild(parent, at: 0)
        let child = PDFOutline()
        child.label = "図📄"
        child.destination = target
        parent.insertChild(child, at: 0)
        expected.outlineRoot = root

        // Supply the wrong page and no bookmarks even on systems whose native writer works.
        let damaged = try #require(try input().dataRepresentation())
        let bytes = try await ReadingPDFNavigation(expected, stage: "view (first save)").verified(
            damaged, pageCount: 2, stage: "first save")
        #expect(bytes.starts(with: damaged))
        let saved = try #require(PDFDocument(data: bytes))
        let stages = "view[\(exportState(expected))] repaired[\(exportState(saved))]"
        let headings = PDFOutlineReader.entries(of: saved)
        #expect(headings.map(\.title) == ["First", "図📄"], "\(stages)")
        #expect(headings.map(\.pageIndex) == [0, 1], "\(stages)")
        #expect(saved.outlineRoot?.numberOfChildren == 1)
        #expect(saved.outlineRoot?.child(at: 0)?.child(at: 0)?.label == "図📄")
        let page = try #require(saved.page(at: 0))
        #expect(page.rotation == 90 && page.string?.contains("PAGE-1") == true)
        // PDFKit may synthesize a popup for the text note when writing it.
        let original = try #require(PDFDocument(data: damaged))
        let originalTypes = try #require(original.page(at: 0)).annotations.map(\.type)
        #expect(page.annotations.map(\.type) == originalTypes)
        let link = try #require(page.annotations.first)
        let destination = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination)
        #expect(saved.index(for: try #require(destination.page, "repaired expected p2, \(stages)")) == 1, "\(stages)")
        #expect(destination.point == CGPoint(x: 12, y: 103.25) && destination.zoom == 1.5)
        #expect(page.annotations.contains { $0.url?.absoluteString == "https://example.com/paper" })
        #expect(page.annotations.contains { $0.contents == "Keep these notes (including /Dest [9 0 R] and >>)." })

        // A later save must resolve the newest cross-reference entry for each updated object.
        child.label = "Renamed"
        let updated = try await ReadingPDFNavigation(expected, stage: "view (second save)").verified(
            bytes, pageCount: 2, stage: "second save")
        #expect(updated.starts(with: bytes))
        let reopened = try #require(PDFDocument(data: updated))
        #expect(PDFOutlineReader.entries(of: reopened).map(\.title) == ["First", "Renamed"])
    }

    @Test("見出しなしでは空のしおりを付けない")
    func noOutline() async throws {
        let output = try await ReadingPDFExporter.document(from: RenderingFixtures.pdf(), entries: [], title: "File")
        #expect(output.outlineRoot == nil)
    }

    @Test("同じページを指すリンクの宛先を文書とともに残し、文書を閉じると解放する")
    func destinationLifetime() throws {
        var owner: PDFDocument?
        weak var weakDocument: PDFDocument?
        let destination = try autoreleasepool {
            let document = try RenderingFixtures.pdf()
            owner = document
            weakDocument = document
            let page = try #require(document.page(at: 0))
            let target = document.destination(on: page, at: CGPoint(x: 12, y: 18))
            let link = PDFAnnotation(
                bounds: CGRect(x: 0, y: 0, width: 20, height: 20), forType: .link, withProperties: nil)
            link.action = PDFActionGoTo(destination: target)
            page.addAnnotation(link)
            return target
        }
        try autoreleasepool {
            let page = try #require(destination.page)
            #expect(owner?.index(for: page) == 0)
        }
        autoreleasepool { owner = nil }
        #expect(weakDocument == nil)
        #expect(destination.page == nil)
    }

    @Test("生成PDFのローカルURLは削除し元PDFと外部URLは保持する")
    func localLinks() async throws {
        let source = try RenderingFixtures.pdf(count: 2)
        let page = try #require(source.page(at: 0))
        let addresses = [
            "file:///private/source.md#%E5%9B%B3", "file:///private/#%E5%9B%B3",
            "surimono-local://document/private/source.md#%E5%9B%B3",
            "file:///private/source.md#missing", "file:///private/other.md#%E5%9B%B3",
            "file:///private/secret.txt", "surimono-local://document/private/secret.txt",
            "https://example.com/#%E5%9B%B3", "mailto:reader@example.com",
            "surimono-snapshot://document/#%E5%9B%B3",
            "surimono-snapshot://document/surimono-snapshot-page.html#%E5%9B%B3",
            "surimono-snapshot://document/other.html#%E5%9B%B3", "about:blank#%E5%9B%B3",
            FileManager.default.temporaryDirectory.appendingPathComponent("surimono-pagination-test.html")
                .absoluteString + "#%E5%9B%B3",
        ]
        for address in addresses {
            let link = PDFAnnotation(
                bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link,
                withProperties: nil)
            link.action = PDFActionURL(url: try #require(URL(string: address)))
            page.addAnnotation(link)
        }
        let output = try await ReadingPDFExporter.document(
            from: source, entries: [OutlineEntry(level: 2, title: "図", pageIndex: 1)], title: "Test",
            headings: [DocumentHeading(level: 2, text: "図", id: "図")],
            sourceURL: URL(fileURLWithPath: "/private/source.md"))
        let data = try await ReadingPDFExporter.data(from: output)
        let reread = try #require(PDFDocument(data: data))
        let links = try #require(reread.page(at: 0)).annotations
        #expect(links.count == 9)
        let stages = "view[\(exportState(source))] export[\(exportState(output))] saved[\(exportState(reread))]"
        let localTargets = try links.compactMap { annotation -> Int? in
            guard let target = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination else {
                return nil
            }
            return reread.index(for: try #require(target.page, "saved expected p2, \(stages)"))
        }
        #expect(localTargets == Array(repeating: 1, count: 7), "\(stages)")
        #expect(
            links.compactMap { ($0.action as? PDFActionURL)?.url?.absoluteString } == [
                "https://example.com/#%E5%9B%B3", "mailto:reader@example.com",
            ])
        #expect(page.annotations.count == addresses.count)
        let preserved = try await ReadingPDFExporter.document(
            from: source, entries: [], title: "PDF", preservesOutline: true)
        #expect(preserved.page(at: 0)?.annotations.count == addresses.count)
        #expect((preserved.page(at: 0)?.annotations.first?.action as? PDFActionURL)?.url?.isFileURL == true)
    }

}

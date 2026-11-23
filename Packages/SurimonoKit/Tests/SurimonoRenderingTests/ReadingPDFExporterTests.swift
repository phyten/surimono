import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct ReadingPDFExporterTests {
    private func exportState(_ document: PDFDocument) -> String {
        var outline: CGPDFDictionaryRef?
        let raw = document.documentRef?.catalog.map { CGPDFDictionaryGetDictionary($0, "Outlines", &outline) } ?? false
        let entries = PDFOutlineReader.entries(of: document).prefix(6).map { entry in
            entry.pageIndex.map { $0 == NSNotFound ? "foreign" : String($0 + 1) } ?? "nil"
        }
        let links = (document.page(at: 0)?.annotations ?? []).prefix(12).map { annotation in
            guard let dest = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination else {
                return ((annotation.action as? PDFActionURL)?.url ?? annotation.url)?.scheme ?? "?"
            }
            guard let page = dest.page else { return "nil" }
            let index = document.index(for: page)
            return index == NSNotFound ? "foreign" : String(index + 1)
        }
        return "catalog=\(raw) bookmarks=\(entries) p1links=\(links)"
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
        let output = try ReadingPDFExporter.document(
            from: prepared.logicalDocument, entries: entries, title: "First",
            headings: try #require(prepared.facts).headings, sourceURL: source.fileURL)
        let before = exportState(output)
        let bytes = try ReadingPDFExporter.data(from: output)
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

    @Test("生成した階層しおりと外部リンクは保存して読み直しても残る")
    func generatedOutline() throws {
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
        let output = try ReadingPDFExporter.document(from: source, entries: entries, title: "Reading")
        let before = exportState(output)
        let bytes = try ReadingPDFExporter.data(from: output)
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
    func originalPDF() throws {
        let fixture = try RenderingFixtures.pdfData(count: 2, bookmarks: [("Original", 2)])
        let source = try #require(PDFDocument(data: fixture))
        let first = try #require(source.page(at: 0))
        let last = try #require(source.page(at: 1))
        let root = try #require(source.outlineRoot, "入力PDF \(exportState(source))")
        source.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Before", PDFDocumentAttribute.authorAttribute: "Private author",
        ]
        let link = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: source.destination(on: last, at: CGPoint(x: 0, y: 100)))
        first.addAnnotation(link)
        let output = try ReadingPDFExporter.document(from: source, entries: [], title: "After", preservesOutline: true)
        let before = exportState(output)
        let bytes = try ReadingPDFExporter.data(from: output)
        let reread = try #require(PDFDocument(data: bytes))
        let bookmark = try #require(
            reread.outlineRoot?.child(at: 0),
            "source[\(exportState(source))] export[\(before)] saved[\(exportState(reread))]")
        #expect(bookmark.label == "Original")
        #expect(reread.index(for: try #require(bookmark.destination?.page)) == 1)
        for stage in [source, output, reread] {
            let detail = "source[\(exportState(source))] export[\(before)] saved[\(exportState(reread))]"
            let link = try #require(stage.page(at: 0)?.annotations.first, "\(detail)")
            let target = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination, "\(detail)")
            #expect(stage.index(for: try #require(target.page, "\(detail)")) == 1, "\(detail)")
            #expect(target.point == CGPoint(x: 0, y: 100), "\(detail)")
        }
        #expect(reread.documentAttributes?[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(source.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Before")
        #expect(source.outlineRoot === root)
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
        let output = try ReadingPDFExporter.document(from: view, entries: [], title: "Paper", furniture: [0: furniture])
        let saved = try #require(PDFDocument(data: try ReadingPDFExporter.data(from: output)))
        #expect(saved.page(at: 0)?.string?.contains("Paper.tex") == true)
        for stage in [view, output, saved] {
            let annotation = try #require(stage.page(at: 0)?.annotations.first)
            let target = try #require((annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination)
            #expect(stage.index(for: try #require(target.page)) == 1)
            #expect(target.point == point)
            #expect((annotation.border?.lineWidth ?? 0) == 0)
        }
    }

    @Test("保存で消えた階層しおりと行先だけを直し、用紙・本文・外部リンク・注釈を保つ")
    func repairsMissingNavigation() throws {
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
        let bytes = try ReadingPDFNavigation(expected).verified(damaged, pageCount: 2, stage: "first save").data
        #expect(bytes.starts(with: damaged))
        let saved = try #require(PDFDocument(data: bytes))
        let headings = PDFOutlineReader.entries(of: saved)
        #expect(headings.map(\.title) == ["First", "図📄"])
        #expect(headings.map(\.pageIndex) == [0, 1])
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
        #expect(saved.index(for: try #require(destination.page)) == 1)
        #expect(destination.point == CGPoint(x: 12, y: 103.25) && destination.zoom == 1.5)
        #expect(page.annotations.contains { $0.url?.absoluteString == "https://example.com/paper" })
        #expect(page.annotations.contains { $0.contents == "Keep these notes (including /Dest [9 0 R] and >>)." })

        // A later save must resolve the newest cross-reference entry for each updated object.
        child.label = "Renamed"
        let updated = try ReadingPDFNavigation(expected).verified(bytes, pageCount: 2, stage: "second save").data
        #expect(updated.starts(with: bytes))
        let reopened = try #require(PDFDocument(data: updated))
        #expect(PDFOutlineReader.entries(of: reopened).map(\.title) == ["First", "Renamed"])
    }

    @Test("見出しなしでは空のしおりを付けない")
    func noOutline() throws {
        let output = try ReadingPDFExporter.document(from: RenderingFixtures.pdf(), entries: [], title: "File")
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
    func localLinks() throws {
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
        let output = try ReadingPDFExporter.document(
            from: source, entries: [OutlineEntry(level: 2, title: "図", pageIndex: 1)], title: "Test",
            headings: [DocumentHeading(level: 2, text: "図", id: "図")],
            sourceURL: URL(fileURLWithPath: "/private/source.md"))
        let data = try ReadingPDFExporter.data(from: output)
        let reread = try #require(PDFDocument(data: data))
        let links = try #require(reread.page(at: 0)).annotations
        #expect(links.count == 9)
        let localTargets = try links.compactMap { annotation -> Int? in
            guard let target = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination else {
                return nil
            }
            return reread.index(for: try #require(target.page))
        }
        #expect(localTargets == Array(repeating: 1, count: 7))
        #expect(
            links.compactMap { ($0.action as? PDFActionURL)?.url?.absoluteString } == [
                "https://example.com/#%E5%9B%B3", "mailto:reader@example.com",
            ])
        #expect(page.annotations.count == addresses.count)
        let preserved = try ReadingPDFExporter.document(from: source, entries: [], title: "PDF", preservesOutline: true)
        #expect(preserved.page(at: 0)?.annotations.count == addresses.count)
        #expect((preserved.page(at: 0)?.annotations.first?.action as? PDFActionURL)?.url?.isFileURL == true)
    }

}

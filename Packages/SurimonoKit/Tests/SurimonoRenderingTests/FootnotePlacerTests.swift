import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct FootnotePlacerTests {
    private let html = """
        <p>Reference<sup class="footnote-ref"><a href="#fn-1">1</a></sup></p>
        <section class="footnotes"><ol><li id="fn-1">Note</li></ol></section>
        """

    private func fixture(reserve: Bool = true, referencePage: Int = 0) throws -> PDFDocument {
        let document = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 600, height: 800))
        let body = try #require(document.page(at: 0))
        let stock = try #require(document.page(at: 1))
        let target = PDFDestination(page: stock, at: CGPoint(x: 40, y: 700))
        func link(_ rect: CGRect, on page: PDFPage) {
            let annotation = PDFAnnotation(bounds: rect, forType: .link, withProperties: nil)
            annotation.destination = target
            page.addAnnotation(annotation)
        }
        link(CGRect(x: 40, y: 696.8, width: 3.2, height: 3.2), on: stock)
        link(CGRect(x: 40, y: 680, width: 3.2, height: 3.2), on: stock)
        link(CGRect(x: 100, y: 640, width: 6, height: 10), on: try #require(document.page(at: referencePage)))
        if reserve { link(CGRect(x: 110, y: 600, width: 3.2, height: 3.2), on: body) }
        let external = PDFAnnotation(
            bounds: CGRect(x: 60, y: 550, width: 40, height: 10), forType: .link, withProperties: nil)
        external.url = URL(string: "https://example.test")
        body.addAnnotation(external)
        let issue = PDFAnnotation(
            bounds: CGRect(x: 42, y: 688, width: 1, height: 1), forType: .link, withProperties: nil)
        issue.url = URL(string: "surimono-issue:0")
        stock.addAnnotation(issue)
        let change = PDFAnnotation(
            bounds: CGRect(x: 42, y: 530, width: 1, height: 10), forType: .link, withProperties: nil)
        change.url = URL(string: "surimono-mark:block")
        body.addAnnotation(change)
        return document
    }

    @Test("測定した脚注の高さと最初の参照から予約量を決める")
    func measurement() throws {
        let planned = try #require(PageFootnotes.plan(for: html))
        let document = try fixture(reserve: false)
        let measured = try FootnotePlacer.measure(document, plan: planned, placing: [1])
        #expect(measured.stock.count == 1)
        #expect(measured.stock.first?.rect.height == 20)
        let groups = try FootnotePlacer.groups(for: measured, plan: planned, contentHeight: 700, textScale: 1)
        #expect(groups.count == 1)
        #expect(groups.first?.heightPixels == 40)
        #expect(try FootnotePlacer.groups(for: measured, plan: planned, contentHeight: 40, textScale: 1).isEmpty)
    }

    @Test("ストック以降を落とし本文と脚注のリンクと検査アンカーを移動する")
    func annotations() throws {
        let planned = try #require(PageFootnotes.plan(for: html))
        let document = try fixture()
        let output = try FootnotePlacer.compose(
            document, plan: planned,
            groups: [.init(firstReference: 0, notes: [1], heightPixels: 40)],
            margins: .init(top: 40, left: 40, bottom: 40, right: 40))
        #expect(output.pageCount == 1)
        let page = try #require(output.page(at: 0))
        #expect(page.annotations.count == 3)
        let external = try #require(page.annotations.first { $0.url?.scheme == "https" })
        #expect(abs(external.bounds.minY - 579) < 0.01)
        let issue = try #require(page.annotations.first { $0.url?.scheme == "surimono-issue" })
        #expect(abs(issue.bounds.minY - 48) < 0.01)
        let change = try #require(page.annotations.first { $0.url?.scheme == "surimono-mark" })
        #expect(abs(change.bounds.minY - 559) < 0.01)
        #expect(document.pageCount == 3)
        #expect(document.page(at: 0)?.annotations.count == 4)
        let issues = PrintIssueAnchors.extract(from: output, issues: [PrintIssue(id: "0", kind: .math, detail: "test")])
        #expect(issues.first?.pageNumber == 1)
        #expect(abs((issues.first?.rect?.minY ?? 0) - 48) < 0.01)
        let changes = ChangeMarkAnchors.extract(from: output, requests: [MarkdownMarkRequest(blockID: "block")])
        #expect(changes.first?.pageIndex == 0)
        #expect(abs((changes.first?.rect.minY ?? 0) - 559) < 0.01)
        #expect(page.annotations.count == 1)
    }

    @Test("文字のない測定印と参照が未定義の同じ宛先を持つとき原紙から脚注を置ける")
    func missingStockDestination() async throws {
        let planned = try #require(PageFootnotes.plan(for: html))
        let bytes = try await PDFDrawing.data(pageSize: CGSize(width: 600, height: 800)) { context in
            // Quartz writes the same indirect /Dest on each of these annotations but
            // no destination object when nothing defines the name.
            let note = "fn-1" as CFString
            context.beginPDFPage(nil)
            context.setDestination(note, for: CGRect(x: 100, y: 640, width: 6, height: 10))
            context.setDestination(note, for: CGRect(x: 110, y: 600, width: 3, height: 3))
            context.endPDFPage()
            context.beginPDFPage(nil)
            context.setDestination(note, for: CGRect(x: 40, y: 697, width: 3, height: 3))
            context.setDestination(note, for: CGRect(x: 40, y: 680, width: 3, height: 3))
            context.endPDFPage()
        }
        #expect(try FootnotePlacer.recoverStock(in: bytes, expected: [.init(references: 2, reservesRoom: true)]) == nil)
        let recovered = try #require(
            try FootnotePlacer.recoverStock(in: bytes, expected: [.init(references: 1, reservesRoom: true)]))
        // Exercise the same trim and PDFKit reopen that otherwise erase the dangling identity.
        let printed = try #require(PDFDocument(data: recovered))
        for index in 0..<printed.pageCount {
            let page = try #require(printed.page(at: index))
            let paper = CGRect(x: 0, y: 2, width: 600, height: 798)
            page.setBounds(paper, for: .mediaBox)
            page.setBounds(paper, for: .cropBox)
        }
        let trimmed = try #require(printed.dataRepresentation())
        let raw = try #require(PDFDocument(data: trimmed))
        let measured = try FootnotePlacer.measure(raw, plan: planned, placing: [1])
        #expect(measured.stock.first?.rect.height == 20)
        #expect(measured.references[0]?.page == 0)
        let groups = try FootnotePlacer.groups(for: measured, plan: planned, contentHeight: 720, textScale: 1)
        // Simulate a successful reading repair which omits all private stock links.
        let reading = try #require(PDFDocument(data: trimmed))
        for index in 0..<reading.pageCount {
            let page = try #require(reading.page(at: index))
            for mark in page.annotations { page.removeAnnotation(mark) }
        }
        let url = try #require(URL(string: "https://example.test/read"))
        let external = PDFAnnotation(
            bounds: CGRect(x: 30, y: 740, width: 28, height: 10),
            forType: .link, withProperties: nil)
        external.url = url
        reading.page(at: 0)?.addAnnotation(external)
        let margins = WebPaginator.Margins(top: 40, left: 40, bottom: 40, right: 40)
        let placed = try FootnotePlacer.composition(
            raw, annotationSource: reading, plan: planned, groups: groups, margins: margins)
        #expect(placed.document.pageCount == 1)
        #expect(placed.document.page(at: 0)?.annotations.map(\.url) == [url])
        // A missing navigation reply uses the same raw measurement and stock removal.
        let withoutReading = try FootnotePlacer.compose(raw, plan: planned, groups: groups, margins: margins)
        #expect(withoutReading.pageCount == placed.document.pageCount)
        #expect(withoutReading.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test("リンク計測の結果にかかわらず原紙を使ってページ下の脚注を組む", arguments: [false, true])
    func separateReadingAndLayout(repaired: Bool) async throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        var options = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        options.finish.footnotes = .pageBottom
        let source = DocumentSource(data: Data("A reference[^one].\n\n[^one]: Note.".utf8), format: .markdown)
        var measured: [Bool] = []
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let pass = try #require(request.footnotePass)
            measured.append(pass.measuresOnly)
            #expect(pass.stock == [.init(references: 1, reservesRoom: !pass.measuresOnly)])
            let layout = try fixture(reserve: !pass.measuresOnly)
            if pass.measuresOnly || !repaired { return .init(document: layout) }
            // The reading copy has an external link but none of the stock's geometry.
            let reader = try RenderingFixtures.pdf(count: layout.pageCount, size: CGSize(width: 600, height: 800))
            let link = PDFAnnotation(
                bounds: CGRect(x: 40, y: 720, width: 60, height: 14),
                forType: .link, withProperties: nil)
            link.url = URL(string: "https://example.test/reader")
            reader.page(at: 0)?.addAnnotation(link)
            var result = WebPaginator.Result(document: reader)
            result.footnoteLayout = layout
            return result
        })
        let placed = try await renderer.prepare(source, settings: options).logicalDocument
        #expect(measured == [true, false])
        #expect(placed.pageCount == 1)
        let url = repaired ? "https://example.test/reader" : "https://example.test"
        #expect(placed.page(at: 0)?.annotations.contains { $0.url?.absoluteString == url } == true)
    }

    @Test("予約マーカーが失われたときは部分合成せず失敗する")
    func missingReserve() throws {
        let planned = try #require(PageFootnotes.plan(for: html))
        let document = try fixture(reserve: false)
        #expect(throws: FootnotePlacer.PlacementError.self) {
            try FootnotePlacer.compose(
                document, plan: planned,
                groups: [.init(firstReference: 0, notes: [1], heightPixels: 40)], margins: .uniform(millimeters: 10))
        }
    }

    @Test("同じ行の初回参照をまとめ繰り返し参照は予約を増やさない")
    func lineGroups() throws {
        let fragment = """
            <p><sup class="footnote-ref"><a href="#fn-1">1</a></sup>
            <sup class="footnote-ref"><a href="#fn-2">2</a></sup>
            <sup class="footnote-ref"><a href="#fn-1">1</a></sup></p>
            <section class="footnotes"><ol><li id="fn-1">One</li><li id="fn-2">Two</li></ol></section>
            """
        let planned = try #require(PageFootnotes.plan(for: fragment))
        let measured = FootnotePlacer.Measurement(
            stock: [
                .init(number: 1, page: 2, rect: CGRect(x: 0, y: 700, width: 600, height: 20)),
                .init(number: 2, page: 2, rect: CGRect(x: 0, y: 650, width: 600, height: 30)),
            ],
            references: [
                0: .init(page: 0, rect: CGRect(x: 80, y: 600, width: 6, height: 10)),
                1: .init(page: 0, rect: CGRect(x: 100, y: 601, width: 6, height: 10)),
                2: .init(page: 1, rect: CGRect(x: 80, y: 600, width: 6, height: 10)),
            ])
        let groups = try FootnotePlacer.groups(for: measured, plan: planned, contentHeight: 700, textScale: 1)
        #expect(groups.count == 1)
        #expect(groups.first?.notes == [1, 2])
        #expect(groups.first?.firstReference == 0)
        #expect(groups.first?.heightPixels == 78)
        #expect(try FootnotePlacer.groups(for: measured, plan: planned, contentHeight: 100, textScale: 1).isEmpty)
    }

    @Test("予約で参照が次のページへ移ってもそのページの予約と一致すれば配置する")
    func movesToNextPage() throws {
        let planned = try #require(PageFootnotes.plan(for: html))
        let document = try fixture()
        let blankDocument = try RenderingFixtures.pdf()
        let blank = try #require(blankDocument.page(at: 0))
        document.insert(try #require(StandalonePage.copy(of: blank)), at: 0)
        let output = try FootnotePlacer.compose(
            document, plan: planned,
            groups: [.init(firstReference: 0, notes: [1], heightPixels: 40)],
            margins: .init(top: 40, left: 40, bottom: 40, right: 40))
        #expect(output.pageCount == 2)
        #expect(
            output.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                == document.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(output.page(at: 1)?.annotations.contains { $0.url?.scheme == "surimono-issue" } == true)
    }

    @Test("脚注を移さない本文ページのリンクを付け直しても元の注釈配列は増えない")
    func placementKeepsOriginalLinks() async throws {
        let planned = try #require(PageFootnotes.plan(for: html))
        let document = try fixture()
        let linked = try #require(PDFDocument(data: PageSourceLifetimeTests.linkedPDF()))
        let page = try #require(linked.page(at: 0))
        document.insert(page, at: 0)
        let output = try FootnotePlacer.compose(
            document, plan: planned, groups: [.init(firstReference: 0, notes: [1], heightPixels: 40)],
            margins: .init(top: 40, left: 40, bottom: 40, right: 40))
        let annotations = try #require(output.page(at: 0)).annotations
        try #require(annotations.count == 1)
        #expect(annotations.first?.url?.absoluteString == "https://example.com/")
        let backing = try await ReadingPDFRawNavigation.capture(try #require(page.pageRef?.document))
        #expect(backing.annotationCounts == [1])
    }

    @Test("用紙の原点がゼロでなくても箱とリンク座標を保つ")
    func nonzeroOrigin() throws {
        let planned = try #require(PageFootnotes.plan(for: html))
        let document = try fixture()
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            page.setBounds(CGRect(x: 10, y: 20, width: 600, height: 800), for: .mediaBox)
            page.setBounds(CGRect(x: 10, y: 20, width: 600, height: 800), for: .cropBox)
        }
        let output = try FootnotePlacer.compose(
            document, plan: planned,
            groups: [.init(firstReference: 0, notes: [1], heightPixels: 40)],
            margins: .init(top: 40, left: 40, bottom: 40, right: 40))
        let page = try #require(output.page(at: 0))
        #expect(page.bounds(for: .mediaBox) == CGRect(x: 10, y: 20, width: 600, height: 800))
        let issue = try #require(page.annotations.first { $0.url?.scheme == "surimono-issue" })
        #expect(abs(issue.bounds.minY - 68) < 0.01)
    }
}

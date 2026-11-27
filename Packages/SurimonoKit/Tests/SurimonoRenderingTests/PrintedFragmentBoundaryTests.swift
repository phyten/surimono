import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct PrintedFragmentBoundaryTests {
    @Test("リンク計測が途中で失敗しても印刷用 CSS の文字と座標を保つ", .timeLimit(.minutes(1)))
    func printCSS() async throws {
        let body = PaperLinks.inline.apply(
            to: """
                <p><a href="#first">Read</a> <a href="https://example.org">Site</a> <a href="#again">More</a></p>
                <h2 id="first"><strong>Heading</strong></h2><h2 id="again">Again</h2>
                """)
        let html = """
            <!doctype html><style>@media print {
            a[href^="#"]::after { content:" [" attr(href) "]" }
            h2 > strong:first-child { font-size:50px }
            }</style>\(body)
            """
        // Throw on the second target, after the first target has been read.
        let failure = """
            const get = document.getElementById.bind(document);
            document.getElementById = id => { if (id === 'again') throw Error('interrupted'); return get(id); };
            """
        func render(_ script: String?) async throws -> PDFDocument {
            try await WebPaginator().paginate(
                .html(html, baseURL: nil), pageSize: CGSize(width: 440, height: 600), margins: .uniform(millimeters: 8),
                allowsJavaScript: false, preparationScript: script)
        }
        let complete = try await render(nil)
        let fallback = try await render(failure)
        #expect(complete.string == fallback.string)
        #expect(complete.pageCount == fallback.pageCount)
        #expect(complete.string?.contains("[#first]") == true)
        #expect(complete.string?.contains("(https://example.org)") == true)
        for text in ["Read", "Site", "Heading", "Again"] {
            let a = try #require(complete.findString(text).first)
            let b = try #require(fallback.findString(text).first)
            #expect(a.bounds(for: a.pages[0]) == b.bounds(for: b.pages[0]))
        }
        let heading = try #require(complete.findString("Heading").first)
        #expect(heading.bounds(for: heading.pages[0]).height > 30)
        let label = try #require(complete.findString("Read").first)
        let source = try #require(label.pages.first)
        let hit = label.bounds(for: source)
        let link = try #require(source.annotations.first { $0.bounds.contains(CGPoint(x: hit.midX, y: hit.midY)) })
        let point = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination).point
        #expect(abs(point.y - heading.bounds(for: heading.pages[0]).maxY) < 1)
    }

    @Test("絶対配置した画像の静的位置が同じ紙でも別の紙でもリンク先に使わない", .timeLimit(.minutes(1)))
    func replacedTargets() async throws {
        let image =
            "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='60' height='60'%3E%3Crect width='60' height='60'/%3E%3C/svg%3E"
        let html = """
            <!doctype html><style>img { position:absolute; top:100px; left:200px; width:60px; height:60px }</style>
            <p><a href="#near">Near</a> <a href="#far">Far</a> <a href="#a%3Ab%5B1%5D">Go</a></p>
            <img id="near" src="\(image)" alt=""><h2 id="a:b[1]">First match</h2>
            <div style="break-before:page">Later page</div><img id="far" src="\(image)" alt=""><h2 id="a:b[1]">Duplicate</h2>
            """
        let pdf = try await WebPaginator().paginate(
            .snapshot(html, directory: FileManager.default.temporaryDirectory),
            pageSize: CGSize(width: 350, height: 400), margins: .uniform(millimeters: 5), allowsJavaScript: false)
        try #require(pdf.pageCount == 2)
        let source = try #require(pdf.page(at: 0))
        let links = source.annotations.filter { $0.type == "Link" }
        try #require(links.count == 1)
        let target = try #require((links[0].action as? PDFActionGoTo)?.destination ?? links[0].destination)
        #expect(target.page === source)
        let heading = try #require(pdf.findString("First match").first).bounds(for: source)
        #expect(abs(target.point.y - heading.maxY) < 1)
    }

    @Test("縦組みの冊子では次の章の字が印刷された座標へ移る", .timeLimit(.minutes(1)))
    func verticalDestination() async throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let html = HTMLDocumentBuilder.build(
            fragment: .init(body: "<p><a href=\"#section\">甲</a></p><h1 id=\"section\">乙</h1><p>丙</p>"),
            format: .org, theme: theme)
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a5.size, margins: .uniform(millimeters: 10),
            allowsJavaScript: false, verticalBooklet: true, verticalTextScale: 1.2, flow: .vertical)
        let logical = result.document
        let saved = try await ReadingPDFExporter.data(from: logical, entries: [], title: "縦組")
        let copy = try #require(PDFDocument(data: saved))
        for pdf in [logical, copy] {
            let source = try #require(pdf.findString("甲").first?.pages.first)
            let heading = try #require(pdf.findString("乙").first)
            let page = try #require(heading.pages.first)
            #expect(page !== source)
            let annotation = try #require(source.annotations.first { $0.type == "Link" })
            let dest = try #require((annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination)
            let rect = heading.bounds(for: page)
            #expect(dest.page === page)
            #expect(abs(dest.point.x - rect.minX) < 1 && abs(dest.point.y - rect.maxY) < 1)
        }
    }

    @Test("縦の切片を縮小しても抽出順が逆の章の字を紙面上の位置で識別する")
    func verticalExtractionOrder() async throws {
        let size = CGSize(width: 250, height: 300)
        let bytes = try RenderingFixtures.pdfData(pages: [["甲"], ["丙", "乙", "乙"]], size: size)
        let pdf = try #require(PDFDocument(data: bytes))
        let source = try #require(pdf.page(at: 0))
        let heading = try #require(pdf.page(at: 1))
        let label = try #require(pdf.findString("甲").first).bounds(for: source)
        let occurrence = try #require(pdf.findString("乙").first).bounds(for: heading)
        let paper = CGRect(x: 10, y: 20, width: 210, height: 260)
        let strip = CGRect(x: 60, y: 80, width: 420, height: 520)
        func box(_ rect: CGRect, slice: Int) -> PrintedFragmentLinks.Box {
            .init(
                slice: slice, x: strip.minX + 2 * (rect.minX - paper.minX),
                y: strip.minY + 2 * (paper.maxY - rect.maxY), width: 2 * rect.width, height: 2 * rect.height)
        }
        var layout = PrintedFragmentLinks.VerticalLayout()
        for i in 0..<2 { layout.record(i, .init(source: strip, paper: paper, page: i)) }
        let snap = PrintedFragmentLinks(
            text: "甲乙乙丙",
            links: [
                .init(
                    id: "chapter", url: "about:blank#chapter", start: 0, end: 1, top: false,
                    boxes: [box(label, slice: 0)])
            ],
            anchors: [.init(id: "chapter", start: 1, end: 2, box: box(occurrence, slice: 1), glyph: "乙")], rows: [])
        #expect(try await snap.resolve(in: bytes).bytes == nil)
        let result = try await snap.resolve(in: bytes, verticalLayout: layout)
        let logical = try #require(result.reopened?.document)
        let exported = try await ReadingPDFExporter.data(from: logical, entries: [], title: "章")
        for doc in [logical, try #require(PDFDocument(data: exported))] {
            let annotation = try #require(doc.page(at: 0)?.annotations.first)
            #expect(annotation.bounds.contains(CGPoint(x: label.midX, y: label.midY)))
            let dest = try #require(annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination)
            #expect(dest.page === doc.page(at: 1))
            #expect(abs(dest.point.x - occurrence.minX) < 0.02 && abs(dest.point.y - occurrence.maxY) < 0.02)
        }
    }

    @Test("柱付き LaTeX の目次は左右の余白を入れ替えた本文と書き出した紙で同じ行を指す", .timeLimit(.minutes(1)))
    func latexWithFurniture() async throws {
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass[twoside]{article}\usepackage{hyperref}\usepackage{fancyhdr}
                \pagestyle{fancy}\fancyhf{}\lhead{RUNNINGHEAD}
                \begin{document}\tableofcontents\clearpage\section{Arrival}\label{here} Body.\end{document}
                """#.utf8), format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .a4Duplex, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = nil
        settings.options.margins = .init(top: 18, left: 30, bottom: 18, right: 10)
        settings.options.mirrorsMargins = true
        let result = try await DocumentRenderer().prepare(source, settings: settings)
        let pdf = result.logicalDocument
        let data = try await ReadingPDFExporter.data(
            from: pdf, entries: [], title: "LaTeX", furniture: result.viewFurniture)
        let saved = try #require(PDFDocument(data: data))
        #expect(saved.string?.contains("RUNNINGHEAD") == true)
        for document in [pdf, saved] {
            let contents = try #require(document.page(at: 0))
            let line = try #require(document.findString("Arrival").first { $0.pages.first !== contents })
            let page = try #require(line.pages.first)
            let destinations = contents.annotations.compactMap {
                ($0.action as? PDFActionGoTo)?.destination ?? $0.destination
            }
            let dest = try #require(destinations.first)
            #expect(dest.page === page)
            let heading = line.bounds(for: page)
            // A numbered heading begins at the section number, before the title.
            #expect(dest.point.x <= heading.minX + 1 && heading.minX - dest.point.x < 60)
            #expect(abs(dest.point.y - heading.maxY) < heading.height)
        }
    }

    @Test("合本で同じ本文を二度挟んでも目次は各冊の見出しを指す", .timeLimit(.minutes(1)))
    func binderOccurrences() async throws {
        let chapter = DocumentSource(data: Data("#+OPTIONS: toc:t num:nil\n* Destination\n本文".utf8), format: .org)
        var settings = RenderSettings(
            layout: .a4Duplex,
            theme: .init(id: "test", name: "", css: "h1 {break-before:page}"), preset: .init(id: "none", name: ""))
        settings.options.mirrorsMargins = true
        settings.options.margins = .init(top: 12, left: 30, bottom: 12, right: 10)
        let result = try await DocumentRenderer().prepare(.binder([chapter, chapter]), settings: settings)
        let logical = result.logicalDocument
        let saved = try await ReadingPDFExporter.data(from: logical, entries: [], title: "Binder")
        let copy = try #require(PDFDocument(data: saved))
        var firstRelativeY: CGFloat?
        for (stage, pdf) in [("logical", logical), ("export", copy)] {
            try #require(pdf.pageCount == 4)
            for i in [0, 2] {
                let first = try #require(pdf.page(at: i))
                let second = try #require(pdf.page(at: i + 1))
                let link = try #require(first.annotations.first { $0.type == "Link" })
                let dest = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination)
                let heading = try #require(pdf.findString("Destination").first { $0.pages.first === second }).bounds(
                    for: second)
                let media = second.bounds(for: .mediaBox)
                let targetIndex = dest.page.map { String(pdf.index(for: $0)) } ?? "nil"
                let detail =
                    "\(stage) sourceIndex=\(i) expectedIndex=\(i + 1) actualIndex=\(targetIndex) "
                    + "destination=\(dest.point) heading=\(heading) mediaBox=\(media) cropBox=\(second.bounds(for: .cropBox))"
                #expect(dest.page === second, "\(detail)")
                #expect(abs(dest.point.x - heading.minX) < 1, "\(detail)")
                // The anchor uses the first character. The search measures the whole title.
                #expect(abs(dest.point.y - heading.maxY) < heading.height, "\(detail)")

                // Both copies of the same child and their exports must still preserve the same point on paper.
                let relativeY = dest.point.y - media.minY
                if let firstRelativeY {
                    #expect(
                        abs(relativeY - firstRelativeY) < 0.02,
                        "\(detail) relativeY=\(relativeY) first=\(firstRelativeY)")
                } else {
                    firstRelativeY = relativeY
                }
            }
        }
    }

    @Test("ページにまたがるリンクの両端は原点と文字倍率が変わっても紙の端の見出しを指す", arguments: [CGFloat(12), 24], [CGFloat(0), 2])
    func acrossPages(fontSize: CGFloat, originY: CGFloat) async throws {
        // Write the box directly: PDFKit may rebase pages when saving a setBounds edit.
        let bytes = try RenderingFixtures.pdfData(
            pages: [["Start"], ["End"], ["Other", "Target"]], size: CGSize(width: 250, height: 298),
            origin: CGPoint(x: 0, y: originY), lineSpacing: 230, font: .systemFont(ofSize: fontSize))
        let snapshot = PrintedFragmentLinks(
            text: "StartEndOtherTarget",
            links: [.init(id: "edge", url: "about:blank#edge", start: 0, end: 8, top: false)],
            anchors: [.init(id: "edge", start: 13, end: 19)], rows: [])
        let output = try await snapshot.resolve(in: bytes)
        let repaired = try #require(output.bytes)
        let logical = try #require(PDFDocument(data: repaired))
        let mirrored = try #require(
            PaperComposer.compose(logical, paper: nil, bindsPrintedLinks: true, shift: { $0 == 1 ? 15 : 0 }))
        var documents = [logical, mirrored]
        for document in [logical, mirrored] {
            let saved = try await ReadingPDFExporter.data(from: document, entries: [], title: "Edge")
            documents.append(try #require(PDFDocument(data: saved)))
        }
        for pdf in documents {
            let page = try #require(pdf.page(at: 2))
            let heading = try #require(pdf.findString("Target").first).bounds(for: page)
            for (i, word) in ["Start", "End"].enumerated() {
                let source = try #require(pdf.page(at: i))
                let hit = try #require(pdf.findString(word).first).bounds(for: source)
                try #require(source.annotations.count == 1)
                let link = source.annotations[0]
                #expect(link.bounds.contains(CGPoint(x: hit.midX, y: hit.midY)))
                let dest = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination)
                #expect(dest.page === page)
                #expect(
                    abs(dest.point.x - heading.minX) < 0.02 && abs(dest.point.y - heading.maxY) < 0.02,
                    "source=\(word) destination=\(dest.point) heading=\(heading) mediaBox=\(page.bounds(for: .mediaBox))"
                )
            }
        }
    }

    @Test("重複する文字に別のリンクが重なっても元の移動先を修復後と書き出し後に保つ", arguments: [true, false])
    func ambiguousGoTo(hasTarget: Bool) async throws {
        let original = try RenderingFixtures.pdfData(pages: [["X", "X"], ["Alpha"], ["Beta"]])
        let paper = try #require(PDFDocument(data: original))
        let source = try #require(paper.page(at: 0))
        let firstX = try #require(source.selection(for: NSRange(location: 0, length: 1))).bounds(for: source)
        let point = CGPoint(x: 40, y: 700)
        let bytes = try ReadingPDFNavigationWriter.repair(
            original, links: [], bookmarks: nil,
            adding: [.init(page: 0, bounds: firstX, destination: .init(page: 1, point: point, zoom: 0))])

        // A has no DOM text. B's X can match either printed X. The unambiguous link
        // on Alpha ensures the repair writes new PDF bytes even when it leaves A alone.
        let id = hasTarget ? "beta" : "absent"
        let snapshot = PrintedFragmentLinks(
            text: "XAlphaBeta",
            links: [
                .init(id: "alpha", url: "about:blank#alpha", start: 0, end: 0, top: false),
                .init(id: id, url: "about:blank#\(id)", start: 0, end: 1, top: false),
                .init(id: "beta", url: "about:blank#beta", start: 1, end: 6, top: false),
            ],
            anchors: [.init(id: "alpha", start: 1, end: 6), .init(id: "beta", start: 6, end: 10)], rows: [])
        let repaired = try await snapshot.resolve(in: bytes)
        let logical = try #require(repaired.reopened?.document)
        let saved = try await ReadingPDFExporter.data(from: logical, entries: [], title: "Links")
        for pdf in [logical, try #require(PDFDocument(data: saved))] {
            let links = try #require(pdf.page(at: 0)).annotations
            try #require(links.count == 1)
            let a = try #require((links[0].action as? PDFActionGoTo)?.destination ?? links[0].destination)
            #expect(a.page === pdf.page(at: 1))
            #expect(a.point == point)
            let other = try #require(pdf.page(at: 1)?.annotations.first)
            #expect(((other.action as? PDFActionGoTo)?.destination ?? other.destination)?.page === pdf.page(at: 2))
        }
    }

    @Test(
        "印刷で番号が重複したときは候補位置にある同じ URL の注釈だけを修復する",
        arguments: [("note", "note", true), ("note", "%6Eote", true), ("%FF", "%FE", false)])
    func ambiguousMatchingURL(printed: String, dom: String, matches: Bool) async throws {
        let paper = try RenderingFixtures.pdf(pages: [["1", "1"], ["Note"]])
        let source = try #require(paper.page(at: 0))
        let hits = paper.findString("1")
        try #require(hits.count == 2)
        let base = "https://example.org/document#"
        let url = try #require(URL(string: base + printed))
        for hit in hits {
            let annotation = PDFAnnotation(bounds: hit.bounds(for: source), forType: .link, withProperties: nil)
            annotation.url = url
            source.addAnnotation(annotation)
        }
        let id = dom.removingPercentEncoding ?? dom
        let snapshot = PrintedFragmentLinks(
            text: "1Note", links: [.init(id: id, url: base + dom, start: 0, end: 1, top: false)],
            anchors: [.init(id: id, start: 1, end: 5)], rows: [])
        let output = try await snapshot.resolve(in: #require(paper.dataRepresentation()))
        #expect((output.reopened != nil) == matches)
        let logical = output.reopened?.document ?? paper
        let page = try #require(logical.page(at: 0))
        for (index, hit) in hits.enumerated() {
            let bounds = hit.bounds(for: source)
            let link = try #require(page.annotation(at: CGPoint(x: bounds.midX, y: bounds.midY)))
            if index == 0 && matches {
                #expect(
                    ((link.action as? PDFActionGoTo)?.destination ?? link.destination)?.page === logical.page(at: 1))
            } else {
                #expect(link.url == url)
            }
        }
    }

    @Test("文書内リンクの DOM 走査には 100 ミリ秒と検査回数・項目数の上限がある")
    func scanLimits() throws {
        let script = try #require(PrintedFragmentLinks.script)
        #expect(script.contains("performance.now() + 100;"))
        #expect(script.contains("++visits > 16000 ||"))
        #expect(script.contains("entries > 4096 ||"))
    }

    @Test("文書内リンクの既定の返信期限は 500 ミリ秒で修復期限は 1 秒")
    func defaultBudgets() async throws {
        var observed: ContinuousClock.Instant?
        let before = ContinuousClock.now
        _ = try await PrintedFragmentLinks.read { deadline in
            observed = deadline
            return nil
        }
        let after = ContinuousClock.now
        let deadline = try #require(observed)
        // Bracket the creation of the deadline without sleeping or assuming a scheduling tolerance.
        #expect((before...after).contains(deadline - .milliseconds(500)))
        #expect(PrintedFragmentLinks.repairBudget == .seconds(1))
    }

    @Test("WebKit の返信期限を過ぎても完成した本文を保ち、後から来た返信を捨てる")
    func missingWebReply() async throws {
        let paper = try RenderingFixtures.pdfData(pages: [["Finished"]])
        let finished = try await VerticalPaginator.capturedData(timeout: .seconds(10)) { _ in paper }
        var late: WebKitReply<String>.Completion?
        let snapshot = try await PrintedFragmentLinks.read(budget: .seconds(10)) { deadline in
            try await WebKitReply<String>.wait(until: deadline) { reply in
                // Deliver the timeout before sending the WebKit reply, regardless of scheduling.
                late = reply
                reply(.failure(WebPaginator.PaginationError.timedOut))
            }
        }
        let lateReply = try #require(late)
        let next = try await WebKitReply<String>.wait(until: .now + .seconds(10)) { reply in
            lateReply(.success(#"{"text":"Late","links":[],"anchors":[],"rows":[]}"#))
            reply(.success("Next"))
        }
        #expect(next == "Next")
        #expect(snapshot == nil)
        let navigation = try await snapshot?.resolve(in: finished)
        let document = try #require(PDFDocument(data: navigation?.bytes ?? finished))
        #expect(document.pageCount == 1)
        #expect(document.string == "Finished")
    }

    @Test("返事がない修復は独立した期限で諦め、遅れて届いた結果を採らない")
    func silentRepair() async throws {
        let (stream, reply) = AsyncStream<Void>.makeStream()
        defer { reply.finish() }
        let result = try await PrintedFragmentLinks.bounded(until: .now + .milliseconds(12)) {
            for await _ in stream {}
            return Data([1])
        }
        #expect(result == nil)
    }

    @Test("修復が待機中でも利用者のキャンセルを伝える")
    func cancelledRepair() async throws {
        let (started, ready) = AsyncStream<Void>.makeStream()
        let (stream, reply) = AsyncStream<Void>.makeStream()
        defer {
            reply.finish()
            ready.finish()
        }
        let task = Task {
            try await PrintedFragmentLinks.bounded(until: .now + .seconds(10)) {
                ready.yield()
                for await _ in stream {}
                return Data()
            }
        }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

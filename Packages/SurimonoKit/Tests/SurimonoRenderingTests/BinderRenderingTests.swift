import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct BinderRenderingTests {
    private var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    private func children() throws -> [DocumentSource] {
        [
            DocumentSource(
                data: Data("# First".utf8), fileURL: URL(fileURLWithPath: "/fixture/a.md"), format: .markdown),
            DocumentSource(
                data: try #require(RenderingFixtures.pdf(count: 2).dataRepresentation()),
                fileURL: URL(fileURLWithPath: "/fixture/b.pdf"), format: .pdf),
            DocumentSource(
                data: try RenderingFixtures.image(), fileURL: URL(fileURLWithPath: "/fixture/c.tiff"), format: .image),
        ]
    }

    @Test("合本のHTML本文は外部更新から独立し隣の画像とスクリプトを読み込める", .timeLimit(.minutes(1)))
    func htmlSnapshotWebKit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("article.html")
        let html = "<p>Before</p><img src='image.tiff'><script src='script.js'></script>"
        try Data(html.utf8).write(to: file)
        try RenderingFixtures.image().write(to: directory.appendingPathComponent("image.tiff"))
        try Data("document.body.append('ScriptLoaded');".utf8).write(to: directory.appendingPathComponent("script.js"))
        var child = DocumentSource(data: Data(html.utf8), fileURL: file, format: .html)
        child.allowedResourceFolders = [directory]
        let source = DocumentSource.binder([child])
        let renderer = DocumentRenderer(isSandboxed: { true })
        var settings = settings
        settings.allowsJavaScriptInHTML = true
        let first = try await renderer.prepare(source, settings: settings)
        #expect(first.logicalDocument.string?.contains("Before") == true)
        #expect(first.logicalDocument.string?.contains("ScriptLoaded") == true)
        #expect(first.issues.isEmpty && first.requiredFolderAccess == nil)
        try Data("<p>After</p>".utf8).write(to: file)
        settings.options.marginsInMillimeters = 11
        let changed = try await renderer.prepare(source, settings: settings)
        #expect(changed.logicalDocument.string?.contains("Before") == true)
        #expect(changed.logicalDocument.string?.contains("After") == false)
        #expect(changed.logicalDocument.string?.contains("ScriptLoaded") == true)
        #expect(changed.issues.isEmpty && changed.requiredFolderAccess == nil)
        var refreshed = DocumentSource(data: try Data(contentsOf: file), fileURL: file, format: .html)
        refreshed.allowedResourceFolders = [directory]
        let reloaded = try await renderer.prepare(.binder([refreshed]), settings: settings)
        #expect(reloaded.logicalDocument.string?.contains("After") == true)
        #expect(reloaded.logicalDocument.string?.contains("Before") == false)
    }

    @Test("合本の自動方向は子のページの多数決で両面と2アップへ反映する", arguments: [PrintLayout.a4Duplex, .a3TwoUp])
    func automaticOrientation(layout: PrintLayout) async throws {
        for (portraitCount, landscapeCount, expected) in [
            (0, 2, PaperOrientation.landscape), (2, 4, .landscape), (4, 2, .portrait), (2, 2, .portrait),
        ] {
            var children: [DocumentSource] = []
            for (count, size) in [
                (portraitCount, CGSize(width: 200, height: 400)),
                (landscapeCount, CGSize(width: 400, height: 200)),
            ] {
                for pages in count == 2 ? [1, 1] : (count == 0 ? [] : [count]) {
                    let pdf = try RenderingFixtures.pdf(count: pages, size: size)
                    children.append(DocumentSource(data: try #require(pdf.dataRepresentation()), format: .pdf))
                }
            }
            var settings = settings
            settings.layout = layout
            let renderer = DocumentRenderer()
            let source = DocumentSource.binder(children)
            let result = try await renderer.render(source, settings: settings)
            #expect(result.resolvedOrientation == expected)
            let sheetOrientation: PaperOrientation =
                layout == .a4Duplex
                ? expected : (expected == .landscape ? .portrait : .landscape)
            #expect(result.sheetOrientations.allSatisfy { $0 == sheetOrientation })
            let childCount = renderer.binderChildRenderCount
            settings.binderStartsOnFront = true
            let padded = try await renderer.render(source, settings: settings)
            #expect(padded.resolvedOrientation == expected)
            #expect(renderer.binderChildRenderCount == childCount)
            settings.paperOrientation = .portrait
            #expect(try await renderer.prepare(source, settings: settings).resolvedOrientation == .portrait)
            settings.paperOrientation = .landscape
            #expect(try await renderer.prepare(source, settings: settings).resolvedOrientation == .landscape)
            settings.layout = .a4BookletA5
            let booklet = try await renderer.render(source, settings: settings)
            #expect(booklet.resolvedOrientation == .portrait)
            #expect(booklet.sheetOrientations.allSatisfy { $0 == .landscape })
        }
    }

    @Test("合本の自動方向は子のCropBoxと回転を反映する")
    func croppedOrientation() async throws {
        let pdf = try RenderingFixtures.pdf(count: 2, size: CGSize(width: 400, height: 400))
        pdf.page(at: 0)?.setBounds(CGRect(x: 20, y: 30, width: 300, height: 100), for: .cropBox)
        pdf.page(at: 1)?.setBounds(CGRect(x: 20, y: 30, width: 100, height: 300), for: .cropBox)
        pdf.page(at: 1)?.rotation = 90
        let source = DocumentSource.binder([DocumentSource(data: try #require(pdf.dataRepresentation()), format: .pdf)])
        var settings = settings
        settings.layout = .a4Duplex
        let result = try await DocumentRenderer().render(source, settings: settings)
        #expect(result.resolvedOrientation == .landscape)
        #expect(result.sheetOrientations == [.landscape, .landscape])
    }

    @Test("合本のHTMLは読み込み済み本文を使い相対リソースの許可とJavaScript設定を保つ", arguments: [false, true])
    func loadedHTML(sandboxed: Bool) async throws {
        var requests: [PaginationRequest] = []
        let renderer = DocumentRenderer(
            isSandboxed: { sandboxed },
            paginate: { request in
                requests.append(request)
                return try RenderingFixtures.pdf()
            })
        let file = URL(fileURLWithPath: "/fixture/article.html")
        let folder = URL(fileURLWithPath: "/fixture/assets")
        let html = "<p>Loaded</p><img src='assets/image.png'>"
        var child = DocumentSource(data: Data(html.utf8), fileURL: file, format: .html)
        child.allowedResourceFolders = [folder]
        var settings = settings
        settings.allowsJavaScriptInHTML = true
        _ = try await renderer.prepare(.binder([child]), settings: settings)
        settings.preset = HTMLCleanupPreset(id: "no-script", name: "No script", disablesJavaScript: true)
        _ = try await renderer.prepare(.binder([child]), settings: settings)
        #expect(requests.map(\.allowsJavaScript) == [true, false])
        for request in requests {
            guard case .sandboxed(let loaded, let access) = request.source else {
                Issue.record("HTMLをファイルから再取得している")
                return
            }
            #expect(loaded == html)
            #expect(access.documentURL == file)
            #expect(access.folders == (sandboxed ? [folder] : [file.deletingLastPathComponent()]))
        }
    }

    @Test("MarkdownとPDFと画像を順に結合し白紙は文書間だけに入る", .timeLimit(.minutes(1)))
    func mixed() async throws {
        let children = try children()
        let renderer = DocumentRenderer()
        var settings = settings
        let result = try await renderer.render(.binder(children), settings: settings)
        #expect(result.logicalDocument.pageCount == 4)
        #expect(result.logicalDocument.page(at: 0)?.string?.contains("First") == true)
        #expect(result.logicalDocument.page(at: 1)?.string == PDFDocument(data: children[1].data)?.page(at: 0)?.string)
        #expect(result.logicalDocument.page(at: 2)?.string == PDFDocument(data: children[1].data)?.page(at: 1)?.string)
        settings.binderStartsOnFront = true
        let front = try await renderer.render(.binder(children), settings: settings)
        #expect(front.logicalDocument.pageCount == 5)
        #expect((front.logicalDocument.page(at: 1)?.string ?? "").isEmpty)
        #expect(front.logicalDocument.page(at: 2)?.string == result.logicalDocument.page(at: 1)?.string)
    }

    @Test("文字を持つPDFは合本の論理ページと書き出した用紙でも文字を選択できる", arguments: [PrintLayout.a4Single, .a4BookletA5])
    func preservesText(layout: PrintLayout) async throws {
        let original = try RenderingFixtures.pdf(count: 2)
        let data = try #require(original.dataRepresentation())
        let source = DocumentSource.binder([
            DocumentSource(data: data, fileURL: URL(fileURLWithPath: "/fixture/text.pdf"), format: .pdf)
        ])
        var settings = settings
        settings.layout = layout
        let result = try await DocumentRenderer().render(source, settings: settings)
        let logicalData = try #require(result.logicalDocument.dataRepresentation())
        let sheetData = try #require(result.sheetDocument.dataRepresentation())
        let logicalCopy = try #require(PDFDocument(data: logicalData))
        let exported = try #require(PDFDocument(data: sheetData))
        for document in [original, result.logicalDocument, logicalCopy, exported] {
            #expect(document.pageCount == 2)
            for (index, expected) in ["PAGE-1", "PAGE-2"].enumerated() {
                let page = try #require(document.page(at: index))
                let text = try #require(page.string)
                #expect(text.contains(expected))
                // Check the text layer, not glyph coordinates or visible placement on the sheet.
                let selection = try #require(
                    page.selection(for: NSRange(location: 0, length: (text as NSString).length)))
                #expect(selection.string?.contains(expected) == true)
            }
        }
    }

    @Test("並べ替えと取り除きと表面開始では子を組版し直さず読めない子は除く")
    func cache() async throws {
        var calls = 0
        let renderer = DocumentRenderer(paginate: { _ in
            calls += 1
            return try RenderingFixtures.pdf()
        })
        let children = try children()
        let broken = DocumentSource(data: Data(), fileURL: URL(fileURLWithPath: "/fixture/broken.pdf"), format: .pdf)
        let result = try await renderer.prepare(.binder(children + [broken]), settings: settings)
        #expect(result.logicalDocument.pageCount == 4)
        #expect(result.unreadableDocumentURLs == [broken.fileURL!])
        let count = renderer.binderChildRenderCount
        let reordered = try await renderer.prepare(.binder(children.reversed()), settings: settings)
        #expect(reordered.logicalDocument.page(at: 3)?.string == result.logicalDocument.page(at: 0)?.string)
        _ = try await renderer.prepare(.binder([children[0], children[2]]), settings: settings)
        var front = settings
        front.binderStartsOnFront = true
        _ = try await renderer.prepare(.binder([children[0], children[2]]), settings: front)
        #expect(renderer.binderChildRenderCount == count)
        #expect(calls == 1)
        let changed = DocumentSource(data: Data("# Changed".utf8), fileURL: children[0].fileURL, format: .markdown)
        _ = try await renderer.prepare(.binder([changed, children[2]]), settings: front)
        #expect(calls == 2)
    }

    @Test("子の問題は白紙を含む通しページと文書ごとの位置の鍵になる")
    func issues() async throws {
        let renderer = DocumentRenderer(paginateWithResult: { _ in
            let pdf = try RenderingFixtures.pdf()
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 10, y: 10, width: 10, height: 10), forType: .link, withProperties: nil)
            annotation.url = URL(string: "surimono-issue:0")
            pdf.page(at: 0)?.addAnnotation(annotation)
            return WebPaginator.Result(
                document: pdf,
                preparationResult:
                    #"{"previous":"","issues":[{"id":"0","kind":"math","detail":"bad","locationKey":"math:0"}]}"#)
        })
        let children = try children()
        var settings = settings
        settings.binderStartsOnFront = true
        let output = try await renderer.prepare(.binder([children[1], children[0], children[0]]), settings: settings)
        #expect(output.issues.map(\.pageNumber) == [3, 5])
        #expect(Set(output.issues.map(\.id)).count == 2)
        #expect(Set(output.issues.compactMap(\.locationKey)).count == 2)
    }
    @Test("テーマとHTMLプリセットは対応する子だけを再組版しMermaidも子の経路へ渡す")
    func childSettings() async throws {
        var requests: [PaginationRequest] = []
        let renderer = DocumentRenderer(paginate: { request in
            requests.append(request)
            return try RenderingFixtures.pdf()
        })
        let markdown = DocumentSource(data: Data("```mermaid\ngraph LR; A-->B\n```".utf8), format: .markdown)
        let html = DocumentSource(data: Data("<p>HTML</p>".utf8), format: .html)
        let source = DocumentSource.binder([markdown, html])
        var settings = settings
        settings.allowsJavaScriptInHTML = true
        _ = try await renderer.prepare(source, settings: settings)
        #expect(requests.count == 2)
        #expect(requests[0].rendersMermaid)
        #expect(!requests[0].allowsJavaScript)
        #expect(requests[1].allowsJavaScript)
        settings.theme = PrintTheme(id: "other", name: "Other", css: "body { color: navy; }")
        settings.textScale = 1.5
        _ = try await renderer.prepare(source, settings: settings)
        #expect(requests.count == 3)
        #expect(requests.last?.rendersMermaid == true)
        settings.preset = HTMLCleanupPreset(id: "other", name: "Other", extraCSS: ".noise { display: none; }")
        _ = try await renderer.prepare(source, settings: settings)
        #expect(requests.count == 4)
        #expect(requests.last?.preparationScript?.contains(".noise") == true)
    }

    @Test("子の組版のキャンセルは読めない文書として握りつぶさない")
    func cancellation() async throws {
        let renderer = DocumentRenderer(paginate: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            try await renderer.prepare(
                .binder([DocumentSource(data: Data("text".utf8), format: .plainText)]), settings: settings)
        }
    }

}

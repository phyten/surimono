import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct PrintIssueRenderingTests {
    private var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single,
            theme: PrintTheme(id: "test", name: "Test", css: "body { font-size: 12pt; }"),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    @Test("既知と未知の問題リンクをすべて除去し通常のリンクは保存する")
    func extractsAllLinks() throws {
        let document = try RenderingFixtures.pdf(count: 2)
        let page = try #require(document.page(at: 1))
        for url in ["surimono-issue:known", "surimono-issue:unknown", "https://example.com"] {
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 20, y: 30, width: 1, height: 8), forType: .link, withProperties: nil)
            annotation.url = URL(string: url)
            page.addAnnotation(annotation)
        }
        let issues = PrintIssueAnchors.extract(
            from: document, issues: [PrintIssue(id: "known", kind: .math, detail: "x")])
        #expect(issues.first?.pageNumber == 2)
        #expect(issues.first?.rect == CGRect(x: 20, y: 30, width: 1, height: 8))
        let saved = try #require(document.dataRepresentation().flatMap(PDFDocument.init(data:)))
        #expect(saved.page(at: 1)?.annotations.map { $0.url?.absoluteString } == ["https://example.com"])
    }

    @Test("未知の LaTeX コマンドは印刷前の確認に一件だけ渡し、紙面には出さない")
    func unreadCommands() async throws {
        let renderer = DocumentRenderer(paginateWithResult: { request in
            if case .html(let html, _) = request.source {
                #expect(html.contains("<p>Visible</p>"))
                #expect(!html.contains("secret-option"))
                #expect(!html.contains("commands not read"))
            } else {
                Issue.record("LaTeX の本文は HTML として組版する")
            }
            return WebPaginator.Result(document: try RenderingFixtures.pdf(), preparationResult: nil)
        })
        let source = DocumentSource(data: Data(#"\unknown[secret-option]{Visible}\other\unknown"#.utf8), format: .latex)
        let result = try await renderer.render(source, settings: settings)
        #expect(result.issues.map(\.detail) == [#"commands not read: \unknown, \other"#])
        #expect(result.issues.first?.kind == .latex)
        #expect(result.issues.first?.pageNumber == nil)
    }

    @Test("図の読み取り診断と紙面上の診断をひとつにまとめ、図番号とページを残す")
    func pictureIssue() async throws {
        let renderer = DocumentRenderer(paginateWithResult: { _ in
            let printed = PrintIssue(
                id: "0", kind: .latex, detail: #"Figure 1 (TikZ) — \badA"#, element: .figure, pageNumber: 2)
            let payload = try JSONEncoder().encode([printed])
            return WebPaginator.Result(
                document: try RenderingFixtures.pdf(count: 2),
                preparationResult: "{\"issues\":" + String(decoding: payload, as: UTF8.self) + "}")
        })
        let source = #"\begin{tikzpicture}\badA;\end{tikzpicture}\begin{tikzpicture}\badB;\end{tikzpicture}"#
        let input = DocumentSource(data: Data(source.utf8), format: .latex)
        let result = try await renderer.render(input, settings: settings)
        #expect(result.issues.map(\.detail) == [#"Figure 1 (TikZ) — \badA"#, #"Figure 2 (TikZ) — \badB"#])
        #expect(result.issues.map(\.pageNumber) == [2, nil])
    }

    @Test("問題と既存の準備結果はキャッシュと両面の再合成で失われない")
    func cache() async throws {
        let renderer = DocumentRenderer(paginateWithResult: { _ in
            WebPaginator.Result(
                document: try RenderingFixtures.pdf(count: 2),
                preparationResult: #"{"previous":null,"issues":[{"id":"0","kind":"math","detail":"x"}]}"#)
        })
        let source = DocumentSource(data: Data("Body".utf8), format: .markdown)
        let first = try await renderer.render(source, settings: settings)
        var duplex = settings
        duplex.layout = .a4Duplex
        let second = try await renderer.render(source, settings: duplex)
        #expect(first.issues.count == 1)
        #expect(first.issues.first?.pageNumber == nil)
        #expect(second.issues == first.issues)
        #expect(renderer.logicalRenderCount == 1)
    }

    @Test("準備結果の紙判定と問題一覧を両方の描画経路で保持する", arguments: [false, true])
    func paperResult(separatesPaper: Bool) async throws {
        let previous = WebPaginator.clearBackground
        if separatesPaper {
            WebPaginator.clearBackground = { _ in }
        } else {
            WebPaginator.clearBackground = nil
        }
        defer { WebPaginator.clearBackground = previous }
        var calls = 0
        let renderer = DocumentRenderer(paginateWithResult: { request in
            calls += 1
            let isText = request.preparationScript?.contains("surimono-issue:") == true
            if isText {
                #expect(request.preparationScript?.contains(PaperBackground.detectionScript) == separatesPaper)
            }
            return WebPaginator.Result(
                document: try RenderingFixtures.pdf(),
                preparationResult: isText
                    ? #"{"previous":"paper","issues":[{"id":"0","kind":"latex","detail":"Unsupported drawing"}]}"#
                    : nil)
        })
        let result = try await renderer.render(
            DocumentSource(data: Data("Body".utf8), format: .plainText), settings: settings)
        #expect(result.issues.first?.detail == "Unsupported drawing")
        #expect(calls == (separatesPaper ? 2 : 1))
    }

    @Test("スマート削除の候補と問題一覧を同じ準備結果から受け取る")
    func smartRemovalResult() async throws {
        let candidate = SmartRemovalCandidate(id: "ad", category: .advertisement, excerpt: "Ad", reason: "class=ad")
        let previous = String(decoding: try JSONEncoder().encode([candidate]), as: UTF8.self)
        let envelope: [String: Any] = [
            "previous": previous,
            "issues": [["id": "0", "kind": "image", "detail": "file:///surimono-missing/flow.png"]],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        let renderer = DocumentRenderer(paginateWithResult: { _ in
            WebPaginator.Result(document: try RenderingFixtures.pdf(), preparationResult: json)
        })
        var settings = settings
        settings.smartRemoval = SmartRemovalRequest()
        let result = try await renderer.render(
            DocumentSource(data: Data("<p>Body</p>".utf8), format: .html), settings: settings)
        #expect(result.smartRemovalCandidates == [candidate])
        #expect(result.issues.first?.detail == "flow.png")
        #expect(result.issues.first?.imageFailure == .missing)
    }

    @Test("画像の失敗は許可がない場所と許可内の不存在を区別する")
    func imageFailures() {
        let file = URL(fileURLWithPath: "/tmp/surimono-nonexistent-preflight/image.png")
        let access = LocalResourceAccess(documentURL: URL(fileURLWithPath: "/tmp/document.md"))
        #expect(PrintIssueAnchors.imageFailure(file, access: access) == .folderAccess)
        #expect(PrintIssueAnchors.imageFailure(file, access: nil) == .missing)
    }

    @Test("画像と幅の広い図と壊れた数式のページを返し出力には専用リンクを残さない", .timeLimit(.minutes(1)))
    func actualPages() async throws {
        _ = NSApplication.shared
        let markdown = """
            # Test

            <p style="break-before:page"><img src="file:///surimono-missing/flow.png" alt="Flow"></p>

            <figure style="break-before:page; width:1200px; min-width:1200px">Wide figure</figure>

            <p style="break-before:page">Formula</p>

            $$\\frac{1$$

            """
        #expect(MarkdownConverter.convert(markdown).body.contains("math-error"))
        let result = try await DocumentRenderer().render(
            DocumentSource(data: Data(markdown.utf8), format: .markdown), settings: settings)
        #expect(result.issues.map(\.kind) == [.image, .overflow, .math])
        #expect(result.issues.map(\.pageNumber) == [2, 3, 4])
        #expect(result.issues.allSatisfy { $0.rect != nil })
        for document in [result.logicalDocument, result.sheetDocument] {
            let saved = try #require(document.dataRepresentation().flatMap(PDFDocument.init(data:)))
            for index in 0..<saved.pageCount {
                #expect(
                    saved.page(at: index)?.annotations.contains {
                        ($0.url ?? ($0.action as? PDFActionURL)?.url)?.scheme == "surimono-issue"
                    } == false)
            }
        }
    }

    @Test("80・120・200パーセントでも調整した表は報告せず本文より広い図だけを検出する", .timeLimit(.minutes(1)))
    func overflowAtTextScales() async throws {
        _ = NSApplication.shared
        let source = DocumentSource(
            data: Data(
                """
                <section style="padding:12px 24px;border:2px solid transparent">
                <pre style="width:100%;box-sizing:border-box">Fits</pre>
                <table style="width:100%;box-sizing:border-box"><tr><td>Fits</td></tr></table>
                <table style="width:115%;min-width:115%;max-width:none"><tr><td>Fitted</td></tr></table>
                <figure style="width:115%;margin:0">Too wide</figure>
                </section>
                """.utf8), format: .markdown)
        let renderer = DocumentRenderer()
        var settings = settings
        var keys: [String] = []
        for scale in [0.8, 1.2, 2.0] {
            settings.textScale = scale
            let result = try await renderer.render(source, settings: settings)
            #expect(result.issues.map(\.kind) == [.overflow])
            #expect(result.issues.map(\.element) == [.figure])
            keys.append(try #require(result.issues.first?.locationKey))
        }
        #expect(Set(keys).count == 1)
    }

    @Test("幅超過の有無が変わっても同じ画像と数式の出現箇所の鍵を保つ", .timeLimit(.minutes(1)))
    func keysAcrossLayouts() async throws {
        _ = NSApplication.shared
        let source = DocumentSource(
            data: Data(
                """
                ![First](file:///surimono-missing/flow.png)

                ![Second](file:///surimono-missing/flow.png)

                <figure style="width:400px;margin:0">Figure</figure>

                $$\\frac{1$$

                $$\\frac{1$$
                """.utf8), format: .markdown)
        let renderer = DocumentRenderer()
        let wide = try await renderer.render(source, settings: settings)
        var narrowSettings = settings
        narrowSettings.layout = .a4BookletA5
        let narrow = try await renderer.render(source, settings: narrowSettings)
        #expect(!wide.issues.contains { $0.kind == .overflow })
        #expect(narrow.issues.contains { $0.kind == .overflow })
        for kind in [PrintIssue.Kind.image, .math] {
            let before = wide.issues.filter { $0.kind == kind }
            let after = narrow.issues.filter { $0.kind == kind }
            #expect(before.count == 2)
            #expect(before.map(\.locationKey) == after.map(\.locationKey))
            #expect(Set(before.compactMap(\.locationKey)).count == 2)
        }
        #expect(wide.issues.first { $0.kind == .math }?.id != narrow.issues.first { $0.kind == .math }?.id)
    }

    @Test("問題のない文書は空の一覧を返しHTMLのWeb画像は対象にしない", .timeLimit(.minutes(1)))
    func cleanDocuments() async throws {
        _ = NSApplication.shared
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let inspection = """
                const result = await (async () => { \(request.preparationScript ?? "") })();
                const envelope = JSON.parse(result);
                envelope.anchorCount = document.querySelectorAll('.surimono-issue-anchor').length;
                return JSON.stringify(envelope);
                """
            let result = try await WebPaginator().paginateWithResult(
                request.source, pageSize: request.pageSize, margins: request.margins,
                allowsJavaScript: request.allowsJavaScript, preparationScript: inspection,
                readsPageRules: request.readsPageRules, drawsBackground: request.drawsBackground)
            let json = try #require(result.preparationResult)
            let envelope = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(envelope["anchorCount"] as? Int == 0)
            return result
        })
        let clean = try await renderer.render(
            DocumentSource(data: Data("# Hello\n\nA short paragraph.".utf8), format: .markdown), settings: settings)
        #expect(clean.issues.isEmpty)
        let html = """
            <meta http-equiv="Content-Security-Policy" content="img-src 'none'">
            <p>Body</p><img src="https://example.invalid/flow.png"><img src="data:image/png;base64,broken">
            """
        let web = try await renderer.render(DocumentSource(data: Data(html.utf8), format: .html), settings: settings)
        #expect(web.issues.isEmpty)
    }
}

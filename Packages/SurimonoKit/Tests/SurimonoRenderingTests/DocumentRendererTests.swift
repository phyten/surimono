import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct DocumentRendererTests {
    private var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: "body { font-size: 12pt; }"),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    @Test(
        "文字倍率の変更はテーマ形式だけを再組版し、同じ倍率ならキャッシュを使う",
        arguments: [DocumentFormat.markdown, .org, .plainText, .csv, .html])
    func textScaleCache(format: DocumentFormat) async throws {
        var requests: [PaginationRequest] = []
        let renderer = DocumentRenderer(paginate: { request in
            requests.append(request)
            return try RenderingFixtures.pdf()
        })
        let source = DocumentSource(data: Data("Body".utf8), format: format)
        var settings = settings
        _ = try await renderer.render(source, settings: settings)
        settings.textScale = 1.5
        _ = try await renderer.render(source, settings: settings)
        _ = try await renderer.render(source, settings: settings)
        if format == .html {
            #expect(requests.count == 1)
        } else {
            #expect(requests.count == 2)
            if case .html(let html, _) = try #require(requests.last).source {
                #expect(html.contains("html { zoom: 1.5; }"))
            } else {
                Issue.record("テーマ形式はHTMLで組版する")
            }
        }
    }

    @Test("Markdownの見出しを含む論理ページPDFを作れる", .timeLimit(.minutes(1)))
    func markdown() async throws {
        _ = NSApplication.shared
        let result = try await DocumentRenderer().render(
            DocumentSource(data: Data("# Heading-MARKER\n\nBody".utf8), format: .markdown), settings: settings)
        #expect(result.logicalDocument.pageCount >= 1)
        #expect(result.logicalDocument.string?.contains("Heading-MARKER") == true)
    }

    @Test("12ページのPDFは組版せずA3冊子3枚6面にする")
    func pdf() async throws {
        let document = try RenderingFixtures.pdf(count: 12)
        let data = try #require(document.dataRepresentation())
        var settings = settings
        settings.layout = .a3BookletA4
        let renderer = DocumentRenderer(paginate: { _ in
            Issue.record("PDF入力ではWeb組版を呼ばない")
            return PDFDocument()
        })
        let result = try await renderer.render(DocumentSource(data: data, format: .pdf), settings: settings)
        #expect(result.logicalDocument.pageCount == 12)
        #expect(result.summary.logicalPageCount == 12)
        #expect(result.summary.sheetCount == 3)
        #expect(result.summary.sideCount == 6)
        #expect(result.sheetDocument.pageCount == 6)
    }

    @Test("画像から1枚の論理ページと用紙ページを作る")
    func image() async throws {
        let result = try await DocumentRenderer().render(
            DocumentSource(data: RenderingFixtures.image(), format: .image), settings: settings)
        #expect(result.logicalDocument.pageCount == 1)
        #expect(result.sheetDocument.pageCount == 1)
    }

    @Test("両面とページ番号と裏面回転だけの変更では再組版しない")
    func reusesPagination() async throws {
        var calls = 0
        let renderer = DocumentRenderer(paginate: { _ in
            calls += 1
            return try RenderingFixtures.pdf(count: 2)
        })
        let source = DocumentSource(data: Data("# Test".utf8), format: .markdown)
        var settings = settings
        let first = try await renderer.render(source, settings: settings)
        first.logicalDocument.removePage(at: 0)
        settings.layout = .a4Duplex
        settings.options.showsPageNumbers = true
        settings.options.rotatesBackSides = true
        let second = try await renderer.render(source, settings: settings)
        #expect(second.logicalDocument.pageCount == 2)
        settings.layout = .a3BookletA4
        _ = try await renderer.render(source, settings: settings)
        #expect(calls == 1)
        #expect(renderer.logicalRenderCount == 1)
    }

    @Test("本文と論理寸法とテーマと余白を変更すると再組版する")
    func invalidatesPagination() async throws {
        var calls = 0
        let renderer = DocumentRenderer(paginate: { _ in
            calls += 1
            return try RenderingFixtures.pdf()
        })
        var source = DocumentSource(data: Data("One".utf8), format: .markdown)
        var settings = settings
        _ = try await renderer.render(source, settings: settings)
        source = DocumentSource(data: Data("Two".utf8), format: .markdown)
        _ = try await renderer.render(source, settings: settings)
        settings.layout = .a4BookletA5
        _ = try await renderer.render(source, settings: settings)
        settings.theme = PrintTheme(id: "test", name: "Test", css: "body { color: red; }")
        _ = try await renderer.render(source, settings: settings)
        settings.options.marginsInMillimeters = 10
        _ = try await renderer.render(source, settings: settings)
        #expect(calls == 5)
        renderer.clearCache()
        _ = try await renderer.render(source, settings: settings)
        #expect(calls == 6)
    }

    @Test("HTMLのプリセットとJavaScriptの変更を組版へ渡してキャッシュを無効化する")
    func htmlSettings() async throws {
        var requests: [PaginationRequest] = []
        let renderer = DocumentRenderer(paginate: { request in
            requests.append(request)
            return try RenderingFixtures.pdf()
        })
        let source = DocumentSource(data: Data("<p>Body</p>".utf8), format: .html)
        var settings = settings
        _ = try await renderer.render(source, settings: settings)
        settings.allowsJavaScriptInHTML = true
        _ = try await renderer.render(source, settings: settings)
        settings.preset.removeSelectors = ["nav"]
        _ = try await renderer.render(source, settings: settings)
        settings.preset.disablesJavaScript = true
        _ = try await renderer.render(source, settings: settings)
        #expect(requests.count == 4)
        #expect(requests.map(\.allowsJavaScript) == [false, true, true, false])
        #expect(requests[2].preparationScript?.contains("nav") == true)
        if case .html(let html, baseURL: nil) = requests[0].source {
            #expect(html == "<p>Body</p>")
        } else {
            Issue.record("URLなしのHTMLは文字列で渡す")
        }
    }

    @Test("HTMLファイルはディレクトリの読み取り権限と一緒に渡す")
    func htmlFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/surimono-input/index.html")
        let renderer = DocumentRenderer(paginate: { request in
            if case .file(let file, let directory) = request.source {
                #expect(file == url)
                #expect(directory == url.deletingLastPathComponent())
            } else {
                Issue.record("HTMLファイルはfile sourceにする")
            }
            return try RenderingFixtures.pdf()
        })
        _ = try await renderer.render(DocumentSource(data: Data(), fileURL: url, format: .html), settings: settings)
    }

    @Test("TSVはタブ区切りで変換し文書のディレクトリをbaseURLにする")
    func tsv() async throws {
        let url = URL(fileURLWithPath: "/tmp/surimono-input/data.TSV")
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, let baseURL) = request.source {
                #expect(html.contains("<th>A</th><th>B</th>"))
                #expect(baseURL == url.deletingLastPathComponent())
                #expect(html.contains("<base href=\"file:///tmp/surimono-input/\">"))
            } else {
                Issue.record("TSVはHTMLに変換する")
            }
            #expect(!request.allowsJavaScript)
            return try RenderingFixtures.pdf()
        })
        _ = try await renderer.render(
            DocumentSource(data: Data("A\tB\n1\t2".utf8), fileURL: url, format: .csv), settings: settings)
    }

    @Test("破損PDFと不正な文字コードとタイムアウトを識別する")
    func failures() async throws {
        let settings = settings
        await #expect(throws: DocumentRenderer.RenderingError.invalidPDF) {
            _ = try await DocumentRenderer().render(
                DocumentSource(data: Data([0, 1]), format: .pdf), settings: settings)
        }
        await #expect(throws: DocumentRenderer.RenderingError.textDecodingFailed) {
            _ = try await DocumentRenderer().render(
                DocumentSource(data: Data([0xFF, 0xFE, 0x61]), format: .plainText), settings: settings)
        }
        let renderer = DocumentRenderer(paginate: { _ in throw WebPaginator.PaginationError.timedOut })
        await #expect(throws: DocumentRenderer.RenderingError.pagination(.timedOut)) {
            _ = try await renderer.render(
                DocumentSource(data: Data("text".utf8), format: .plainText), settings: settings)
        }
    }

    @Test("暗号化PDFはパスワード要求を識別できるエラーにする")
    func encryptedPDF() async throws {
        let document = try RenderingFixtures.pdf()
        let data = try #require(
            document.dataRepresentation(options: [
                PDFDocumentWriteOption.ownerPasswordOption: "fixture-owner",
                PDFDocumentWriteOption.userPasswordOption: "fixture-reader",
            ]))
        let settings = settings
        await #expect(throws: DocumentRenderer.RenderingError.encryptedPDF) {
            _ = try await DocumentRenderer().render(DocumentSource(data: data, format: .pdf), settings: settings)
        }
    }

    @Test(
        "BOM付きの日本語を欠落なく変換して改行を正規化する",
        arguments: [
            (String.Encoding.utf8, [UInt8](arrayLiteral: 0xEF, 0xBB, 0xBF)),
            (.utf16LittleEndian, [0xFF, 0xFE]), (.utf16BigEndian, [0xFE, 0xFF]),
            (.utf32LittleEndian, [0xFF, 0xFE, 0, 0]), (.utf32BigEndian, [0, 0, 0xFE, 0xFF]),
        ])
    func encodedText(encoding: String.Encoding, prefix: [UInt8]) async throws {
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, _) = request.source {
                #expect(html.contains("日本語😀\n次"))
                #expect(!html.contains("\u{FEFF}"))
            } else {
                Issue.record("テキストはHTMLに変換する")
            }
            return try RenderingFixtures.pdf()
        })
        let data = Data(prefix) + (try #require("日本語😀\r\n次".data(using: encoding)))
        _ = try await renderer.render(DocumentSource(data: data, format: .plainText), settings: settings)
    }

    @Test("Orgの見出しをHTML化し文書のJavaScriptを常に無効にする")
    func org() async throws {
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, _) = request.source {
                #expect(html.contains("<h1>見出し</h1>"))
            } else {
                Issue.record("OrgはHTMLに変換する")
            }
            #expect(!request.allowsJavaScript)
            return try RenderingFixtures.pdf()
        })
        var settings = settings
        settings.allowsJavaScriptInHTML = true
        _ = try await renderer.render(DocumentSource(data: Data("* 見出し".utf8), format: .org), settings: settings)
    }

    @Test("キャンセルされた組版はCancellationErrorを返し結果をキャッシュしない")
    func cancellation() async throws {
        var started = false
        var calls = 0
        let renderer = DocumentRenderer(paginate: { _ in
            calls += 1
            started = true
            if calls == 1 { try await Task.sleep(for: .seconds(30)) }
            return try RenderingFixtures.pdf()
        })
        let source = DocumentSource(data: Data("text".utf8), format: .plainText)
        let settings = settings
        let task = Task { try await renderer.render(source, settings: settings) }
        while !started { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        _ = try await renderer.render(source, settings: settings)
        #expect(calls == 2)
        #expect(renderer.logicalRenderCount == 1)
    }
}

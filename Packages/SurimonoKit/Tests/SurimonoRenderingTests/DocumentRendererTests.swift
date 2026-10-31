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

    @Test("縦2横4のPDFは自動の通常片面だけページごとの用紙になる")
    func mixedSheets() async throws {
        let pdf = try RenderingFixtures.pdf(count: 2, size: CGSize(width: 200, height: 400))
        let wide = try RenderingFixtures.pdf(count: 4, size: CGSize(width: 400, height: 200))
        for index in 0..<4 { pdf.insert(try #require(wide.page(at: index)), at: pdf.pageCount) }
        let source = DocumentSource(data: try #require(pdf.dataRepresentation()), format: .pdf)
        let renderer = DocumentRenderer()
        var settings = settings
        let mixed = try await renderer.render(source, settings: settings)
        #expect(mixed.sheetOrientations == [.portrait, .portrait, .landscape, .landscape, .landscape, .landscape])
        #expect(mixed.hasMixedSheetOrientations)
        for index in 0..<6 {
            let size = try #require(mixed.sheetDocument.page(at: index)).bounds(for: .mediaBox).size
            #expect(abs(size.width - (index < 2 ? 595.28 : 841.89)) < 0.1)
            #expect(abs(size.height - (index < 2 ? 841.89 : 595.28)) < 0.1)
        }
        let exported = try #require(PDFDocument(data: mixed.sheetDocument.dataRepresentation()!))
        #expect(exported.pageCount == 6)
        for index in 0..<6 {
            let reread = try #require(exported.page(at: index)).bounds(for: .mediaBox).size
            let original = try #require(mixed.sheetDocument.page(at: index)).bounds(for: .mediaBox).size
            #expect(reread == original)
        }
        settings.layout = .a4Duplex
        let duplex = try await renderer.render(source, settings: settings)
        #expect(duplex.sheetOrientations == Array(repeating: .landscape, count: 6))
        settings.layout = .a3TwoUp
        let twoUp = try await renderer.render(source, settings: settings)
        #expect(twoUp.resolvedOrientation == .landscape)
        #expect(twoUp.sheetOrientations == [.portrait, .portrait, .portrait])
        settings.layout = .a4Single
        settings.paperOrientation = .portrait
        let portrait = try await renderer.render(source, settings: settings)
        #expect(portrait.sheetOrientations == Array(repeating: .portrait, count: 6))
        #expect(renderer.logicalRenderCount == 1)
    }

    @Test("正方形は縦、CropBoxとRotateを反映した横ページは横の用紙になる")
    func croppedMixedSheets() async throws {
        let pdf = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 400, height: 400))
        pdf.page(at: 1)?.setBounds(CGRect(x: 20, y: 30, width: 300, height: 100), for: .cropBox)
        pdf.page(at: 2)?.setBounds(CGRect(x: 20, y: 30, width: 100, height: 300), for: .cropBox)
        pdf.page(at: 2)?.rotation = 90
        let result = try await DocumentRenderer().render(
            DocumentSource(data: try #require(pdf.dataRepresentation()), format: .pdf), settings: settings)
        #expect(result.sheetOrientations == [.portrait, .landscape, .landscape])
    }

    @Test(
        "固定レイアウトと明示した横向きでは混在させない",
        arguments: [PrintLayout.a3BookletA4, .a4Handout3, .a4Single])
    func mixedSourceFixedSheets(layout: PrintLayout) async throws {
        let pdf = try RenderingFixtures.pdf(size: CGSize(width: 200, height: 400))
        let wide = try RenderingFixtures.pdf(size: CGSize(width: 400, height: 200))
        pdf.insert(try #require(wide.page(at: 0)), at: 1)
        var settings = settings
        settings.layout = layout
        settings.paperOrientation = .landscape
        let result = try await DocumentRenderer().render(
            DocumentSource(data: try #require(pdf.dataRepresentation()), format: .pdf), settings: settings)
        #expect(!result.hasMixedSheetOrientations)
        #expect(result.sheetOrientations.allSatisfy { $0 == (layout.kind == .handout3 ? .portrait : .landscape) })
    }

    @Test("画像の束の自動片面はEXIF後の各画像に合わせ、両面への変更でキャッシュを更新する")
    func mixedImageSheets() async throws {
        let source = DocumentSource.images([
            .init(data: try RenderingFixtures.image(orientation: 6), fileURL: URL(fileURLWithPath: "/fixture/p.tiff")),
            .init(data: try RenderingFixtures.image(), fileURL: URL(fileURLWithPath: "/fixture/l.tiff")),
            .init(data: try RenderingFixtures.image(), fileURL: URL(fileURLWithPath: "/fixture/l2.tiff")),
        ])
        let renderer = DocumentRenderer()
        var settings = settings
        let mixed = try await renderer.render(source, settings: settings)
        #expect(mixed.sheetOrientations == [.portrait, .landscape, .landscape])
        settings.layout = .a4Duplex
        let duplex = try await renderer.render(source, settings: settings)
        #expect(duplex.sheetOrientations == [.landscape, .landscape, .landscape, .landscape])
        settings.layout = .a4Single
        let again = try await renderer.render(source, settings: settings)
        #expect(again.sheetOrientations == mixed.sheetOrientations)
    }

    @Test("3枚＋メモの用紙は内容の向きと別に常に縦になる", arguments: PaperOrientation.allCases)
    func handoutSheetOrientation(orientation: PaperOrientation) async throws {
        let pdf = try RenderingFixtures.pdf(size: CGSize(width: 800, height: 450))
        let source = DocumentSource(data: try #require(pdf.dataRepresentation()), format: .pdf)
        var settings = settings
        settings.layout = .a4Handout3
        settings.paperOrientation = orientation
        let result = try await DocumentRenderer().render(source, settings: settings)
        #expect(result.sheetOrientation == .portrait)
        #expect(settings.paperOrientation == orientation)
        settings.layout = .a4Single
        let single = try await DocumentRenderer().render(source, settings: settings)
        #expect(single.sheetOrientation == (orientation == .portrait ? .portrait : .landscape))
    }

    @Test("3枚＋メモのWeb組版は枠の寸法を使い外周余白を二重に引かない")
    func handoutPagination() async throws {
        var sizes: [CGSize] = []
        let renderer = DocumentRenderer(paginate: { request in
            sizes.append(request.pageSize)
            #expect(request.margins == .uniform(millimeters: 0))
            return try RenderingFixtures.pdf(count: 7, size: request.pageSize)
        })
        var settings = settings
        settings.layout = .a4Handout3
        let source = DocumentSource(data: Data("# Handout".utf8), format: .markdown)
        let automatic = try await renderer.render(source, settings: settings)
        #expect(automatic.sheetDocument.pageCount == 3)
        settings.paperOrientation = .portrait
        _ = try await renderer.render(source, settings: settings)
        settings.paperOrientation = .landscape
        _ = try await renderer.render(source, settings: settings)
        #expect(sizes.count == 1)
        settings.options.marginsInMillimeters = 10
        _ = try await renderer.render(source, settings: settings)
        #expect(sizes.count == 2)
        #expect(abs(sizes[0].width - 312.0378) < 0.001)
        #expect(abs(sizes[0].height - 237.1654) < 0.001)
        #expect(abs(sizes[1].width - 330.1795) < 0.001)
    }

    @Test("Markdownの向き変更は寸法を変えて再組版し印刷だけの変更は使い回す")
    func paperOrientationCache() async throws {
        var sizes: [CGSize] = []
        let renderer = DocumentRenderer(paginate: { request in
            sizes.append(request.pageSize)
            return try RenderingFixtures.pdf(size: request.pageSize)
        })
        let source = DocumentSource(data: Data("# Heading".utf8), format: .markdown)
        var settings = settings
        _ = try await renderer.render(source, settings: settings)
        settings.paperOrientation = .landscape
        let result = try await renderer.render(source, settings: settings)
        settings.options.showsPageNumbers = true
        _ = try await renderer.render(source, settings: settings)
        #expect(sizes.count == 2)
        #expect(abs(sizes[1].width - 841.89) < 0.1)
        #expect(abs(sizes[1].height - 595.28) < 0.1)
        #expect(result.resolvedOrientation == .landscape)
        let size = try #require(result.logicalDocument.page(at: 0)).bounds(for: .mediaBox).size
        #expect(abs(size.width - sizes[1].width) < 0.01)
        #expect(abs(size.height - sizes[1].height) < 0.01)
    }

    @Test("PDFは向き変更で読み直さず再面付けしRotateを自動判定に反映する")
    func pdfOrientationCache() async throws {
        let document = try RenderingFixtures.pdf(size: CGSize(width: 200, height: 400))
        document.page(at: 0)?.rotation = 90
        let source = DocumentSource(data: try #require(document.dataRepresentation()), format: .pdf)
        let renderer = DocumentRenderer()
        var settings = settings
        let automatic = try await renderer.render(source, settings: settings)
        #expect(automatic.resolvedOrientation == .landscape)
        #expect(abs(try #require(automatic.sheetDocument.page(at: 0)).bounds(for: .mediaBox).width - 841.89) < 0.1)
        settings.paperOrientation = .portrait
        let portrait = try await renderer.render(source, settings: settings)
        #expect(portrait.resolvedOrientation == .portrait)
        #expect(abs(try #require(portrait.sheetDocument.page(at: 0)).bounds(for: .mediaBox).width - 595.28) < 0.1)
        #expect(renderer.logicalRenderCount == 1)
    }

    @Test("画像と画像の束はEXIF反映後の多数決で用紙を決める")
    func imageOrientation() async throws {
        let landscape = try RenderingFixtures.image()
        let portrait = try RenderingFixtures.image(orientation: 6)
        let source = DocumentSource.images([
            .init(data: portrait, fileURL: URL(fileURLWithPath: "/fixture/1.tiff")),
            .init(data: landscape, fileURL: URL(fileURLWithPath: "/fixture/2.tiff")),
            .init(data: landscape, fileURL: URL(fileURLWithPath: "/fixture/3.tiff")),
        ])
        let renderer = DocumentRenderer()
        var settings = settings
        settings.layout = .a3TwoUp
        let bundle = try await renderer.render(source, settings: settings)
        #expect(bundle.resolvedOrientation == .landscape)
        #expect(bundle.layout.sheetSize.width < bundle.layout.sheetSize.height)
        let page = try #require(bundle.logicalDocument.page(at: 0))
        #expect(page.bounds(for: .mediaBox).width > page.bounds(for: .mediaBox).height)
        let single = try await renderer.render(DocumentSource(data: portrait, format: .image), settings: settings)
        #expect(single.resolvedOrientation == .portrait)
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

    @Test("画像の表示用のページは画像の縦横比で、印刷のページは用紙のまま", arguments: [false, true])
    func imageViewPages(isBundle: Bool) async throws {
        let data = try RenderingFixtures.image()
        let source =
            isBundle
            ? DocumentSource.images([
                .init(data: data, fileURL: URL(fileURLWithPath: "/fixture/1.tiff")),
                .init(data: data, fileURL: URL(fileURLWithPath: "/fixture/2.tiff")),
            ])
            : DocumentSource(data: data, format: .image)
        var settings = settings
        settings.paperOrientation = .portrait
        settings.options.marginsInMillimeters = 0
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        #expect(prepared.viewDocument.pageCount == prepared.logicalDocument.pageCount)
        for index in 0..<prepared.viewDocument.pageCount {
            let shown = try #require(prepared.viewDocument.page(at: index)).bounds(for: .cropBox).size
            // The 2:1 image across a portrait A4 sheet, without the paper above and below it.
            #expect(abs(shown.width - 595.28) < 0.1 && abs(shown.height - 297.64) < 0.1)
            let logical = try #require(prepared.logicalDocument.page(at: index)).bounds(for: .cropBox).size
            #expect(abs(logical.width - 595.28) < 0.1 && abs(logical.height - 841.89) < 0.1)
        }
        let sheet = try #require(
            try await DocumentRenderer().render(source, settings: settings).sheetDocument.page(at: 0))
        #expect(abs(sheet.bounds(for: .mediaBox).height - 841.89) < 0.1)
    }

    @Test("画像以外の表示用のページは論理ページそのもの", arguments: [DocumentFormat.markdown, .pdf])
    func viewPagesOfOtherFormats(format: DocumentFormat) async throws {
        let renderer = DocumentRenderer(paginate: { _ in try RenderingFixtures.pdf() })
        let data =
            format == .pdf ? try #require(try RenderingFixtures.pdf(count: 2).dataRepresentation()) : Data("Body".utf8)
        let prepared = try await renderer.prepare(DocumentSource(data: data, format: format), settings: settings)
        #expect(prepared.viewDocument === prepared.logicalDocument)
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
        settings.layout = .a4Duplex
        settings.options.showsPageNumbers = true
        settings.options.rotatesBackSides = true
        let second = try await renderer.render(source, settings: settings)
        #expect(second.logicalDocument === first.logicalDocument)
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

    @Test("用紙ちょうどの大きさの紙片を並べた HTML は、紙片の数だけの用紙に 1 枚ずつ刷られる", .timeLimit(.minutes(1)))
    func fixedSheetHTMLPrintsOneSheetPerPaper() async throws {
        let sheets = (1...3).map { "<article class=\"sheet\"><p>LINE-00\($0)</p></article>" }.joined()
        let html = """
            <!doctype html><meta charset="utf-8"><style>@page { size: A4 portrait; margin: 0 }
            * { box-sizing: border-box } body { margin: 0 }
            .sheet { width: 210mm; height: 297mm; padding: 12mm 16mm; break-after: page; break-inside: avoid }
            .sheet:last-child { break-after: auto }</style><body>\(sheets)</body>
            """
        let result = try await DocumentRenderer().render(
            DocumentSource(data: Data(html.utf8), format: .html), settings: settings)
        #expect(result.logicalDocument.pageCount == 3)
        #expect(result.sheetDocument.pageCount == 3)
        for index in 0..<result.sheetDocument.pageCount {
            let page = try #require(result.sheetDocument.page(at: index))
            #expect(page.string?.contains("LINE-00\(index + 1)") == true)
        }
    }

    @Test("用紙の下端を越えて文字が組まれた HTML のページは、刷るときに用紙へ縮めて収める", .timeLimit(.minutes(1)))
    func fitsTallerLogicalPagesOntoThePaper() async throws {
        // A sheet a little taller than A4 whose footer's descenders reach below the paper.
        let html = """
            <!doctype html><meta charset="utf-8"><style>@page { size: A4 portrait; margin: 0 }
            * { box-sizing: border-box } body { margin: 0 }
            .sheet { width: 210mm; height: calc(297mm + 1.5px); display: flex; flex-direction: column }
            footer { margin-top: auto; font: 14px/4px sans-serif }
            </style><body><article class="sheet"><p>SHEET-1</p><footer>FOOT-MARKER gjpqy</footer></article></body>
            """
        let result = try await DocumentRenderer().render(
            DocumentSource(data: Data(html.utf8), format: .html), settings: settings)
        let logical = try #require(result.logicalDocument.page(at: 0))
        #expect(logical.bounds(for: .cropBox).height > 841.89 + 1)
        #expect(result.sheetDocument.pageCount == 1)
        let sheet = try #require(result.sheetDocument.page(at: 0))
        let size = sheet.bounds(for: .mediaBox).size
        #expect(abs(size.width - 595.28) < 0.1 && abs(size.height - 841.89) < 0.1)
        #expect(sheet.string?.contains("FOOT-MARKER") == true)
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

    @Test("LaTeX は節に番号を振った HTML にし、印刷テーマを当て、文書の JavaScript を常に無効にする")
    func latex() async throws {
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, _) = request.source {
                #expect(html.contains("<body class=\"surimono format-latex\">"))
                #expect(html.contains("<h2 id=\"sec-1\"><span class=\"secnum\">1</span>見出し</h2>"))
            } else {
                Issue.record("LaTeX は HTML に変換する")
            }
            #expect(!request.allowsJavaScript)
            return try RenderingFixtures.pdf()
        })
        var settings = settings
        settings.allowsJavaScriptInHTML = true
        let source = DocumentSource(
            data: Data("\\documentclass{article}\\begin{document}\\section{見出し}本文\\end{document}".utf8),
            format: .latex)
        _ = try await renderer.render(source, settings: settings)
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

    @Test("今の状態の写しは文書の場所だけを読める形で JavaScript なしで組み、別の写しは組み直す")
    func liveSnapshot() async throws {
        var requests: [PaginationRequest] = []
        let renderer = DocumentRenderer(paginate: { request in
            requests.append(request)
            return try RenderingFixtures.pdf()
        })
        var settings = settings
        settings.allowsJavaScriptInHTML = true
        let file = URL(fileURLWithPath: "/Documents/page.html")
        let first = DocumentSource.liveSnapshot("<p>First</p>", of: file)
        _ = try await renderer.render(first, settings: settings)
        _ = try await renderer.render(first, settings: settings)
        _ = try await renderer.render(.liveSnapshot("<p>Second</p>", of: file), settings: settings)
        _ = try await renderer.render(
            DocumentSource(data: Data("<p>First</p>".utf8), fileURL: file, format: .html), settings: settings)
        #expect(requests.count == 3)
        #expect(requests.map(\.allowsJavaScript) == [false, false, true])
        if case .snapshot(let html, let directory) = requests[0].source {
            #expect(html == "<p>First</p>")
            #expect(directory == URL(fileURLWithPath: "/Documents/"))
        } else {
            Issue.record("写しは文書の場所だけを読める写しとして渡す")
        }
        if case .file(let url, _) = requests[2].source {
            #expect(url == file)
        } else {
            Issue.record("写しでなければファイルから読む")
        }
    }

    @Test("今の状態の写しも用紙の向きを決めてから組み、自動は縦、横を選べば横で組む")
    func liveSnapshotOrientation() async throws {
        var requests: [PaginationRequest] = []
        let renderer = DocumentRenderer(paginate: { request in
            requests.append(request)
            return try RenderingFixtures.pdf()
        })
        let source = DocumentSource.liveSnapshot("<p>Wide</p>", of: URL(fileURLWithPath: "/Documents/page.html"))
        var settings = settings
        let automatic = try await renderer.render(source, settings: settings)
        settings.paperOrientation = .landscape
        let landscape = try await renderer.render(source, settings: settings)
        #expect(automatic.resolvedOrientation == .portrait)
        #expect(landscape.resolvedOrientation == .landscape)
        #expect(requests.count == 2)
        #expect(requests[0].pageSize.width < requests[0].pageSize.height)
        #expect(requests[1].pageSize.width > requests[1].pageSize.height)
    }

    @Test("HTML の @page が横を求めると、自動は横で組み直し、次からは最初から横で組む")
    func pageRuleTurnsHTML() async throws {
        var requests: [PaginationRequest] = []
        let renderer = DocumentRenderer(paginateWithResult: { request in
            requests.append(request)
            return WebPaginator.Result(
                document: try RenderingFixtures.pdf(size: request.pageSize),
                pageRules: [PageRule(size: "A4 landscape")])
        })
        let source = DocumentSource(data: Data("<p>Wide</p>".utf8), format: .html)
        var settings = settings
        let first = try await renderer.render(source, settings: settings)
        #expect(first.resolvedOrientation == .landscape)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.readsPageRules })
        #expect(requests[0].pageSize.width < requests[0].pageSize.height)
        #expect(requests[1].pageSize.width > requests[1].pageSize.height)

        settings.options.marginsInMillimeters = 20
        let again = try await renderer.render(source, settings: settings)
        #expect(again.resolvedOrientation == .landscape)
        #expect(requests.count == 3)
        #expect(requests[2].pageSize.width > requests[2].pageSize.height)
    }

    @Test("スライドは自動なら @page にかかわらず横で 1 回だけ組み、刷り方を変えると組み直す")
    func slidesTurnLandscape() async throws {
        var requests: [PaginationRequest] = []
        let renderer = DocumentRenderer(paginateWithResult: { request in
            requests.append(request)
            return WebPaginator.Result(
                document: try RenderingFixtures.pdf(size: request.pageSize), pageRules: [PageRule(size: "A4 portrait")])
        })
        let source = DocumentSource(data: Data("<p>Deck</p>".utf8), format: .html)
        var settings = settings
        settings.slides = SlidePrintRequest(slideSize: CGSize(width: 1280, height: 720), count: 6)
        let all = try await renderer.render(source, settings: settings)
        #expect(all.resolvedOrientation == .landscape)
        #expect(requests.count == 1)
        #expect(requests[0].pageSize.width > requests[0].pageSize.height)
        #expect(requests[0].preparationScript?.contains("const only = -1;") == true)

        settings.slides?.onlyIndex = 2
        _ = try await renderer.render(source, settings: settings)
        #expect(requests.count == 2)
        #expect(requests[1].preparationScript?.contains("const only = 2;") == true)

        settings.paperOrientation = .portrait
        let portrait = try await renderer.render(source, settings: settings)
        #expect(portrait.resolvedOrientation == .portrait)
    }

    @Test("HTML の @page の向きは自動のときだけ使い、縦を選べば縦、冊子はいつも縦の用紙で組む")
    func pageRuleOnlyForAuto() async throws {
        var requests: [PaginationRequest] = []
        let renderer = DocumentRenderer(paginateWithResult: { request in
            requests.append(request)
            return WebPaginator.Result(
                document: try RenderingFixtures.pdf(size: request.pageSize), pageRules: [PageRule(size: "landscape")])
        })
        let source = DocumentSource(data: Data("<p>Wide</p>".utf8), format: .html)
        var settings = settings
        settings.paperOrientation = .portrait
        let portrait = try await renderer.render(source, settings: settings)
        #expect(portrait.resolvedOrientation == .portrait)
        settings.paperOrientation = .auto
        settings.layout = .a3BookletA4
        let booklet = try await renderer.render(source, settings: settings)
        #expect(booklet.resolvedOrientation == .portrait)
        #expect(requests.allSatisfy { $0.pageSize.width < $0.pageSize.height })
    }

    @Test("HTML の @page が向きを求めなければ、自動は縦のまま 1 回で組む")
    func noPageRuleKeepsHTMLUpright() async throws {
        var count = 0
        let renderer = DocumentRenderer(paginateWithResult: { request in
            count += 1
            return WebPaginator.Result(
                document: try RenderingFixtures.pdf(size: request.pageSize),
                pageRules: [PageRule(selector: ":first", size: "landscape"), PageRule(size: "auto")])
        })
        let result = try await renderer.render(
            DocumentSource(data: Data("<p>Tall</p>".utf8), format: .html), settings: settings)
        #expect(result.resolvedOrientation == .portrait)
        #expect(count == 1)
    }

    @Test("折りたたみを開いて刷るときは、写しを開く処理を先に入れて組み直す")
    func opensDetailsBeforePreparation() async throws {
        var requests: [PaginationRequest] = []
        let renderer = DocumentRenderer(paginate: { request in
            requests.append(request)
            return try RenderingFixtures.pdf()
        })
        let source = DocumentSource.liveSnapshot(
            "<details><summary>Q</summary>A</details>", of: URL(fileURLWithPath: "/Documents/page.html"))
        var settings = settings
        _ = try await renderer.render(source, settings: settings)
        settings.opensDetails = true
        _ = try await renderer.render(source, settings: settings)
        #expect(requests.count == 2)
        #expect(requests[0].preparationScript?.contains(HTMLSnapshotScript.openDetailsJavaScript) == false)
        #expect(requests[1].preparationScript?.hasPrefix(HTMLSnapshotScript.openDetailsJavaScript) == true)
    }
}

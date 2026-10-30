import AppKit
import Foundation
import PDFKit
import Testing

@testable import SurimonoRendering

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WebPaginatorTests {
    private let a4 = CGSize(width: 595.28, height: 841.89)
    private let simpleHTML = "<!doctype html><meta charset=\"utf-8\"><body><p>BODY-MARKER</p></body>"

    init() {
        // WebKit needs an application object to host its off-screen window.
        _ = NSApplication.shared
    }

    private func text(of document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    @Test("長い HTML を指定した寸法の複数ページの PDF に組版できる")
    func paginatesLongHTML() async throws {
        var body = "<h1>見出し</h1>"
        for index in 1...30 { body += "<h2>節 \(index)</h2><p>" + String(repeating: "本文。", count: 120) + "</p>" }
        let html = "<!doctype html><meta charset=\"utf-8\"><body>\(body)<p>END-MARKER</p></body>"
        let document = try await WebPaginator().paginate(
            .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15), allowsJavaScript: false)
        #expect(document.pageCount >= 2)
        let size = try #require(document.page(at: 0)?.bounds(for: .mediaBox).size)
        #expect(abs(size.width - a4.width) < 1)
        #expect(abs(size.height - a4.height) < 1)
        #expect(text(of: document).contains("END-MARKER"))
    }

    @Test("文書の JavaScript を止めても準備スクリプトは動き、文書のスクリプトは動かない")
    func runsPreparationScriptWithPageScriptsDisabled() async throws {
        let html = """
            <!doctype html><meta charset="utf-8"><body><nav>NOISE-MARKER</nav><p>BODY-MARKER</p>
            <script>document.body.insertAdjacentHTML('beforeend', '<p>PAGE-SCRIPT-MARKER</p>')</script></body>
            """
        let document = try await WebPaginator().paginate(
            .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: "document.querySelectorAll('nav').forEach(node => node.remove());")
        let content = text(of: document)
        #expect(content.contains("BODY-MARKER"))
        #expect(!content.contains("NOISE-MARKER"))
        #expect(!content.contains("PAGE-SCRIPT-MARKER"))
    }

    @Test("アプリがダークでも、ダークに対応した HTML はライトの色で組版される")
    func typesetsInLightAppearanceEvenWhenAppIsDark() async throws {
        let html = """
            <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">
            <style>html, body { margin: 0; height: 100%; background: rgb(255, 255, 255); }
            @media (prefers-color-scheme: dark) { html, body { background: rgb(0, 0, 0); } }</style>
            <body><p>BODY-MARKER</p></body>
            """
        let application = NSApplication.shared
        let previous = application.appearance
        application.appearance = NSAppearance(named: .darkAqua)
        defer { application.appearance = previous }
        let document = try await WebPaginator().paginate(
            .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 0), allowsJavaScript: false)
        let page = try #require(document.page(at: 0))
        let pixel = try RenderingFixtures.pixel(page, x: 300, y: 600)
        #expect(pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240)
    }

    @Test("JavaScript を許可すると文書のスクリプトの結果が印刷される")
    func runsPageScriptsWhenAllowed() async throws {
        let html = """
            <!doctype html><meta charset="utf-8"><body><p>BODY-MARKER</p>
            <script>document.body.insertAdjacentHTML('beforeend', '<p>PAGE-SCRIPT-MARKER</p>')</script></body>
            """
        let document = try await WebPaginator().paginate(
            .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15), allowsJavaScript: true)
        #expect(text(of: document).contains("PAGE-SCRIPT-MARKER"))
    }

    /// Creates `<directory>/<relativePath>` as a small PNG and returns the directory.
    private func makeImageDirectory(relativePath: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "surimono-test-\(UUID().uuidString)")
        let imageURL = directory.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: imageURL)
        return directory
    }

    /// Appends IMAGE-LOADED or IMAGE-MISSING to the page depending on whether `#pic` decoded.
    private let imageReport = """
        const image = document.getElementById('pic');
        document.body.insertAdjacentHTML('beforeend',
          image && image.naturalWidth > 0 ? '<p>IMAGE-LOADED</p>' : '<p>IMAGE-MISSING</p>');
        """

    @Test("生成した HTML から文書の隣にある相対パスの画像を読み込める")
    func loadsRelativeImagesForGeneratedHTML() async throws {
        let directory = try makeImageDirectory(relativePath: "img/dot.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        // No <base> element: the baseURL argument alone must make the relative path resolve.
        let html = """
            <!doctype html><meta charset="utf-8">
            <body><img id="pic" src="img/dot.png"><p>BODY-MARKER</p></body>
            """
        let document = try await WebPaginator().paginate(
            .html(html, baseURL: directory), pageSize: a4, margins: .uniform(millimeters: 15),
            allowsJavaScript: false, preparationScript: imageReport)
        #expect(text(of: document).contains("IMAGE-LOADED"))
    }

    @Test("コメント内の base や href のない base は無視して baseURL で相対画像を読める")
    func ignoresCommentedAndTargetOnlyBase() async throws {
        let directory = try makeImageDirectory(relativePath: "img/dot.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = """
            <!doctype html><head><!-- <base href="old/"> --><base target="_blank"><meta charset="utf-8"></head>
            <body><img id="pic" src="img/dot.png"></body>
            """
        let document = try await WebPaginator().paginate(
            .html(html, baseURL: directory), pageSize: a4, margins: .uniform(millimeters: 15),
            allowsJavaScript: false, preparationScript: imageReport)
        #expect(text(of: document).contains("IMAGE-LOADED"))
    }

    @Test("文書の相対的な base href は baseURL を基準に解決される")
    func resolvesRelativeBaseAgainstBaseURL() async throws {
        let directory = try makeImageDirectory(relativePath: "sub/img/dot.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = """
            <!doctype html><head><base href="sub/"><meta charset="utf-8"></head>
            <body><img id="pic" src="img/dot.png"></body>
            """
        let document = try await WebPaginator().paginate(
            .html(html, baseURL: directory), pageSize: a4, margins: .uniform(millimeters: 15),
            allowsJavaScript: false, preparationScript: imageReport)
        #expect(text(of: document).contains("IMAGE-LOADED"))
    }

    @Test("JavaScript を許可した HTML 文字列にはローカルファイルの読み取りを許可しない")
    func grantsNoFileAccessWhenJavaScriptIsAllowed() async throws {
        let directory = try makeImageDirectory(relativePath: "img/dot.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = """
            <!doctype html><meta charset="utf-8"><body><img id="pic" src="img/dot.png"></body>
            """
        let document = try await WebPaginator().paginate(
            .html(html, baseURL: directory), pageSize: a4, margins: .uniform(millimeters: 15),
            allowsJavaScript: true, preparationScript: imageReport)
        #expect(text(of: document).contains("IMAGE-MISSING"))
    }

    @Test("base 要素は doctype の直後に入り、既存の相対 base href は解決済みの URL になる")
    func injectsResolvedBaseAfterDoctype() {
        let base = URL(fileURLWithPath: "/docs/", isDirectory: true)
        #expect(
            WebPaginator.injectingBase(base, into: "<!doctype html><p>x</p>")
                == "<!doctype html><base href=\"file:///docs/\"><p>x</p>")
        #expect(
            WebPaginator.injectingBase(base, into: "<!doctype html><!-- <base href=\"old/\"> --><p>x</p>")
                == "<!doctype html><base href=\"file:///docs/\"><!-- <base href=\"old/\"> --><p>x</p>")
        #expect(
            WebPaginator.injectingBase(base, into: "<!doctype html><base target=\"_blank\">")
                == "<!doctype html><base href=\"file:///docs/\"><base target=\"_blank\">")
        #expect(
            WebPaginator.injectingBase(base, into: "<!doctype html><base href='sub/'>")
                == "<!doctype html><base href=\"file:///docs/sub/\"><base href='sub/'>")
        #expect(WebPaginator.injectingBase(base, into: "<p>x</p>") == "<base href=\"file:///docs/\"><p>x</p>")
    }

    @Test("doctype の前にコメントがあっても base 要素は doctype の直後に入る")
    func injectsBaseAfterDoctypePrecededByComments() {
        let base = URL(fileURLWithPath: "/docs/", isDirectory: true)
        #expect(
            WebPaginator.injectingBase(base, into: "<!-- exported -->\n<!doctype html><p>x</p>")
                == "<!-- exported -->\n<!doctype html><base href=\"file:///docs/\"><p>x</p>")
        #expect(
            WebPaginator.injectingBase(base, into: "<!-- a --> <!-- b --><p>x</p>")
                == "<!-- a --> <!-- b --><base href=\"file:///docs/\"><p>x</p>")
    }

    @Test("既存の base href の文字参照は一度だけ復元してから使う")
    func decodesCharacterReferencesInExistingBase() {
        let base = URL(fileURLWithPath: "/docs/", isDirectory: true)
        #expect(
            WebPaginator.injectingBase(base, into: "<!doctype html><base href=\"file:///docs/A&amp;B/\">")
                == "<!doctype html><base href=\"file:///docs/A&amp;B/\"><base href=\"file:///docs/A&amp;B/\">")
        #expect(WebPaginator.decodingCharacterReferences("A&#38;B&#x26;C&unknown;") == "A&B&C&unknown;")
    }

    @Test("& を含むディレクトリでも、エスケープ済みの base href から相対画像を読める")
    func loadsImagesFromDirectoryWithAmpersand() async throws {
        let parent = try makeImageDirectory(relativePath: "A&B/img/dot.png")
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appending(path: "A&B", directoryHint: .isDirectory)
        let escapedBase = directory.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        let html = """
            <!doctype html><head><meta charset="utf-8"><base href="\(escapedBase)"></head>
            <body><img id="pic" src="img/dot.png"></body>
            """
        let document = try await WebPaginator().paginate(
            .html(html, baseURL: directory), pageSize: a4, margins: .uniform(millimeters: 15),
            allowsJavaScript: false, preparationScript: imageReport)
        #expect(text(of: document).contains("IMAGE-LOADED"))
    }

    @Test("doctype の前にコメントがある文書も標準モードのまま組版される")
    func keepsStandardsModeWithLeadingComment() async throws {
        let directory = try makeImageDirectory(relativePath: "img/dot.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = """
            <!-- exported document -->
            <!doctype html><html><head><meta charset="utf-8"></head><body><img id="pic" src="img/dot.png"></body></html>
            """
        let report =
            imageReport + "document.body.insertAdjacentHTML('beforeend', '<p>MODE-' + document.compatMode + '</p>');"
        let document = try await WebPaginator().paginate(
            .html(html, baseURL: directory), pageSize: a4, margins: .uniform(millimeters: 15),
            allowsJavaScript: false, preparationScript: report)
        let content = text(of: document)
        #expect(content.contains("MODE-CSS1Compat"))
        #expect(content.contains("IMAGE-LOADED"))
    }

    @Test("印刷の完了とキャンセルが重なったときは CancellationError になる")
    func reportsCancellationEvenIfPrintingCompletes() async throws {
        let paginator = WebPaginator()
        var task: Task<Int, any Error>?
        // Cancel right after the print callback has stored its result, before the wait loop re-checks.
        paginator.didFinishPrinting = { task?.cancel() }
        task = Task { @MainActor in
            try await paginator.paginate(
                .html(simpleHTML, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15),
                allowsJavaScript: false
            ).pageCount
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task?.value
        }
        #expect(paginator.printStartCount == 1)
        #expect(paginator.openSessionCount == 0)
    }

    @Test("リソースの待機中にキャンセルされたら印刷を始めない")
    func doesNotPrintAfterCancellationWhileWaitingForResources() async throws {
        let paginator = WebPaginator()
        var task: Task<Int, any Error>?
        paginator.didStartWaitingForResources = { task?.cancel() }
        task = Task { @MainActor in
            try await paginator.paginate(
                .html(simpleHTML, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15),
                allowsJavaScript: false
            ).pageCount
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task?.value
        }
        #expect(paginator.printStartCount == 0)
        #expect(paginator.openSessionCount == 0)
    }

    @Test("キャンセルされた組版は CancellationError で終わる")
    func endsWithCancellationErrorWhenCancelled() async throws {
        let html = "<!doctype html><meta charset=\"utf-8\"><body><p>BODY-MARKER</p></body>"
        // PDFDocument is not Sendable, so return only the page count across the task boundary.
        let task = Task { @MainActor in
            try await WebPaginator().paginate(
                .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15), allowsJavaScript: false
            ).pageCount
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("終わらない準備スクリプトは期限で打ち切られ、すぐに片付けられる")
    func timesOutHangingPreparationScript() async throws {
        let paginator = WebPaginator()
        await #expect(throws: WebPaginator.PaginationError.timedOut) {
            _ = try await paginator.paginate(
                .html(simpleHTML, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15),
                allowsJavaScript: false, preparationScript: "await new Promise(() => {});", timeout: .seconds(1))
        }
        #expect(paginator.openSessionCount == 0)
    }

    @Test("印刷の完了前に期限を過ぎても、片付けは印刷が終わるまで待つ")
    func defersCleanupUntilPrintingFinishes() async throws {
        let paginator = WebPaginator()
        paginator.printTimeout = .zero
        await #expect(throws: WebPaginator.PaginationError.timedOut) {
            _ = try await paginator.paginate(
                .html(simpleHTML, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15),
                allowsJavaScript: false)
        }
        // The print thread is still running, so the web view and temporary files must still be held.
        #expect(paginator.openSessionCount == 1)
        let deadline = ContinuousClock.now + .seconds(10)
        while paginator.openSessionCount > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(paginator.openSessionCount == 0)
    }

    @Test("成功した組版はウィンドウと一時ファイルを片付ける")
    func releasesSessionAfterSuccess() async throws {
        let paginator = WebPaginator()
        _ = try await paginator.paginate(
            .html(simpleHTML, baseURL: FileManager.default.temporaryDirectory), pageSize: a4,
            margins: .uniform(millimeters: 15), allowsJavaScript: false)
        #expect(paginator.openSessionCount == 0)
    }

    @Test("存在しないファイルは読み込み失敗のエラーになる")
    func failsForMissingFile() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(
            path: "surimono-missing-\(UUID().uuidString).html")
        await #expect(throws: WebPaginator.PaginationError.self) {
            _ = try await WebPaginator().paginate(
                .file(missing, readAccessURL: missing.deletingLastPathComponent()), pageSize: a4,
                margins: .uniform(millimeters: 15), allowsJavaScript: false)
        }
    }
}

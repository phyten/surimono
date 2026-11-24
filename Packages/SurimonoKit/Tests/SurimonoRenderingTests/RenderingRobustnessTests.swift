import AppKit
import ImageIO
import PDFKit
import RobustnessSupport
import SurimonoCore
import Testing
import WebKit

@testable import SurimonoRendering

/// Unusual documents through the real hidden WKWebView. Each must end, within its time, in pages or in an error for
/// that document, and the next document must still lay out. They are slow, so `make robustness-rendering` runs them.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SURIMONO_ROBUSTNESS_WEB"] == "1"), .serialized)
struct RenderingRobustnessTests {
    @Test("20万個の要素がある本文でも、時間内にページかエラーになる", .timeLimit(.minutes(5)))
    func manyElements() async throws {
        _ = try await WebRobustness.prepare(String(repeating: "<span>word </span>", count: 200_000), name: "200k-nodes")
    }

    @Test("2000行50列の表でも、時間内にページかエラーになる", .timeLimit(.minutes(5)))
    func wideTable() async throws {
        let row = "<tr>" + String(repeating: "<td>1</td>", count: 50) + "</tr>"
        _ = try await WebRobustness.prepare(
            "<table>" + String(repeating: row, count: 2_000) + "</table>", name: "table-2000x50")
    }

    @Test("縦3万画素の画像の後ろにある本文も刷れる", .timeLimit(.minutes(3)))
    func tallImage() async throws {
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 30_000, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 30_000))
        let data = NSMutableData()
        let png = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(png, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(png))
        let outcome = try await WebRobustness.prepare(
            "<img src='data:image/png;base64,\((data as Data).base64EncodedString())'>", name: "tall-image")
        guard case .pages(_, let containsEnd) = outcome else {
            Issue.record("tall image: \(outcome)")
            return
        }
        #expect(containsEnd)
    }

    @Test("描くのに時間のかかる SVG でも、時間内にページかエラーになる", .timeLimit(.minutes(3)))
    func slowSVG() async throws {
        _ = try await WebRobustness.prepare(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="2000" height="2000">
            <filter id="f"><feTurbulence baseFrequency="0.9" numOctaves="10"/><feGaussianBlur stdDeviation="40"/></filter>
            <rect width="2000" height="2000" filter="url(#f)"/>
            \(String(repeating: "<circle cx='1000' cy='1000' r='900' fill='none' stroke='navy' filter='url(#f)'/>", count: 40))
            </svg>
            """, name: "slow-svg")
    }

    @Test("タイマーとアニメーションが止まらない文書でも、時間内にページかエラーになる", .timeLimit(.minutes(3)))
    func endlessTimers() async throws {
        _ = try await WebRobustness.prepare(
            "<script>setInterval(() => document.body.append('.'), 1); "
                + "(function f() { requestAnimationFrame(f) })()</script>",
            javaScript: true, name: "endless-timers")
    }

    @Test("スクリプトが終わらない文書でも、時間内にエラーになり次の文書を刷れる", .timeLimit(.minutes(4)))
    func busyScript() async throws {
        _ = try await WebRobustness.prepare("<script>while (true) {}</script>", javaScript: true, name: "busy-script")
    }

    @Test("固定配置と @page の誤用があっても、時間内にページかエラーになる", .timeLimit(.minutes(3)))
    func pageRuleMisuse() async throws {
        _ = try await WebRobustness.prepare(
            """
            <style>@page { size: 1px 1px; margin: 5000px } @page :first { size: 99999in 1in }
            aside { position: fixed; inset: 0; height: 100000px }</style><aside>Fixed</aside>
            """, name: "page-misuse")
    }

    @Test("読み込めない書体を指定した文書でも、本文を刷れる", .timeLimit(.minutes(3)))
    func missingFonts() async throws {
        let outcome = try await WebRobustness.prepare(
            """
            <style>@font-face { font-family: Broken; src: url(data:font/woff2;base64,AAAA) }
            @font-face { font-family: Gone; src: url(file:///nonexistent/font.otf) }
            body { font-family: Broken, Gone, serif }</style><p>Text</p>
            """, name: "missing-fonts")
        guard case .pages(_, let containsEnd) = outcome else {
            Issue.record("missing fonts: \(outcome)")
            return
        }
        #expect(containsEnd)
    }

}

/// The two findings of `make robustness-rendering` that are quick to lay out run with every `make test-kit`.
@MainActor
@Suite(.serialized)
struct WebRecoveryTests {
    @Test(
        "自分を読み込み直す文書でも、最初に読み込んだページを本文ごと刷る", .timeLimit(.minutes(1)),
        arguments: [false, true])
    func refreshLoop(asFile: Bool) async throws {
        let outcome = try await WebRobustness.prepare(
            "<meta http-equiv='refresh' content='0'><p>again</p>", asFile: asFile,
            name: asFile ? "meta-refresh-file" : "meta-refresh-memory")
        // From memory the refresh used to replace the page with a blank one, which printed without its text.
        #expect(outcome == .pages(1, containsEnd: true))
    }

    @Test("開いた HTML が同じフォルダーの別の文書へ移ると、移った先の文書を刷る", .timeLimit(.minutes(1)))
    func fileDocumentFollowsRefresh() async throws {
        let text = try await WebRobustness.printedText(
            files: [
                "index.html": "<meta http-equiv='refresh' content='0;url=chapter.html'><p>ENTRANCE</p>",
                "chapter.html": "<p>CHAPTER</p>",
            ])
        #expect(text.contains("CHAPTER"))
        #expect(!text.contains("ENTRANCE"))
    }

    @Test(
        "Markdown から組んだ紙面は、原稿の HTML が別の文書へ移ろうとしても移らない", .timeLimit(.minutes(1)),
        arguments: [false, true])
    func generatedPageDoesNotFollow(sandboxed: Bool) async throws {
        let text = try await WebRobustness.printedText(
            files: [
                "notes.md": "<meta http-equiv=\"refresh\" content=\"0;url=chapter.html\">\n\nMARKDOWN BODY\n",
                "chapter.html": "<p>CHAPTER</p>",
            ], opened: "notes.md", format: .markdown, sandboxed: sandboxed)
        #expect(text.contains("MARKDOWN BODY"))
        #expect(!text.contains("CHAPTER"))
    }

    @Test("sandbox でも、開いた HTML は許可したフォルダーの別の文書へ移る", .timeLimit(.minutes(1)))
    func sandboxedFileDocumentFollowsRefresh() async throws {
        var atPrint = "印刷開始前"
        let text = try await WebRobustness.printedText(
            files: [
                "index.html": "<meta http-equiv='refresh' content='0;url=chapter.html'><p>ENTRANCE</p>",
                "chapter.html": "<p>CHAPTER</p>",
            ], sandboxed: true,
            didStartPrinting: { view in
                atPrint = "\(view.url?.lastPathComponent ?? "nil") loading=\(view.isLoading)"
            })
        #expect(text.contains("CHAPTER") && !text.contains("ENTRANCE"), "印刷開始 \(atPrint)、本文 \(text.debugDescription)")
    }

    @Test("開いた HTML が二つの文書のあいだを行き来しても、時間内にどちらかを刷る", .timeLimit(.minutes(1)), arguments: [false, true])
    func fileDocumentsThatRefreshEachOther(sandboxed: Bool) async throws {
        var atPrint = "印刷開始前"
        do {
            let text = try await WebRobustness.printedText(
                files: [
                    "index.html": "<meta http-equiv='refresh' content='0;url=chapter.html'><p>ENTRANCE</p>",
                    "chapter.html": "<meta http-equiv='refresh' content='0;url=index.html'><p>CHAPTER</p>",
                ], sandboxed: sandboxed,
                didStartPrinting: { view in
                    atPrint = "\(view.url?.lastPathComponent ?? "nil") loading=\(view.isLoading)"
                })
            print("robustness-rendering refresh-each-other: \(text.prefix(40))")
            #expect(
                text.contains("CHAPTER") || text.contains("ENTRANCE"),
                "印刷開始 \(atPrint)、抽出 \(text.debugDescription)")
        } catch DocumentRenderer.RenderingError.pagination(.loadFailed(let reason)) {
            if #available(macOS 26, *) { throw DocumentRenderer.RenderingError.pagination(.loadFailed(reason)) }
            print("robustness-rendering refresh-each-other: \(reason)")
            #expect(reason == URLError(.httpTooManyRedirects).localizedDescription)
        }
    }

    @Test("メモリから組む文書は、別の文書へ移ろうとしても最初の文書を刷る", .timeLimit(.minutes(1)))
    func memoryDocumentKeepsFirstDocument() async throws {
        let outcome = try await WebRobustness.prepare(
            "<meta http-equiv='refresh' content='0;url=data:text/html,%3Cp%3EOTHER%3C/p%3E'><p>first</p>",
            name: "memory-refresh-elsewhere")
        #expect(outcome == .pages(1, containsEnd: true))
    }

    @Test("印刷を始めた文書の WebContent のプロセスが終わったら、時間内にエラーになり次の文書を刷れる", .timeLimit(.minutes(1)))
    func webContentEnds() async throws {
        // WebKit has no public way to end its process. This private selector is used only here, in a test;
        // `_killWebContentProcess` left the process running. Only the web view of the session under test is ended,
        // as its print starts.
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        let paginator = WebPaginator()
        var ended = 0
        paginator.didStartPrinting = { webView in
            guard ended == 0, webView.responds(to: kill) else { return }
            ended += 1
            webView.perform(kill)
        }
        let html = "<!doctype html>" + String(repeating: "<p>Paragraph of text.</p>", count: 2_000) + "<p>ENDMARK</p>"
        let outcome = try await SmallStack.withDeadline(limit: .seconds(40)) { @MainActor in
            do {
                let pages = try await paginator.paginate(
                    .html(html, baseURL: nil), pageSize: CGSize(width: 595, height: 842),
                    margins: .uniform(millimeters: 15), allowsJavaScript: false)
                return pages.string?.contains("ENDMARK") == true ? "pages" : "pages without text"
            } catch {
                return "\(error)"
            }
        }
        guard case .finished(let result, _) = outcome else {
            Issue.record("the paginator did not end within 40 s")
            return
        }
        print("robustness-rendering web-content-ends: \(result)")
        #expect(ended == 1)
        // Before, the pages printed after the process ended came out without their text, and nothing said so.
        let termination = NSError(domain: WKError.errorDomain, code: WKError.Code.webContentProcessTerminated.rawValue)
        #expect(result == "\(WebPaginator.PaginationError.loadFailed(termination.localizedDescription))")
        paginator.didStartPrinting = nil
        let next = try await paginator.paginate(
            .html("<p>RECOVERED</p>", baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false)
        #expect(next.string?.contains("RECOVERED") == true)
        #expect(paginator.openSessionCount == 0)
    }

    @Test("HTML の書き出し中に WebContent のプロセスが終わったら、終了のエラーになる", .timeLimit(.minutes(1)))
    func webContentEndsDuringExport() async throws {
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        let paginator = WebPaginator()
        paginator.didStartExporting = { webView in
            if webView.responds(to: kill) { webView.perform(kill) }
        }
        let outcome = try await SmallStack.withDeadline(limit: .seconds(40)) { @MainActor in
            do {
                _ = try await paginator.paginateWithResult(
                    .html("<!doctype html><p>Exported</p>", baseURL: nil), pageSize: CGSize(width: 400, height: 500),
                    margins: .uniform(millimeters: 10), allowsJavaScript: false, exportHTMLTitle: "Example")
                return "exported"
            } catch {
                return "\(error)"
            }
        }
        guard case .finished(let result, _) = outcome else {
            Issue.record("the export did not end within 40 s")
            return
        }
        let termination = NSError(domain: WKError.errorDomain, code: WKError.Code.webContentProcessTerminated.rawValue)
        #expect(result == "\(WebPaginator.PaginationError.loadFailed(termination.localizedDescription))")
    }

    @Test("図を画像にする途中で WebContent のプロセスが終わったら、待ち続けずに終了のエラーになる", .timeLimit(.minutes(1)))
    func webContentEndsDuringSnapshot() async throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let webView = WKWebView(frame: frame)
        let tracker = NavigationTracker()
        webView.navigationDelegate = tracker
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.close() }
        webView.loadHTMLString("<p style='font-size:40px'>Figure</p>", baseURL: nil)
        try await WebPaginator.waitUntil(timeout: .seconds(15)) { tracker.state != .loading }
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        try #require(webView.responds(to: kill))
        webView.perform(kill)
        try await WebPaginator.waitUntil(timeout: .seconds(15)) { tracker.terminationError != nil }
        let started = ContinuousClock.now
        let termination = NSError(domain: WKError.errorDomain, code: WKError.Code.webContentProcessTerminated.rawValue)
        await #expect(throws: WebPaginator.PaginationError.loadFailed(termination.localizedDescription)) {
            _ = try await WebGraphicSnapshot(requestedScale: 1).png(
                in: webView, viewport: frame, document: frame, until: .now + .seconds(30))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("文書の中の見出しへ移るだけのナビゲーションは止めない", .timeLimit(.minutes(1)))
    func fragmentNavigation() async throws {
        let html = """
            <!doctype html><p id="b">Body</p>
            <script>addEventListener('hashchange', () => document.body.insertAdjacentHTML('beforeend', '<p>HASHED</p>'));
            location.hash = 'b';</script>
            """
        let paginator = WebPaginator()
        let pages = try await paginator.paginate(
            .html(html, baseURL: nil), pageSize: CGSize(width: 595, height: 842), margins: .uniform(millimeters: 15),
            allowsJavaScript: true)
        #expect(pages.string?.contains("HASHED") == true)
        for page in [
            "<!doctype html><meta http-equiv='refresh' content='0;url=#b'><p id=b>Body</p>",
            "<!doctype html><p id=b>Body</p><a id=l href='#b'>x</a><script>document.getElementById('l').click()</script>",
            "<!doctype html><p id=b>Body</p><script>location.href = '#b'</script>",
            // A form posted to an anchor loads a new document; it must not pass as a jump within this one.
            """
            <!doctype html><form method=post action='#b'><p id=b>Body</p></form>
            <script>addEventListener('load', () => document.forms[0].submit())</script>
            """,
        ] {
            let result = try await paginator.paginate(
                .html(page, baseURL: nil), pageSize: CGSize(width: 595, height: 842),
                margins: .uniform(millimeters: 15),
                allowsJavaScript: true)
            // A refresh to an anchor loaded a blank page when it was let through.
            #expect(result.string?.contains("Body") == true, "\(page)")
        }
        #expect(
            NavigationTracker.differsOnlyByFragment(
                URL(string: "file:///a.html#b"), from: URL(string: "file:///a.html")))
        #expect(
            !NavigationTracker.differsOnlyByFragment(URL(string: "file:///a.html"), from: URL(string: "file:///a.html"))
        )
        #expect(
            !NavigationTracker.differsOnlyByFragment(
                URL(string: "file:///b.html#b"), from: URL(string: "file:///a.html")))
        #expect(
            NavigationTracker.differsOnlyByFragment(URL(string: "about:blank%23b"), from: URL(string: "about:blank")))
        #expect(!NavigationTracker.differsOnlyByFragment(URL(string: "about:srcdoc"), from: URL(string: "about:blank")))
    }
}

@MainActor
enum WebRobustness {
    enum Outcome: Equatable {
        case pages(Int, containsEnd: Bool)
        case failed(String)
    }

    /// Writes `files` to a new folder, opens `opened` from that file as the app opens it (in the sandbox with the
    /// folder granted, or not), and returns the text of the pages.
    static func printedText(
        files: [String: String], opened: String = "index.html", format: DocumentFormat = .html, sandboxed: Bool = false,
        didStartPrinting: (@MainActor (WKWebView) -> Void)? = nil
    ) async throws -> String {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "surimono-navigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, body) in files {
            let page = name.hasSuffix(".html") ? "<!doctype html><meta charset=utf-8>" + body : body
            try Data(page.utf8).write(to: folder.appendingPathComponent(name))
        }
        let url = folder.appendingPathComponent(opened)
        var source = DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: format)
        source.allowedResourceFolders = [folder]
        let renderer = DocumentRenderer(
            isSandboxed: { sandboxed },
            paginateWithResult: { request in
                let paginator = WebPaginator()
                paginator.didStartPrinting = didStartPrinting
                return try await paginator.paginate(request)
            })
        let pages = try await renderer.prepare(source, settings: settings(javaScript: false)).logicalDocument
        return pages.string ?? ""
    }

    static func settings(javaScript: Bool) -> RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"), allowsJavaScriptInHTML: javaScript)
    }

    /// Lays out `body` as an HTML document, then a small document with the same renderer, and returns what became of
    /// the first. The deadline is the paginator's own load and print time plus a minute of slack.
    /// `asFile` lays the page out from a file, as the app opens an HTML document; otherwise from memory, as a page
    /// read from the clipboard.
    static func prepare(_ body: String, javaScript: Bool = false, asFile: Bool = false, name: String) async throws
        -> Outcome
    {
        _ = NSApplication.shared
        let renderer = DocumentRenderer()
        let html = "<!doctype html><meta charset=utf-8>" + body + "<p>ENDMARK</p>"
        var fileURL: URL?
        if asFile {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                "surimono-robustness-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            fileURL = folder.appendingPathComponent("page.html")
            try Data(html.utf8).write(to: try #require(fileURL))
        }
        defer { if let fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) } }
        let source = DocumentSource(data: Data(html.utf8), fileURL: fileURL, format: .html)
        let limit =
            PageLayoutLimits.timeout(bytes: html.utf8.count, baseSeconds: 15)
            + PageLayoutLimits.timeout(bytes: html.utf8.count, baseSeconds: 60) + .seconds(60)
        let started = ContinuousClock.now
        let outcome = try await SmallStack.withDeadline(limit: limit) { @MainActor in
            do {
                let pages = try await renderer.prepare(source, settings: Self.settings(javaScript: javaScript))
                    .logicalDocument
                return Outcome.pages(pages.pageCount, containsEnd: pages.string?.contains("ENDMARK") == true)
            } catch {
                return Outcome.failed(String(describing: error))
            }
        }
        guard case .finished(let result, _) = outcome else {
            Issue.record("\(name) did not end within \(limit)")
            return .failed("timed out")
        }
        print("robustness-rendering \(name): \(result) in \(ContinuousClock.now - started)")
        let next = DocumentSource(data: Data("<p>RECOVERED</p>".utf8), format: .html)
        let recovered = try await renderer.prepare(next, settings: Self.settings(javaScript: false)).logicalDocument
        #expect(recovered.string?.contains("RECOVERED") == true)
        return result
    }
}

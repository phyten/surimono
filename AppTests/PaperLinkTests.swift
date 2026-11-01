import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct PaperLinkTests {
    @Test("HTTP・HTTPS・メールのリンクは既定の外部アプリで開く", arguments: ["http", "https", "mailto", "HTTPS"])
    func external(scheme: String) throws {
        let url = try #require(URL(string: "\(scheme):example.com"))
        #expect(PaperLinkAction.resolve(url, fileExists: false, isRegularFile: false, format: nil) == .external)
    }

    @Test("存在する対応形式のファイルはSurimonoで開く", arguments: ["md", "pdf", "png", "org", "txt", "html", "csv", "zip", "tex"])
    func supportedFile(ext: String) {
        let url = URL(fileURLWithPath: "/fixtures/other.\(ext)")
        #expect(
            PaperLinkAction.resolve(
                url, fileExists: true, isRegularFile: true, format: DocumentFormat(fileExtension: ext)) == .document)
    }

    @Test("存在しないファイルは形式によらず見つからないと知らせる", arguments: ["md", "unknown"])
    func missingFile(ext: String) {
        let url = URL(fileURLWithPath: "/fixtures/missing.\(ext)")
        #expect(
            PaperLinkAction.resolve(
                url, fileExists: false, isRegularFile: false, format: DocumentFormat(fileExtension: ext))
                == .missingFile)
    }

    @Test("未対応ファイルと対応する拡張子のフォルダーは開かない")
    func unsupportedFile() {
        #expect(
            PaperLinkAction.resolve(
                URL(fileURLWithPath: "/fixtures/tool.app"), fileExists: true, isRegularFile: true, format: nil)
                == .unsupported)
        #expect(
            PaperLinkAction.resolve(
                URL(fileURLWithPath: "/fixtures/folder.md"), fileExists: true, isRegularFile: false, format: .markdown)
                == .unsupported)
    }

    @Test(
        "その他のスキームと相対URLは外部アプリへ渡さない", arguments: ["tel:123", "javascript:alert(1)", "ftp://example.com/a", "other.md"])
    func unsupportedScheme(value: String) throws {
        let url = try #require(URL(string: value))
        #expect(PaperLinkAction.resolve(url, fileExists: true, isRegularFile: true, format: .markdown) == .unsupported)
    }

    @Test("外部アプリで開けなければトーストを通知する")
    func externalFailure() async throws {
        var opened: [URL] = []
        var toasts: [Toast] = []
        let handler = PaperLinkHandler(openExternal: { url in
            opened.append(url)
            throw CocoaError(.fileReadUnknown)
        })
        let url = try #require(URL(string: "https://example.com/"))
        await handler.open(url) { toasts.append($0) }
        #expect(opened == [url])
        #expect(toasts.count == 1)
        #expect(toasts.first?.title == String(localized: "This link cannot be opened"))
    }

    @Test("対応ファイルのリンクをOpenRouterへ渡して元の内容を保つ")
    func fileThroughRouter() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "other.md")
        let data = Data("# Link destination\n".utf8)
        try data.write(to: url)
        var opened: [URL] = []
        let router = OpenRouter(
            openDocument: { url, completion in
                opened.append(url)
                completion(true)
            }, openBundle: { _ in Issue.record("画像の束にしない") }, warn: { _ in Issue.record("警告しない") },
            hasOpenWindows: { true }, showWelcome: { Issue.record("ウェルカム画面を出さない") })
        let handler = PaperLinkHandler(
            openExternal: { _ in Issue.record("外部アプリへ渡さない") },
            openDocument: { router.open([$0]) })
        await handler.open(url) { _ in Issue.record("トーストを出さない") }
        #expect(opened == [url])
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("URLのdelegateを接続しても文書内リンクは表示用コピーのページへ移動する")
    func internalDestination() throws {
        let source = try #require(PDFDocument(data: TestFixtures.pdf("internal-link", pages: 3)))
        let first = try #require(source.page(at: 0))
        let destination = try #require(source.page(at: 2))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 50, y: 700, width: 100, height: 30), forType: .link, withProperties: nil)
        annotation.action = PDFActionGoTo(destination: PDFDestination(page: destination, at: CGPoint(x: 50, y: 700)))
        first.addAnnotation(annotation)
        let view = PaperPDFView(frame: CGRect(x: 0, y: 0, width: 420, height: 594))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.configure(
            source, at: 0,
            options: ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false),
            logicalMargin: nil, showsPageNumbers: true)
        view.onToast = { _ in Issue.record("文書内の移動でトーストを出さない") }
        let action = try #require(view.document?.page(at: 0)?.annotations.first?.action as? PDFActionGoTo)
        #expect(action.destination.page === view.document?.page(at: 2))
        view.perform(action)
        #expect(view.currentPageIndex == 2)
        withExtendedLifetime(window) {}
    }

    @Test("紙のURLリンクdelegateは不足ファイルの名前をトーストへ渡す")
    func delegateConnection() async throws {
        let view = PaperPDFView()
        let delegate = try #require(view.delegate)
        #expect(delegate !== view)
        #expect(!delegate.responds(to: NSSelectorFromString("PDFViewWillChangeScaleFactor:toScale:")))
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(
            path: "missing.md")
        var toasts: [Toast] = []
        view.onToast = { toasts.append($0) }
        view.perform(PDFActionURL(url: url))
        for _ in 0..<100 where toasts.isEmpty { await Task.yield() }
        #expect(toasts.count == 1)
        #expect(toasts.first?.title == String(localized: "The linked file could not be found"))
        #expect(toasts.first?.detail == "missing.md")
    }
    @Test("サンドボックスで読めない紙のリンクはフォルダ許可を案内する")
    func missingSandboxFileRequestsPermission() async {
        var handler = PaperLinkHandler()
        handler.isSandboxed = { true }
        var toasts: [Toast] = []
        await handler.open(URL(fileURLWithPath: "/missing-folder-\(UUID().uuidString)/next.md")) {
            toasts.append($0)
        }
        #expect(toasts.count == 1)
        #expect(toasts.first?.action == .allowFolderAccess)
    }

}

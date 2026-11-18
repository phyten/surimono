import Foundation
import Testing

@testable import SurimonoCore

struct URLDocumentTests {
    @Test("アドレス欄には単独の HTTP・HTTPS の URL だけを入れる")
    func prefill() {
        #expect(URLDocument.address(" HTTPS://example.test/path?q=1\n")?.host == "example.test")
        #expect(URLDocument.address("http://example.test")?.scheme == "http")
        for invalid in [
            nil, "", "/tmp/a", "example.test", "https://", "mailto:a@b.test", "file:///tmp/a",
            "see https://example.test", "https://one.test\nhttps://two.test", "https://one.test two",
        ] {
            #expect(URLDocument.address(invalid) == nil)
        }
    }

    @Test("応答の種類と最後の URL の拡張子から形式を選ぶ")
    func formats() {
        let url = URL(string: "https://example.test/read")!
        let md = url.appendingPathExtension("MD")
        #expect(URLDocument.format(mimeType: "Text/HTML; charset=utf-8", url: md) == .html)
        #expect(URLDocument.format(mimeType: "text/markdown", url: url) == .markdown)
        #expect(URLDocument.format(mimeType: "application/octet-stream", url: md) == .markdown)
        #expect(URLDocument.format(mimeType: "text/plain", url: md) == .markdown)
        #expect(URLDocument.format(mimeType: "text/plain", url: url) == .plainText)
        #expect(URLDocument.format(mimeType: "application/pdf", url: url) == .pdf)
        #expect(URLDocument.format(mimeType: "image/png", url: url) == .image)
        #expect(URLDocument.format(mimeType: "application/zip", url: url) == nil)
    }

    private func load(_ path: String, limit: Int = 100, origin: String = "https://fixture.invalid") async throws
        -> URLDocument
    {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageStub.self]
        return try await URLDocument.load(
            URL(string: origin + "/" + path)!, configuration: config,
            limit: limit)
    }

    @Test("宣言サイズと受信中の合計サイズをともに制限し、上限ちょうどなら開く")
    func limits() async throws {
        for path in ["large-header", "chunks"] {
            await #expect(throws: URLDocument.Failure.tooLarge) { try await load(path, limit: 5) }
        }
        let page = try await load("chunks", limit: 6)
        #expect(page.data == Data("123456".utf8))
        #expect(page.title == "chunks")
    }

    @Test("タイムアウトを呼び出し元へ返し、受信途中の文書を開かない")
    func timeout() async {
        await #expect {
            try await load("timeout")
        } throws: { error in
            (error as? URLError)?.code == .timedOut
        }
    }

    @Test("HTML は応答の URL とページの表題を持つ")
    func html() async throws {
        let page = try await load("article")
        #expect(page.url.absoluteString == "https://fixture.invalid/final/index.html")
        #expect(page.title == "Tea & Coffee")
        #expect(page.format == .html)
    }

    @Test("HTTP は最初の要求から HTTPS にし、パスとクエリを保つ")
    func upgrade() async throws {
        let page = try await load("a%20b/chunks?q=x%2Fy", origin: "HTTP://fixture.invalid:80")
        #expect(page.url.absoluteString == "https://fixture.invalid/a%20b/chunks?q=x%2Fy")
        let customPort = try await load("chunks", origin: "http://fixture.invalid:8443")
        #expect(customPort.url.port == 8443)
    }

    @Test("HTTP の入力で HTTPS の取得に失敗したときは HTTPS が必要なことを伝える")
    func upgradeFailure() async {
        await #expect(throws: URLDocument.Failure.requiresHTTPS) {
            try await load("timeout", origin: "http://fixture.invalid")
        }
        await #expect(throws: URLDocument.Failure.unsupportedFormat) {
            try await load("zip", origin: "http://fixture.invalid")
        }
    }

    @Test("HTTPS への転送後の本文と URL を返す")
    func redirects() async throws {
        let page = try await load("redirect")
        #expect(page.data == Data("123456".utf8))
        #expect(page.url.absoluteString == "https://fixture.invalid/chunks")
    }

    @Test("HTTP や FTP への転送先には要求を送らない")
    func refusesRedirect() async {
        for path in ["http-redirect", "other-scheme"] {
            await #expect(throws: URLDocument.Failure.requiresHTTPS) { try await load(path) }
        }
    }

    @Test("HTTP エラーと未対応形式は文書を返さない")
    func errors() async {
        await #expect(throws: URLDocument.Failure.badResponse) { try await load("missing") }
        await #expect(throws: URLDocument.Failure.unsupportedFormat) { try await load("zip") }
    }
}

private final class PageStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        #expect(url.scheme == "https")
        #expect(request.timeoutInterval == 20)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0")
        let path = url.lastPathComponent
        if path == "other-target" {
            Issue.record("許可していない転送先を要求した")
        }
        let redirects = [
            "redirect": "https://fixture.invalid/chunks",
            "http-redirect": "http://fixture.invalid/other-target",
            "other-scheme": "ftp://fixture.invalid/other-target",
        ]
        if let location = redirects[path], let target = URL(string: location) {
            let redirect = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            return
        }
        if path == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        var headers = ["Content-Type": path == "article" ? "text/html" : "text/plain"]
        if path == "large-header" { headers["Content-Length"] = "99999" }
        if path == "zip" { headers["Content-Type"] = "application/zip" }
        let response = HTTPURLResponse(
            url: path == "article" ? URL(string: "https://fixture.invalid/final/index.html")! : url,
            statusCode: path == "missing" ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunks = path == "article" ? ["<title>Tea &amp; Coffee</title>"] : ["123", "456"]
        for chunk in chunks { client?.urlProtocol(self, didLoad: Data(chunk.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

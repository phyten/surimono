import Foundation

public struct URLDocument: Sendable {
    public enum Failure: Error {
        case invalidURL, requiresHTTPS, unsupportedFormat, tooLarge, badResponse
    }

    public let url: URL
    public let data: Data
    public let format: DocumentFormat

    public let title: String

    fileprivate init(url: URL, data: Data, format: DocumentFormat) {
        self.url = url
        self.data = data
        self.format = format
        if format == .html, let name = DocumentOutline.title(ofHTML: TextDecoding.decode(data).text), !name.isEmpty {
            title = name
        } else {
            let name = url.lastPathComponent
            title = name.isEmpty || name == "/" ? url.host ?? url.absoluteString : name
        }
    }

    public static func address(_ text: String?) -> URL? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
            !trimmed.contains("\\"), let url = URL(string: trimmed),
            ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host, !host.isEmpty,
            url.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        return url
    }

    public static func format(mimeType: String?, url: URL) -> DocumentFormat? {
        let mime = mimeType?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        switch mime {
        case "text/html": return .html
        case "text/markdown": return .markdown
        case "application/pdf": return .pdf
        case let value? where value.hasPrefix("image/"): return .image
        default:
            if url.pathExtension.lowercased() == "md" { return .markdown }
            return mime == "text/plain" ? .plainText : nil
        }
    }

    public static func load(_ url: URL) async throws -> Self {
        try await load(url, configuration: .ephemeral, limit: 20_000_000)
    }

    static func load(_ url: URL, configuration: URLSessionConfiguration, limit: Int) async throws -> Self {
        guard address(url.absoluteString) != nil, var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw Failure.invalidURL }
        let upgraded = target.scheme?.lowercased() == "http"
        target.scheme = "https"
        if upgraded, target.port == 80 { target.port = nil }
        guard let secureURL = target.url else { throw Failure.invalidURL }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        var request = URLRequest(url: secureURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let transfer = PageTransfer(limit: limit)
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { completion in
                    transfer.start(session: session, request: request, completion: completion)
                }
            } onCancel: {
                session.getAllTasks { tasks in
                    for task in tasks { task.cancel() }
                }
            }
        } catch  where upgraded && !Task.isCancelled {
            // An unsupported or oversized document was reached successfully over HTTPS.
            if let failure = error as? Failure, failure != .badResponse { throw failure }
            throw Failure.requiresHTTPS
        }
    }
}

// Each session has one task. After resume, only its serial delegate queue touches the buffer and completion.
private final class PageTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let limit: Int
    private var body = Data()
    private var failure: URLDocument.Failure?
    private var completion: CheckedContinuation<URLDocument, any Error>?
    private var format: DocumentFormat?

    init(limit: Int) { self.limit = limit }

    func start(session: URLSession, request: URLRequest, completion: CheckedContinuation<URLDocument, any Error>) {
        self.completion = completion
        let task = session.dataTask(with: request)
        task.resume()
        if Task.isCancelled { task.cancel() }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard URLDocument.address(request.url?.absoluteString)?.scheme?.lowercased() == "https" else {
            failure = .requiresHTTPS
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let url = URLDocument.address(http.url?.absoluteString), url.scheme?.lowercased() == "https"
        else {
            failure = failure ?? .badResponse
            completionHandler(.cancel)
            return
        }
        format = URLDocument.format(mimeType: http.mimeType, url: url)
        if format == nil { failure = .unsupportedFormat }
        if http.expectedContentLength > limit { failure = .tooLarge }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard data.count <= limit - body.count else {
            failure = .tooLarge
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { completion = nil }
        if let error: any Error = failure ?? error {
            completion?.resume(throwing: error)
        } else if let url = task.response?.url, let format {
            completion?.resume(returning: URLDocument(url: url, data: body, format: format))
        } else {
            completion?.resume(throwing: URLDocument.Failure.badResponse)
        }
    }
}

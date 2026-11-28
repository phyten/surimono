import Foundation

/// What the converted page shows instead of content: frames, formulas left as source, images that will not appear.
public struct PageCounts: Codable, Equatable, Sendable {
    public var frames = 0
    public var pictureFrames = 0
    /// The reason each picture fell back to a frame or an external image, as the page carries it.
    public var pictureReasons: [String] = []
    public var picturesDrawn = 0
    public var formulasAsSource = 0
    public var imagesMissing = 0
    public var imagesEPS = 0
    public var citationsMissing = 0
    public var beamerUnreadableFrames = 0
    public var beamerTheme = false

    public init() {}

    /// Counts in the fragment's body. Images are resolved against the main file's folder; one outside the paper's
    /// folder, or not there, is missing.
    public init(html body: String, mainFolder: URL, paperFolder: URL) {
        frames = Self.count(#"class="latex-unsupported""#, in: body)
        pictureFrames = Self.count("data-latex-picture", in: body)
        picturesDrawn = Self.count(#"class="tikz-block""#, in: body)
        formulasAsSource = Self.count(#"class="math-error""#, in: body)
        citationsMissing = Self.count(#"class="latex-missing""#, in: body)
        pictureReasons = Self.matches(#"data-latex-picture data-issue="([^"]*)""#, in: body).map(Self.unescape)
        let root = paperFolder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for source in Self.matches(#"<img[^>]*\ssrc="([^"]*)""#, in: body).map(Self.unescape) {
            if source.hasPrefix("data:") { continue }
            if let scheme = URLComponents(string: source)?.scheme, scheme != "file" {
                imagesMissing += 1
                continue
            }
            let path = URLComponents(string: source)?.path.removingPercentEncoding ?? source
            let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : mainFolder.appending(path: path))
                .standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard url.path.hasPrefix(root), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else {
                imagesMissing += 1
                continue
            }
            if ["eps", "ps"].contains(url.pathExtension.lowercased()) { imagesEPS += 1 }
        }
    }

    /// A picture's reason without file names and numbers, so that the same cause groups together.
    public static func reasonKey(_ reason: String) -> String {
        let parts = reason.components(separatedBy: " — ")
        let head = parts.count > 1 ? parts[1] : parts[0]
        let generic = head.replacingOccurrences(of: #"\d+(\.\d+)?"#, with: "N", options: .regularExpression)
        return String(generic.prefix(80))
    }

    static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let string = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: string.length)).map {
            string.substring(with: $0.range(at: 1))
        }
    }

    static func unescape(_ html: String) -> String {
        html.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

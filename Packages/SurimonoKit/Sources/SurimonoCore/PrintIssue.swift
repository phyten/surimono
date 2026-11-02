import Foundation

public struct PrintIssue: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case image, overflow, math, latex }
    public enum ImageFailure: String, Codable, Sendable { case missing, folderAccess, other }
    public enum Element: String, Codable, Sendable { case table, image, figure, code, math }

    public let id: String
    /// Identifies the source occurrence across layouts, before display names and excerpts are shortened.
    public let locationKey: String?
    public let kind: Kind
    public var detail: String
    public var imageFailure: ImageFailure?
    public let element: Element?
    /// One-based logical page, independent of the sheet's imposition. Nil when WebKit left no usable link.
    public var pageNumber: Int?
    public var rect: CGRect?

    public init(
        id: String, kind: Kind, detail: String, imageFailure: ImageFailure? = nil, element: Element? = nil,
        pageNumber: Int? = nil, rect: CGRect? = nil, locationKey: String? = nil
    ) {
        self.id = id
        self.locationKey = locationKey
        self.kind = kind
        self.detail = detail
        self.imageFailure = imageFailure
        self.element = element
        self.pageNumber = pageNumber
        self.rect = rect
    }

    public func pageIndex(in issues: [Self], pageCount: Int, sourcePageCount: Int) -> Int {
        let lastIndex = max(0, pageCount - 1)
        if let locationKey, let page = issues.first(where: { $0.locationKey == locationKey })?.pageNumber {
            return min(lastIndex, max(0, page - 1))
        }
        let fraction = Double(max(0, (pageNumber ?? 1) - 1)) / Double(max(1, sourcePageCount - 1))
        return min(lastIndex, Int((fraction * Double(lastIndex)).rounded()))
    }

    public static func sorted(_ issues: [Self]) -> [Self] {
        issues.enumerated().sorted {
            let left = $0.element.pageNumber ?? Int.max
            let right = $1.element.pageNumber ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    public static func excerpt(_ text: String) -> String {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(text.prefix(40)) + (text.count > 40 ? "…" : "")
    }

    public static func imageName(_ url: URL, directory: URL?) -> String {
        if url.isFileURL, let directory {
            let root = directory.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            if path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        }
        return url.lastPathComponent
    }
}

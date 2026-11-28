import Foundation

public struct PrintIssue: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case image, overflow, math, latex, rst, bibliography, mermaid, mermaidTimeout, verticalWriting
        /// A reader printed part of the document as its text, because it nested deeper than can be read.
        case nestingLimit
        /// A reader left out part of the document (a Word part, a notebook's JSON), because it nested too deeply.
        case nestingOmission
        case contentsLimit
    }
    public enum ImageFailure: String, Codable, Sendable { case missing, folderAccess, other }
    public enum Element: String, Codable, Sendable { case table, image, figure, code, math }

    public static let unresolvedLaTeXPages = PrintIssue(
        id: "latex-page-references", kind: .latex, detail: "Some LaTeX page numbers could not be determined.")

    public let id: String
    /// Identifies the source occurrence across layouts, before display names and excerpts are shortened.
    public let locationKey: String?
    public let kind: Kind
    public var detail: String
    public var imageFailure: ImageFailure?
    /// The file a reader could not read because it lies outside the document's folder, as the document names it. A
    /// folder that contains it, once allowed, lets it be read.
    public var outsideFile: String?
    /// Where the outside file is, for finding a folder that holds both it and the document.
    public var outsideURL: URL?
    /// The failed read of a named file this issue is about (`UnreadFile.id`), which ties the note on the page to the
    /// places the reader looked in.
    public var unreadFile: String?
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

    /// The issue as a binder lists it: its identity told apart from the other documents' and its page counted from
    /// the binder's start. Everything else it says about the problem stays as it was.
    public func inBinder(prefix: String, pageOffset: Int) -> Self {
        var issue = Self(
            id: prefix + id, kind: kind, detail: detail, imageFailure: imageFailure, element: element,
            pageNumber: pageNumber.map { $0 + pageOffset }, rect: rect, locationKey: locationKey.map { prefix + $0 })
        issue.outsideFile = outsideFile
        issue.outsideURL = outsideURL
        issue.unreadFile = unreadFile
        return issue
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

    /// What a problem asks of the reader: content that will not print, or a layout worth a look. Told apart, an
    /// unreadable image is not mistaken for a table that merely runs past the margin.
    public enum Group: Sendable { case content, layout }

    public var unreadLaTeXCommands: String? {
        guard kind == .latex else { return nil }
        for prefix in [LaTeXConverter.unreadCommandPrefix, LaTeXConverter.japaneseUnreadCommandPrefix]
        where detail.hasPrefix(prefix) {
            return String(detail.dropFirst(prefix.count))
        }
        return nil
    }

    public var group: Group { kind == .overflow || kind == .verticalWriting ? .layout : .content }

    /// The issues by group, those that cost content first. A group without issues is left out, and each group keeps
    /// the order it was given in.
    public static func grouped(_ issues: [Self]) -> [(group: Group, issues: [Self])] {
        [Group.content, .layout].compactMap { group in
            let members = issues.filter { $0.group == group }
            return members.isEmpty ? nil : (group, members)
        }
    }

    private static let spotEdge: CGFloat = 8
    private static let spotLeading: CGFloat = 8
    private static let spotAbove: CGFloat = 4
    private static let spotHeight: CGFloat = 32
    private static let spotMargin: CGFloat = 2
    private static let spotMinimumWidth: CGFloat = 24

    /// The frame the paper draws around a problem for a moment, in the page's own coordinates. The link that marks a
    /// problem is a point at the start of its element and says nothing of the element's size, so the frame starts
    /// there and runs to the right edge of the page: it holds the first lines of any kind of element, and does not
    /// claim to know more.
    public static func spotFrame(around anchor: CGRect, in page: CGRect) -> CGRect {
        let minX = max(page.minX + spotEdge, anchor.minX - spotLeading)
        let maxX = max(page.maxX - spotEdge, minX + spotMinimumWidth)
        let top = min(anchor.maxY + spotAbove, page.maxY - spotMargin)
        let bottom = max(top - spotHeight, page.minY + spotMargin)
        return CGRect(x: minX, y: bottom, width: maxX - minX, height: max(top - bottom, 0))
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

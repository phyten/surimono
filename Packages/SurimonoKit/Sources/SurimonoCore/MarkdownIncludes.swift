import Foundation
import Markdown

/// The documents a Markdown file names: Marked's `<<[file]`, MultiMarkdown's `{{file}}` and iA Writer's `/file`, each on
/// a line of its own, or a table of contents such as GitBook's SUMMARY.md, which has nothing but lists of links.
public struct MarkdownIncludes: Equatable, Sendable {
    /// Relative to the parent's folder, normalized, in reading order and without repeats.
    public let paths: [String]
    /// References that leave the parent's folder or are not relative paths, as written.
    public let refused: [String]
    /// The parent's own text without the include lines; nil for a table of contents, which is only a list.
    public let preface: String?

    /// Nil unless the text names at least one document, so that an ordinary document costs nothing further.
    public init?(markdown text: String) {
        let scan = Self.scan(text)
        var references = scan.references
        var preface: String? = scan.keptLines.joined(separator: "\n")
        if references.isEmpty {
            guard let links = Self.tableOfContents(text) else { return nil }
            references = links
            preface = nil
        }
        var paths: [String] = []
        var refused: [String] = []
        for reference in references {
            if let path = Self.normalized(reference) {
                if !paths.contains(path) { paths.append(path) }
            } else if !refused.contains(reference) {
                refused.append(reference)
            }
        }
        guard !paths.isEmpty || !refused.isEmpty else { return nil }
        self.paths = paths
        self.refused = refused
        self.preface = preface
    }

    /// The parent read again: the same text without its include lines.
    public static func prefaceData(_ data: Data) -> Data {
        Data(scan(TextDecoding.decode(data).text).keptLines.joined(separator: "\n").utf8)
    }

    // MARK: - Include lines

    private static func scan(_ text: String) -> (references: [String], keptLines: [Substring]) {
        var references: [String] = []
        var kept: [Substring] = []
        var fence: (marker: Character, length: Int)?
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let open = fence {
                if isClosing(line, of: open) { fence = nil }
                kept.append(line)
            } else if let opening = openingFence(line) {
                fence = opening
                kept.append(line)
            } else if let reference = reference(in: line) {
                references.append(reference)
            } else {
                kept.append(line)
            }
        }
        return (references, kept)
    }

    /// The line without up to three spaces in front and whitespace behind; four spaces make it indented code.
    private static func trimmed(_ line: Substring) -> Substring? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3, line.first != "\t" else { return nil }
        var body = line.dropFirst(indent)
        while let last = body.last, last.isWhitespace { body.removeLast() }
        return body
    }

    private static func openingFence(_ line: Substring) -> (marker: Character, length: Int)? {
        guard let body = trimmed(line), let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let length = body.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        // An info string cannot contain a backtick, or the line is inline code.
        if marker == "`", body.dropFirst(length).contains("`") { return nil }
        return (marker, length)
    }

    private static func isClosing(_ line: Substring, of fence: (marker: Character, length: Int)) -> Bool {
        guard let body = trimmed(line) else { return false }
        return body.count >= fence.length && body.allSatisfy { $0 == fence.marker }
    }

    private static func reference(in line: Substring) -> String? {
        guard let body = trimmed(line), !body.isEmpty else { return nil }
        if body.hasPrefix("<<["), body.hasSuffix("]") {
            let path = body.dropFirst(3).dropLast().trimmingCharacters(in: .whitespaces)
            return path.isEmpty || path.contains("]") ? nil : path
        }
        if body.hasPrefix("{{"), body.hasSuffix("}}") {
            let path = body.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
            return hasFileExtension(path) && !path.contains("}") ? path : nil
        }
        if body.hasPrefix("/") {
            let path = String(body.dropFirst())
            return hasFileExtension(path) ? path : nil
        }
        return nil
    }

    /// `{{TOC}}`, a template's `{{ title }}` and `/usr/bin` are not documents; only the file name tells them apart.
    private static func hasFileExtension(_ path: String) -> Bool {
        let name = path.split(separator: "/").last ?? ""
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let suffix = name[name.index(after: dot)...]
        return !suffix.isEmpty && suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// A path inside the parent's folder, or nil when it is absolute, a URL, or climbs out of the folder.
    private static func normalized(_ reference: String) -> String? {
        guard !reference.hasPrefix("/"), !reference.hasPrefix("~"), !reference.contains("://"),
            !reference.lowercased().hasPrefix("file:")
        else { return nil }
        var parts: [Substring] = []
        for part in reference.split(separator: "/") where part != "." {
            if part == ".." {
                guard parts.popLast() != nil else { return nil }
            } else {
                parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    // MARK: - Tables of contents

    /// The local link targets of a document that holds nothing but headings, rules and lists of links.
    private static func tableOfContents(_ text: String) -> [String]? {
        var links: [String] = []
        var hasList = false
        for block in Document(parsing: text).children {
            switch block {
            case is Heading, is ThematicBreak: continue
            case let list as ListItemContainer:
                hasList = true
                guard collect(list, into: &links) else { return nil }
            default: return nil
            }
        }
        return hasList && !links.isEmpty ? links : nil
    }

    private static func collect(_ list: ListItemContainer, into links: inout [String]) -> Bool {
        for item in list.listItems {
            for child in item.children {
                if let nested = child as? ListItemContainer {
                    guard collect(nested, into: &links) else { return false }
                } else if let paragraph = child as? Paragraph, paragraph.childCount == 1,
                    let link = paragraph.child(at: 0) as? Link
                {
                    if let path = localPath(of: link.destination ?? "") { links.append(path) }
                } else {
                    return false
                }
            }
        }
        return true
    }

    /// Web links and a draft's empty link stay in a table of contents without being documents.
    private static func localPath(of destination: String) -> String? {
        let hasScheme = destination.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
        guard !hasScheme else { return nil }
        let path = destination.prefix { $0 != "#" && $0 != "?" }
        guard !path.isEmpty else { return nil }
        return path.removingPercentEncoding ?? String(path)
    }
}

extension MarkdownIncludes {
    /// What a parent file can be bound from, as found on disk.
    public struct Plan: Equatable, Sendable {
        public let parent: URL
        /// The parent's folder as it really was when the plan was made. Every read of a document stays under it, so
        /// that nothing swapped in later, the folder itself included, leads anywhere else.
        public let root: String
        public let hasPreface: Bool
        /// The documents that can be read, in reading order.
        public let documents: [URL]
        /// References that lead to nothing that may be read, as paths for the reader.
        public let missing: [String]
        /// Files that exist in a format a binder cannot hold.
        public let excluded: [URL]

        /// One document alone is not worth a binder; it would only rearrange what is already open.
        public var offersBinder: Bool { documents.count >= 2 }
    }

    public func plan(
        parent: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Plan {
        let parent = parent.standardizedFileURL
        let folder = parent.deletingLastPathComponent()
        var documents: [URL] = []
        var missing: [String] = []
        var excluded: [URL] = []
        for path in paths {
            let url = folder.appending(path: path).standardizedFileURL
            if url == parent { continue }
            guard exists(url), LocalResourceAccess.contains(url, in: folder) else {
                missing.append(path)
                continue
            }
            if OpenRequest.binderFormat(url) == nil {
                excluded.append(url)
            } else {
                documents.append(url)
            }
        }
        let hasText = preface?.contains { !$0.isWhitespace } == true
        return Plan(
            parent: parent, root: (try? ConfinedFile.canonicalPath(folder)) ?? folder.path, hasPreface: hasText,
            documents: documents, missing: missing + refused, excluded: excluded)
    }
}

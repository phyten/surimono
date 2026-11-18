import Foundation

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

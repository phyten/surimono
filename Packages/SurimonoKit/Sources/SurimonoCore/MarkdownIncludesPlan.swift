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
        /// The format each document was found to have, under `root`. The binder takes it from here and does not
        /// look at the file again, where a link put in its place since could lead out of the folder.
        public let formats: [URL: DocumentFormat]
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
        var formats: [URL: DocumentFormat] = [:]
        let root = (try? ConfinedFile.canonicalPath(folder)) ?? folder.path
        for path in paths {
            let url = folder.appending(path: path).standardizedFileURL
            if url == parent { continue }
            guard exists(url), LocalResourceAccess.contains(url, in: folder) else {
                missing.append(path)
                continue
            }
            // What is read to tell the format must be the file under the folder, not what a link leads to.
            if let format = OpenRequest.binderFormat(url, within: root) {
                documents.append(url)
                formats[url] = format
            } else {
                excluded.append(url)
            }
        }
        let hasText = preface?.contains { !$0.isWhitespace } == true
        return Plan(
            parent: parent, root: root, hasPreface: hasText,
            documents: documents, formats: formats, missing: missing + refused, excluded: excluded)
    }
}

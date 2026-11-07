import Foundation

/// A binder the reader closed, kept by the files that were in it: a binder has no file of its own to open again.
public struct RecentBinder: Codable, Equatable, Sendable, Identifiable {
    public struct File: Codable, Equatable, Sendable {
        /// The absolute path.
        public var path: String
        /// A read-only security-scoped bookmark. The sandbox gives an app no access to a file after a relaunch, so a
        /// path alone cannot open it again there; nil where no bookmark was made.
        public var bookmark: Data?

        public init(path: String, bookmark: Data? = nil) {
            self.path = path
            self.bookmark = bookmark
        }
    }

    /// In the order the reader had them.
    public var files: [File]

    public init(files: [File]) {
        self.files = files
    }

    public var paths: [String] { files.map(\.path) }

    /// The file name a binder is named after, as its window is: the first file's.
    public var firstName: String { paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }

    /// The same for the same files in any order, which is what makes two binders the same one.
    public var id: Set<String> { Set(paths) }

    /// The binder with each path once, or nil when fewer than two files are left: one document is no binder.
    fileprivate var normalized: RecentBinder? {
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.path).inserted }
        return unique.count >= 2 ? RecentBinder(files: unique) : nil
    }
}

/// The binders the reader closed lately, newest first, to open again from a menu.
///
/// Closing a binder again that has the same files, in any order, replaces the earlier one and brings it to the front,
/// and the oldest go once there are more than `limit`.
public struct RecentBinders: Codable, Equatable, Sendable {
    public static let limit = 5

    public private(set) var entries: [RecentBinder]

    /// - Parameter entries: Newest first. One that is not a binder, or has the files of a newer one, is left out.
    public init(entries: [RecentBinder] = []) {
        var kept: [RecentBinder] = []
        for entry in entries {
            guard let binder = entry.normalized, !kept.contains(where: { $0.id == binder.id }) else { continue }
            kept.append(binder)
            if kept.count == Self.limit { break }
        }
        self.entries = kept
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func record(_ binder: RecentBinder) {
        // A file that could not be reached as its binder closed, on a volume that is away for instance, keeps the
        // bookmark it had: a path alone would not open it again in the sandbox once it is back.
        let bookmarks = Dictionary(
            entries.flatMap(\.files).compactMap { file in file.bookmark.map { (file.path, $0) } },
            uniquingKeysWith: { newest, _ in newest })
        let files = binder.files.map { RecentBinder.File(path: $0.path, bookmark: $0.bookmark ?? bookmarks[$0.path]) }
        self = RecentBinders(entries: [RecentBinder(files: files)] + entries)
    }

    /// Puts `moved` where `binder` is, when its files turn out to be somewhere else now: closing it would otherwise
    /// leave one entry for the old paths and another for the new ones.
    public mutating func replace(_ binder: RecentBinder, with moved: RecentBinder) {
        guard let index = entries.firstIndex(where: { $0.id == binder.id }) else { return }
        var updated = entries
        updated[index] = moved
        self = RecentBinders(entries: updated)
    }

    public mutating func clear() {
        entries = []
    }

    private enum CodingKeys: String, CodingKey { case entries }

    /// What is stored may come from another version or be damaged, so it goes through the rules of `init(entries:)`,
    /// and an entry that cannot be read does not take the others with it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try container.decode([Stored].self, forKey: .entries).compactMap(\.value))
    }

    private struct Stored: Decodable {
        let value: RecentBinder?
        init(from decoder: any Decoder) throws {
            value = try? RecentBinder(from: decoder)
        }
    }
}

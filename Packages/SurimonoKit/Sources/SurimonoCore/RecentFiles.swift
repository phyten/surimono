import Foundation

public struct RecentFile: Codable, Equatable, Sendable {
    public var path: String
    public var bookmark: Data?

    public init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }
}

public struct RecentFiles: Codable, Equatable, Sendable {
    public private(set) var entries: [RecentFile]

    public init(entries: [RecentFile] = []) {
        var seen = Set<String>()
        self.entries = entries.filter { seen.insert($0.path).inserted }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func record(_ file: RecentFile, limit: Int) {
        var file = file
        // A temporary failure to create a bookmark must not discard previously granted access.
        file.bookmark = file.bookmark ?? entries.first(where: { $0.path == file.path })?.bookmark
        self = RecentFiles(entries: [file] + entries)
        trim(to: limit)
    }

    public mutating func trim(to limit: Int) {
        entries = Array(entries.prefix(max(0, limit)))
    }

    public mutating func clear() { entries = [] }

    private enum CodingKeys: String, CodingKey { case entries }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try container.decode([Stored].self, forKey: .entries).compactMap(\.value))
    }

    private struct Stored: Decodable {
        let value: RecentFile?
        init(from decoder: any Decoder) throws { value = try? RecentFile(from: decoder) }
    }
}

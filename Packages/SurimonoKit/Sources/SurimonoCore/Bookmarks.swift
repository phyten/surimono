public struct Bookmarks: Codable, Equatable, Sendable {
    private var positions: [ReadingPosition] = []

    public init() {}
    public var isEmpty: Bool { positions.isEmpty }

    public func pages(pageCount: Int, entries: [OutlineEntry]) -> [Int] {
        guard pageCount > 0 else { return [] }
        return Set(positions.map { $0.page(pageCount: pageCount, entries: entries) }).sorted()
    }

    @discardableResult
    public mutating func toggle(page: Int, visiblePages: [Int], pageCount: Int, entries: [OutlineEntry]) -> Bool {
        guard pageCount > 0, (0..<pageCount).contains(page) else { return false }
        let visible = Set(visiblePages)
        let oldCount = positions.count
        positions.removeAll { visible.contains($0.page(pageCount: pageCount, entries: entries)) }
        guard positions.count == oldCount, positions.count < 99 else { return false }
        let position = ReadingPosition(page: page, pageCount: pageCount, entries: entries)
        guard !positions.contains(where: { $0.page(pageCount: pageCount, entries: entries) == page }) else {
            return false
        }
        positions.append(position)
        return true
    }

    public mutating func remove(page: Int, pageCount: Int, entries: [OutlineEntry]) {
        positions.removeAll { $0.page(pageCount: pageCount, entries: entries) == page }
    }

    public func next(after page: Int, pageCount: Int, entries: [OutlineEntry]) -> Int? {
        pages(pageCount: pageCount, entries: entries).first { $0 > page }
    }

    public func previous(before page: Int, pageCount: Int, entries: [OutlineEntry]) -> Int? {
        pages(pageCount: pageCount, entries: entries).last { $0 < page }
    }

    private enum CodingKeys: String, CodingKey { case positions }

    private struct StoredPosition: Decodable {
        let value: ReadingPosition?
        init(from decoder: any Decoder) throws {
            // A damaged mark must not discard the other places the reader kept.
            value = try? ReadingPosition(from: decoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        positions = Array(try values.decode([StoredPosition].self, forKey: .positions).compactMap(\.value).prefix(99))
    }
}

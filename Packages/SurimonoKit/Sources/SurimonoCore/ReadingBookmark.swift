/// A heading tree independent of PDFKit. Missing levels do not create artificial headings.
public struct ReadingBookmark: Equatable, Sendable {
    public let entry: OutlineEntry
    public var children: [ReadingBookmark]

    public static func tree(from entries: [OutlineEntry]) -> [Self] {
        var index = 0
        func siblings(below level: Int?) -> [Self] {
            var result: [Self] = []
            while index < entries.count {
                let entry = entries[index]
                if let level, entry.level <= level { break }
                index += 1
                result.append(Self(entry: entry, children: siblings(below: entry.level)))
            }
            return result
        }
        return siblings(below: nil)
    }
}

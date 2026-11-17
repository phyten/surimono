import SurimonoCore

struct OutlineFilterState {
    static let minimumHeadings = 8
    private(set) var query = ""
    private(set) var selection: Int?
    private(set) var matches: [Int] = []
    private var navigable: [Int] = []

    static func showsField(count: Int) -> Bool { count >= minimumHeadings }

    mutating func setQuery(_ value: String, entries: [OutlineEntry]) {
        query = value
        reload(entries: entries)
    }

    mutating func reload(entries: [OutlineEntry]) {
        matches = OutlineFilter.matches(in: entries, query: query)
        navigable = matches.filter { entries[$0].pageIndex != nil }
        selection = navigable.first
    }

    mutating func move(by offset: Int) {
        guard let selection, let index = navigable.firstIndex(of: selection) else { return }
        self.selection = navigable[min(max(0, index + offset), navigable.count - 1)]
    }

    mutating func submit(entries: [OutlineEntry]) -> OutlineEntry? {
        guard let selection, entries.indices.contains(selection), entries[selection].pageIndex != nil else {
            return nil
        }
        let entry = entries[selection]
        setQuery("", entries: entries)
        return entry
    }

    mutating func escape(entries: [OutlineEntry]) -> Bool {
        guard !query.isEmpty else { return true }
        setQuery("", entries: entries)
        return false
    }
}

import Foundation

/// The sections of a style menu: a few themes to reach at once, then every built-in theme by category, then the user's
/// own styles. A theme may appear both near the top and in its category.
public struct PrintThemeMenu: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case recent
        case favorites
        case featured
        case category(PrintThemeCategory)
        case user
    }

    public struct Section: Equatable, Sendable {
        public let kind: Kind
        public let themes: [PrintTheme]
    }

    /// How many recently chosen themes the menu keeps.
    public static let recentLimit = 5

    public let sections: [Section]

    /// - Parameters:
    ///   - recentIDs: Recently chosen theme ids, most recent first.
    ///   - favoriteIDs: Favorite theme ids in the order they were added.
    public init(
        themes: [PrintTheme], categories: [PrintThemeCategory], recentIDs: [String], favoriteIDs: [String]
    ) {
        let byID = Dictionary(themes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func resolve(_ ids: [String]) -> [PrintTheme] {
            var seen = Set<String>()
            return ids.compactMap { id in seen.insert(id).inserted ? byID[id] : nil }
        }
        var sections = [
            Section(kind: .recent, themes: Array(resolve(recentIDs).prefix(Self.recentLimit))),
            Section(kind: .favorites, themes: resolve(favoriteIDs)),
            Section(
                kind: .featured,
                themes: themes.compactMap { theme in theme.featuredRank.map { ($0, theme) } }
                    .sorted { $0.0 < $1.0 }.map(\.1)),
        ]
        sections += categories.map { category in
            Section(kind: .category(category), themes: themes.filter { $0.category == category.id })
        }
        sections.append(Section(kind: .user, themes: themes.filter { $0.category == nil }))
        self.sections = sections.filter { !$0.themes.isEmpty }
    }

    /// The recent list after choosing `id`: it moves to the front, and the oldest drop off past the limit.
    public static func recording(_ id: String, in recentIDs: [String]) -> [String] {
        Array(([id] + recentIDs.filter { $0 != id }).prefix(recentLimit))
    }

    /// The favorites after toggling `id`: removed when present, otherwise added at the end.
    public static func toggling(_ id: String, in favoriteIDs: [String]) -> [String] {
        favoriteIDs.contains(id) ? favoriteIDs.filter { $0 != id } : favoriteIDs + [id]
    }
}

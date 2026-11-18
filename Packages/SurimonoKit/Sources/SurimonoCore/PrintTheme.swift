import Foundation

public struct PrintTheme: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let localizedNames: [String: String]
    public let css: String
    public let isBuiltIn: Bool
    /// The catalog category of a built-in theme; user styles have none.
    public let category: String?
    /// Nil denotes a general-purpose style, including user styles that predate format restrictions.
    public let formats: Set<DocumentFormat>?

    public func supports(_ format: DocumentFormat?) -> Bool {
        guard let formats else { return true }
        return format.map(formats.contains) ?? false
    }

    /// The position among the suggested themes, or nil when the theme is not one of them.
    public let featuredRank: Int?
    /// A script the theme decorates the page with before printing, run in the app's isolated world; the document's
    /// own JavaScript stays off.
    public let script: String?

    public init(
        id: String, name: String, localizedNames: [String: String] = [:], css: String, isBuiltIn: Bool = false,
        category: String? = nil, formats: Set<DocumentFormat>? = nil, featuredRank: Int? = nil, script: String? = nil
    ) {
        self.id = id
        self.name = name
        self.localizedNames = localizedNames
        self.css = css
        self.isBuiltIn = isBuiltIn
        self.category = category
        self.formats = formats
        self.featuredRank = featuredRank
        self.script = script
    }

    public func displayName(language: String = "en") -> String {
        UILanguage.name(localizedNames, language: language, english: name)
    }
}

/// A group of built-in themes in the style menus, in the catalog's order.
public struct PrintThemeCategory: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let localizedNames: [String: String]

    public let formats: Set<DocumentFormat>?

    public init(id: String, name: String, localizedNames: [String: String] = [:], formats: Set<DocumentFormat>? = nil) {
        self.formats = formats
        self.id = id
        self.name = name
        self.localizedNames = localizedNames
    }

    public func displayName(language: String = "en") -> String {
        UILanguage.name(localizedNames, language: language, english: name)
    }
}

public enum PrintThemeLibrary {
    enum CatalogError: Error, Equatable {
        case duplicateCategory(String)
        case duplicateTheme(String)
        case duplicateFeaturedTheme(String)
        case unknownCategory(theme: String, category: String)
        case unknownFeaturedTheme(String)
    }

    struct Catalog: Decodable {
        struct Category: Decodable {
            let id: String
            let name: String
            let ja: String?
            let localizedNames: [String: String]?
            let formats: Set<DocumentFormat>?
        }
        struct Theme: Decodable {
            let id: String
            let name: String
            let ja: String?
            let localizedNames: [String: String]?
            let formats: Set<DocumentFormat>?
            let category: String
            let script: String?
        }
        let categories: [Category]
        let featured: [String]
        let themes: [Theme]
    }

    /// The built-in categories in menu order.
    public static func categories() throws -> [PrintThemeCategory] {
        try catalog().categories.map {
            PrintThemeCategory(
                id: $0.id, name: $0.name,
                localizedNames: UILanguage.names(english: $0.name, japanese: $0.ja, localized: $0.localizedNames),
                formats: $0.formats)
        }
    }

    /// Built-in themes in the catalog's order (grouped by category), then the user's styles by name.
    public static func load(userDirectory: URL? = nil) throws -> [PrintTheme] {
        let common = try String(contentsOf: CoreResources.url("common", extension: "css"), encoding: .utf8)
        let catalog = try catalog()
        var scripts: [String: String] = [:]
        let tex = try String(contentsOf: CoreResources.url("latex-typesetting", extension: "css"), encoding: .utf8)
        let builtIns = try catalog.themes.map { entry in
            let groupFormats = catalog.categories.first { $0.id == entry.category }?.formats
            // A theme may narrow its category's formats but cannot widen them.
            let formats = entry.formats.map { own in groupFormats.map(own.intersection) ?? own } ?? groupFormats
            let css = try String(contentsOf: CoreResources.url(entry.id, extension: "css"), encoding: .utf8)
            let script = try entry.script.map { name in
                if let loaded = scripts[name] { return loaded }
                let loaded = try String(contentsOf: CoreResources.url(name, extension: "js"), encoding: .utf8)
                scripts[name] = loaded
                return loaded
            }
            return PrintTheme(
                id: entry.id, name: entry.name,
                localizedNames: UILanguage.names(
                    english: entry.name, japanese: entry.ja, localized: entry.localizedNames),
                css: common + "\n" + (entry.category == "latex" ? tex + "\n" : "") + css, isBuiltIn: true,
                category: entry.category, formats: formats,
                featuredRank: catalog.featured.firstIndex(of: entry.id), script: script)
        }
        let users = try CoreResources.userFiles(in: userDirectory, extension: "css").map { url in
            PrintTheme(
                id: "user:\(url.lastPathComponent)", name: url.deletingPathExtension().lastPathComponent,
                css: common + "\n" + (try String(contentsOf: url, encoding: .utf8)))
        }
        return builtIns + users.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private static func catalog() throws -> Catalog {
        try catalog(from: Data(contentsOf: CoreResources.url("themes", extension: "json")))
    }

    /// Decodes and checks a catalog: every id once, and every reference to a category or a featured theme resolved,
    /// so the menus never show two entries for one id or lose a theme.
    static func catalog(from data: Data) throws -> Catalog {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var categories = Set<String>()
        for category in catalog.categories where !categories.insert(category.id).inserted {
            throw CatalogError.duplicateCategory(category.id)
        }
        var themes = Set<String>()
        for theme in catalog.themes {
            guard themes.insert(theme.id).inserted else { throw CatalogError.duplicateTheme(theme.id) }
            guard categories.contains(theme.category) else {
                throw CatalogError.unknownCategory(theme: theme.id, category: theme.category)
            }
        }
        var featured = Set<String>()
        for id in catalog.featured {
            guard featured.insert(id).inserted else { throw CatalogError.duplicateFeaturedTheme(id) }
            guard themes.contains(id) else { throw CatalogError.unknownFeaturedTheme(id) }
        }
        return catalog
    }
}

enum CoreResources {
    enum ResourceError: Error {
        case missingResource(String)
    }

    static func url(_ name: String, extension suffix: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: suffix) else {
            throw ResourceError.missingResource("\(name).\(suffix)")
        }
        return url
    }

    static func userFiles(in directory: URL?, extension suffix: String) throws -> [URL] {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard url.pathExtension.lowercased() == suffix else { return false }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

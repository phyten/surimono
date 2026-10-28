import Foundation

public struct PrintTheme: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let localizedNames: [String: String]
    public let css: String
    public let isBuiltIn: Bool

    public init(id: String, name: String, localizedNames: [String: String] = [:], css: String, isBuiltIn: Bool = false)
    {
        self.id = id
        self.name = name
        self.localizedNames = localizedNames
        self.css = css
        self.isBuiltIn = isBuiltIn
    }

    public func displayName(language: String = "en") -> String {
        localizedNames[language] ?? localizedNames[String(language.prefix(2))] ?? name
    }
}

public enum PrintThemeLibrary {
    public static func load(userDirectory: URL? = nil) throws -> [PrintTheme] {
        let common = try String(contentsOf: CoreResources.url("common", extension: "css"), encoding: .utf8)
        let definitions = [
            ("standard", "Standard", "標準"), ("mincho", "Mincho", "明朝"),
            ("compact", "Compact", "コンパクト"), ("github", "GitHub-like", "GitHub 風"),
        ]
        var themes = try definitions.map { id, name, japanese in
            let css = try String(contentsOf: CoreResources.url(id, extension: "css"), encoding: .utf8)
            return PrintTheme(
                id: id, name: name, localizedNames: ["en": name, "ja": japanese], css: common + "\n" + css,
                isBuiltIn: true)
        }
        for url in try CoreResources.userFiles(in: userDirectory, extension: "css") {
            themes.append(
                PrintTheme(
                    id: "user:\(url.lastPathComponent)", name: url.deletingPathExtension().lastPathComponent,
                    css: common + "\n" + (try String(contentsOf: url, encoding: .utf8))))
        }
        return themes.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
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

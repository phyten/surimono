import Foundation

/// The programming or configuration language of a text file, told from its name and first line. The document's
/// format stays plain text; the language only chooses the colors.
public struct SourceLanguage: Equatable, Sendable {
    /// A canonical id of `SyntaxHighlighter`.
    public let id: String

    public var displayName: String { SyntaxHighlighter.displayName(for: id) }

    /// Every language a file can be told to be.
    public static let supportedIDs: Set<String> = Set(extensions.values).union(fileNames.values).union(
        interpreters.values
    ).union(["matlab"])

    /// The language of a file: a well-known file name first, then the extension, then the shebang line. nil leaves
    /// the text uncolored.
    public static func detect(fileName: String, firstLine: String? = nil) -> SourceLanguage? {
        var name = fileName.lowercased()
        while true {
            if let id = named(name) { return SourceLanguage(id: id) }
            let suffix = fileExtension(of: name)
            if let id = extensions[suffix] { return SourceLanguage(id: id) }
            if suffix == "m" { return SourceLanguage(id: isMATLAB(firstLine) ? "matlab" : "objectivec") }
            // "config.yaml.example" is a YAML file; the last extension only says what the copy is for.
            guard secondaryExtensions.contains(suffix) else {
                // Prose, logs and the formats with a reader of their own never take colors from a shebang.
                if DocumentFormat(fileExtension: suffix) != nil { return nil }
                break
            }
            name.removeLast(suffix.count + 1)
        }
        return firstLine.flatMap(interpreter).map(SourceLanguage.init)
    }

    /// The first line of a file for `detect`, without its line break or byte order mark. A shebang is ASCII, so the
    /// file's encoding does not matter, and a line longer than any shebang is cut.
    public static func firstLine(of data: Data) -> String {
        var bytes = data.prefix(259)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let line = bytes.prefix(256).prefix { $0 != 0x0A && $0 != 0x0D }
        return String(decoding: line, as: UTF8.self)
    }

    private static func fileExtension(of name: String) -> String {
        // A leading dot starts a hidden file's name, not an extension.
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    private static func named(_ name: String) -> String? {
        if let id = fileNames[name] { return id }
        if name.hasPrefix("dockerfile.") || name.hasPrefix("containerfile.") { return "dockerfile" }
        if name.hasPrefix(".env.") { return "ini" }
        return nil
    }

    // macOS gives `.m` to Objective-C. A MATLAB file starts with a `%` comment or a definition that Objective-C
    // cannot start with.
    private static func isMATLAB(_ firstLine: String?) -> Bool {
        guard let line = firstLine?.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }) else { return false }
        return line.hasPrefix("%") || line.hasPrefix("function ") || line.hasPrefix("classdef ")
    }

    private static func interpreter(_ firstLine: String) -> String? {
        let line = firstLine.drop { $0 == "\u{FEFF}" }
        guard line.hasPrefix("#!") else { return nil }
        var words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" })[...]
        func command(_ word: Substring) -> String { String(word.split(separator: "/").last ?? "") }
        guard let first = words.popFirst() else { return nil }
        var name = command(first)
        if name == "env" {
            // `env -S python3 -u` and `env NAME=value python3` name the interpreter after env's own arguments.
            guard let next = words.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) else { return nil }
            name = command(next)
        }
        // "python3.12" and "lua5.4" are the same language as the bare name.
        while let last = name.last, last.isNumber || last == "." { name.removeLast() }
        return interpreters[name.lowercased()]
    }

    private static func table(_ groups: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for group in groups {
            let names = group.split(separator: " ").map(String.init)
            guard let id = names.first else { continue }
            for name in names.dropFirst() { result[name] = id }
        }
        return result
    }

    // Each row is an id followed by its extensions. `.html`, `.tex`, `.md` and the other formats with a reader of
    // their own are left out, so opening one as text shows it as it was written. `.conf` is left out because the
    // files that carry it share no syntax.
    private static let extensions = table([
        "swift swift", "javascript js jsx mjs cjs", "typescript ts tsx mts cts", "python py pyw pyi",
        "ruby rb rake gemspec ru", "go go", "rust rs", "java java", "kotlin kt kts", "c c h",
        "cpp cpp cc cxx c++ hpp hh hxx h++", "csharp cs", "objectivec mm", "php php", "shell sh bash zsh ksh",
        "json json jsonl ndjson jsonc json5 geojson", "yaml yaml yml", "toml toml", "ini ini cfg properties",
        "html vue svelte", "xml xml plist xsl xslt xsd rss atom entitlements storyboard xib", "css css scss less",
        "sql sql", "dockerfile dockerfile", "makefile mk mak", "diff diff patch", "lua lua", "r r", "julia jl",
        "latex sty cls", "haskell hs",
    ])

    private static let fileNames = table([
        "makefile makefile gnumakefile", "dockerfile dockerfile containerfile",
        "ruby gemfile rakefile podfile fastfile brewfile vagrantfile guardfile",
        "toml cargo.lock poetry.lock uv.lock pipfile",
        "shell .zshrc .bashrc .bash_profile .zprofile .zshenv .zlogin .profile",
        "ini .editorconfig .gitconfig .npmrc .env",
    ])

    private static let interpreters = table([
        "shell sh bash zsh ksh dash ash", "python python pypy", "ruby ruby", "javascript node nodejs",
        "typescript deno bun ts-node tsx", "php php", "lua lua luajit", "r rscript", "julia julia", "swift swift",
        "haskell runhaskell runghc", "makefile make gmake",
    ])

    private static let secondaryExtensions: Set<String> = [
        "example", "sample", "dist", "default", "template", "bak", "orig", "in",
    ]
}

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

    /// Every extension that tells a language, for what registers the files that can be opened.
    public static let fileExtensions: Set<String> = Set(extensions.keys).union(["m"])

    /// A shebang longer than this is not read to its end.
    private static let firstLineLimit = 256

    /// The language of a file: a well-known file name first, then the extension, then a name derived from a
    /// well-known one ("Dockerfile.dev"), then the shebang line. nil leaves the text uncolored.
    public static func detect(fileName: String, firstLine: String? = nil) -> SourceLanguage? {
        detect(fileName: fileName, line: { firstLine })
    }

    /// The same, for the decoded text of the file. What draws the text and what names its language both come here,
    /// so they cannot disagree. The text is read only when the name does not settle the language.
    public static func detect(fileName: String, text: () -> String?) -> SourceLanguage? {
        detect(
            fileName: fileName,
            line: { text().map { String($0.prefix(firstLineLimit + 1).prefix { !$0.isNewline }) } })
    }

    private static func detect(fileName: String, line: () -> String?) -> SourceLanguage? {
        var original = fileName
        while true {
            let name = original.lowercased()
            if let id = fileNames[name] { return SourceLanguage(id: id) }
            let suffix = fileExtension(of: name)
            // "config.yaml.example" is a YAML file; the last extension only says what the copy is for.
            if secondaryExtensions.contains(suffix) {
                original.removeLast(suffix.count + 1)
                continue
            }
            // Only the capital letter tells C++'s `.C` and `.H` from C's.
            if ["C", "H"].contains(fileExtension(of: original)) { return SourceLanguage(id: "cpp") }
            if let id = extensions[suffix] { return SourceLanguage(id: id) }
            if suffix == "m" { return SourceLanguage(id: isMATLAB(line()) ? "matlab" : "objectivec") }
            // Prose, logs and the formats with a reader of their own never take colors from the beginning of
            // their name or from a shebang.
            if DocumentFormat(fileExtension: suffix) != nil { return nil }
            if name.hasPrefix("dockerfile.") || name.hasPrefix("containerfile.") {
                return SourceLanguage(id: "dockerfile")
            }
            if name.hasPrefix(".env.") { return SourceLanguage(id: "ini") }
            return line().flatMap(interpreter).map(SourceLanguage.init)
        }
    }

    private static func fileExtension(of name: String) -> String {
        // A leading dot starts a hidden file's name, not an extension.
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    // macOS gives `.m` to Objective-C. A MATLAB file starts with a `%` comment or a definition that Objective-C
    // cannot start with.
    private static func isMATLAB(_ firstLine: String?) -> Bool {
        guard let line = firstLine?.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }) else { return false }
        if line.hasPrefix("%") { return true }
        let word = line.prefix { !$0.isWhitespace }
        return (word == "function" || word == "classdef") && word.endIndex < line.endIndex
    }

    private struct Word {
        var text: String
        /// Where the word ends in the line, to tell a word the length limit may have cut.
        var end: String.Index
    }

    /// The words of a shebang line, with quotations as `env -S` reads them. nil when a quotation is left open.
    private static func words(of line: Substring) -> [Word]? {
        var result: [Word] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                if inWord { result.append(Word(text: current, end: index)) }
                current = ""
                inWord = false
            } else {
                current.append(character)
                inWord = true
            }
            index = line.index(after: index)
        }
        guard quote == nil else { return nil }
        if inWord { result.append(Word(text: current, end: line.endIndex)) }
        return result
    }

    private static func interpreter(_ firstLine: String) -> String? {
        let whole = firstLine.drop { $0 == "\u{FEFF}" }
        guard whole.hasPrefix("#!") else { return nil }
        let line = whole.prefix(firstLineLimit)
        guard var words = words(of: line.dropFirst(2))?[...], let first = words.popFirst() else { return nil }
        var command = first
        if first.text.split(separator: "/").last == "env" {
            guard let next = environmentCommand(&words) else { return nil }
            command = next
        }
        // A name the limit may have cut short is not a name to go by.
        if whole.count > firstLineLimit, command.end == line.endIndex { return nil }
        var name = String(command.text.split(separator: "/").last ?? "")
        // "python3.12" and "lua5.4" are the same language as the bare name.
        while let last = name.last, last.isNumber || last == "." { name.removeLast() }
        return interpreters[name.lowercased()]
    }

    /// The command `env` runs, after its options and `NAME=value` settings. `-u`, `-C` and `-P` take a value, which
    /// is not the command: in `env -S -u ruby python3` the interpreter is python3.
    private static func environmentCommand(_ words: inout ArraySlice<Word>) -> Word? {
        while let word = words.popFirst() {
            // A quoted string after `-S` is split again into the command and its arguments.
            let pieces = word.text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if pieces.count > 1 {
                // `"NAME=a b"` is one setting whose value has a space.
                if let first = pieces.first, !first.hasPrefix("-"), first.contains("=") { continue }
                words = (pieces.map { Word(text: String($0), end: word.end) } + words)[...]
                continue
            }
            let text = word.text
            if text == "--" { return words.first }
            if text.hasPrefix("--") {
                if text == "--unset" || text == "--chdir" { _ = words.popFirst() }
                let split = "--split-string="
                if text.hasPrefix(split), text.count > split.count {
                    return Word(text: String(text.dropFirst(split.count)), end: word.end)
                }
                continue
            }
            if text.hasPrefix("-"), text.count > 1 {
                var flags = text.dropFirst()
                while let flag = flags.popFirst() {
                    if flag == "S" {
                        // The rest of the cluster already starts the command line `-S` splits.
                        if !flags.isEmpty { return Word(text: String(flags), end: word.end) }
                    } else if "uCP".contains(flag) {
                        if flags.isEmpty { _ = words.popFirst() }
                        break
                    }
                }
                continue
            }
            if text.contains("=") { continue }
            return word
        }
        return nil
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
    // their own are left out, so opening one as text shows it as it was written. `.conf` and `.cfg` are left out
    // because the files that carry them share no syntax; the names known to be INI are in `fileNames`. `.h` is C
    // although C++ and Objective-C headers carry it too, and `.r` is R although macOS gives it to Rez.
    private static let extensions = table([
        "swift swift", "javascript js jsx mjs cjs", "typescript ts tsx mts cts", "python py pyw pyi",
        "ruby rb rake gemspec ru", "go go", "rust rs", "java java", "kotlin kt kts", "c c h",
        "cpp cpp cc cxx c++ hpp hh hxx h++", "csharp cs", "objectivec mm", "php php", "shell sh bash zsh ksh",
        "json json jsonl ndjson jsonc json5 geojson", "yaml yaml yml", "toml toml", "ini ini properties",
        "html vue svelte", "xml xml plist xsl xslt xsd rss atom entitlements storyboard xib", "css css scss less",
        "sql sql", "dockerfile dockerfile", "makefile mk mak", "diff diff patch", "lua lua", "r r", "julia jl",
        "latex sty cls", "haskell hs",
    ])

    private static let fileNames = table([
        "makefile makefile gnumakefile", "dockerfile dockerfile containerfile",
        "ruby gemfile rakefile podfile fastfile brewfile vagrantfile guardfile",
        "toml cargo.lock poetry.lock uv.lock pipfile",
        "shell .zshrc .bashrc .bash_profile .zprofile .zshenv .zlogin .profile",
        "ini .editorconfig .gitconfig .npmrc .env setup.cfg .flake8 .coveragerc .pylintrc",
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

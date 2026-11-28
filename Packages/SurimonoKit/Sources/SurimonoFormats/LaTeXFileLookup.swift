import Foundation

/// Where TeX would look for a file a document names, in the order it would look. Every input, bibliography,
/// listing and image the reader finds comes from here, and every read goes through the host's `readFile` or
/// `imageExists`, which confine it to the folders the document may read.
enum LaTeXFileLookup {
    enum Kind {
        /// `\input`, `\subfile`, `\import`. Kpathsea tries `name.tex` first unless the name ends in a suffix TeX
        /// knows, then the name as written, so `\input{1.intro}` reads `1.intro.tex`.
        case input
        /// `\include` always adds `.tex`.
        case include
        /// `\bibliography`, `\addbibresource` and a Markdown `bibliography`: BibTeX adds `.bib` the same way.
        case bibliography
        /// `\lstinputlisting` and `\inputminted` read the name as written.
        case listing
        /// `\includegraphics`: graphicx tries its extensions unless the name ends in one of them.
        case graphic
    }

    /// Suffixes Kpathsea's tex format searches as written.
    private static let texSuffixes: Set<String> = ["tex", "sty", "cls", "fd", "aux", "bbl", "def", "clo", "ldf", "ltx"]
    /// The ones tried, in order, for a name without one of `graphicSuffixes`.
    static let graphicExtensions = ["pdf", "png", "jpg", "jpeg", "svg", "gif"]
    /// Image suffixes graphicx takes as written, including those Surimono cannot draw.
    private static let graphicSuffixes = Set(
        graphicExtensions + ["eps", "ps", "mps", "jbig2", "jb2", "bmp", "tif", "tiff"])

    /// The names to try, or nil for one that is not a local file: empty, absolute, home-relative, a URL or with NUL.
    static func names(_ raw: String, kind: Kind) -> [String]? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("~"), !name.contains("\0"),
            URLComponents(string: name)?.scheme == nil
        else { return nil }
        let suffix = (name as NSString).pathExtension.lowercased()
        switch kind {
        case .input: return texSuffixes.contains(suffix) ? [name] : [name + ".tex", name]
        case .include: return suffix == "tex" ? [name] : [name + ".tex"]
        case .bibliography: return suffix == "bib" ? [name] : [name + ".bib", name]
        case .listing: return [name]
        case .graphic:
            if graphicSuffixes.contains(suffix) { return [name] }
            return graphicExtensions.map { name + "." + $0 } + (suffix.isEmpty ? [] : [name])
        }
    }

    /// Each name in each folder, then the main folder read as the folder a manuscript was compiled from. arXiv
    /// compiles from the top of the upload, so a main file in `latex/` names `latex/intro`; that is `intro` in the
    /// main file's own folder. Only a leading run of the main folder's own names is taken off, so no candidate
    /// leaves the folders searched.
    static func candidates(_ names: [String], in folders: [URL], mainFolder main: URL?) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        func add(_ url: URL) {
            let url = url.standardizedFileURL
            if seen.insert(url).inserted { result.append(url) }
        }
        for folder in folders {
            for name in names { add(folder.appending(path: name)) }
        }
        guard let main else { return result }
        let own = main.standardizedFileURL.pathComponents.dropFirst()
        for name in names {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count > 1, !parts.contains(".."), !parts.contains("."), !parts.contains("") else { continue }
            for count in stride(from: min(own.count, parts.count - 1), through: 1, by: -1)
            where Array(own.suffix(count)) == Array(parts.prefix(count)) {
                add(main.appending(path: parts.dropFirst(count).joined(separator: "/")))
            }
        }
        return result
    }
}

extension LaTeXDocument {
    /// The places to look for a named file, in order.
    func lookupCandidates(_ names: [String]) -> [URL] {
        LaTeXFileLookup.candidates(names, in: searchDirectories, mainFolder: directory)
    }
}

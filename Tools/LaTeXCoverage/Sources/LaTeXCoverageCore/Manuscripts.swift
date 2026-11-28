import Foundation

/// One paper of a corpus: the folder it was unpacked into and the file TeX compiles.
public struct Manuscript: Codable, Equatable, Sendable {
    public var id: String
    /// Relative to the corpus folder.
    public var folder: String
    /// Relative to `folder`.
    public var main: String
    public var group: String?
    public var year: Int?

    public init(id: String, folder: String, main: String, group: String? = nil, year: Int? = nil) {
        self.id = id
        self.folder = folder
        self.main = main
        self.group = group
        self.year = year
    }
}

public enum Manuscripts {
    /// The papers of a corpus. A manifest fixes them: either the coverage tool's own (an array of `Manuscript`) or
    /// one keyed by paper id with `main`, `group`, `year` and `status` (papers whose status is not `tex` are left
    /// out), each in `<corpus>/src/<id>` or `<corpus>/<id>`. Without one, each subfolder that holds a main file is a
    /// paper, and a corpus folder holding no such subfolder is one paper itself.
    public static func list(corpus: URL, manifest: URL?) throws -> [Manuscript] {
        let candidates = [manifest, corpus.appending(path: "manifest.json")].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try read(manifest: url, corpus: corpus)
        }
        return discover(corpus: corpus)
    }

    static func read(manifest url: URL, corpus: URL) throws -> [Manuscript] {
        let data = try Data(contentsOf: url)
        if let list = try? JSONDecoder().decode([Manuscript].self, from: data) { return list }
        struct Entry: Decodable {
            var main: String?
            var group: String?
            var year: Int?
            var status: String?
        }
        let entries = try JSONDecoder().decode([String: Entry].self, from: data)
        let source = corpus.appending(path: "src")
        let nested = FileManager.default.fileExists(atPath: source.path)
        return entries.compactMap { id, entry in
            guard entry.status == nil || entry.status == "tex", let main = entry.main else { return nil }
            let folder = id.replacingOccurrences(of: "/", with: "_")
            return Manuscript(
                id: id, folder: nested ? "src/" + folder : folder, main: main, group: entry.group, year: entry.year)
        }.sorted { ($0.group ?? "", $0.year ?? 0, $0.id) < ($1.group ?? "", $1.year ?? 0, $1.id) }
    }

    static func discover(corpus: URL) -> [Manuscript] {
        let folders =
            ((try? FileManager.default.contentsOfDirectory(
                at: corpus, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let papers = folders.compactMap { folder in
            mainFile(in: folder).map {
                Manuscript(id: folder.lastPathComponent, folder: folder.lastPathComponent, main: $0)
            }
        }
        if papers.isEmpty, let main = mainFile(in: corpus) {
            return [Manuscript(id: corpus.lastPathComponent, folder: ".", main: main)]
        }
        return papers
    }

    /// The file TeX would be run on: one with `\documentclass` on an uncommented line, preferring one that also
    /// begins the document, then the largest, then the first path. A file that only inputs another (an arXiv entry
    /// point) has no class, so the file it inputs is chosen, as the reader opens it.
    public static func mainFile(in folder: URL) -> String? {
        guard
            let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        var best: (begins: Bool, size: Int, path: String)?
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for case let url as URL in walker {
            guard ["tex", "ltx", "latex"].contains(url.pathExtension.lowercased()),
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                let data = try? Data(contentsOf: url)
            else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard hasUncommented(#"\documentclass"#, in: text) else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { continue }
            let candidate = (
                hasUncommented(#"\begin{document}"#, in: text), data.count, String(path.dropFirst(base.count))
            )
            if let current = best {
                let better =
                    candidate.0 != current.begins
                    ? candidate.0
                    : candidate.1 != current.size ? candidate.1 > current.size : candidate.2 < current.path
                if !better { continue }
            }
            best = (candidate.0, candidate.1, candidate.2)
        }
        return best?.path
    }

    static func hasUncommented(_ command: String, in text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let range = line.range(of: command) else { continue }
            var escaped = false
            var commented = false
            for character in line[..<range.lowerBound] {
                if character == "%" && !escaped { commented = true }
                escaped = character == "\\" && !escaped
            }
            if !commented { return true }
        }
        return false
    }
}

import Foundation

extension LaTeXDocument {
    /// An imported chapter first sees its own siblings, then the enclosing inputs and the main document.
    var searchDirectories: [URL] {
        var seen = Set<URL>()
        return (inputChain.reversed().map { $0.deletingLastPathComponent() } + [directory].compactMap { $0 })
            .filter { seen.insert($0.standardizedFileURL).inserted }
    }

    func resourceSource(_ url: URL, relativeTo directory: URL) -> String {
        let root = directory.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        let shared = zip(root, path).prefix(while: { $0 == $1 }).count
        let relative = Array(repeating: "..", count: root.count - shared) + path.dropFirst(shared)
        var parts = URLComponents()
        parts.path = relative.joined(separator: "/")
        return parts.percentEncodedPath
    }

    func reportFileIssue(_ issue: String) {
        if seenFileIssues.insert(issue).inserted { fileIssues.append(issue) }
    }
}

extension LaTeXReader {
    private static func localName(_ raw: String, defaultExtension: String? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("~"), !name.contains("\0"),
            URLComponents(string: name)?.scheme == nil
        else { return nil }
        if let defaultExtension, (name as NSString).pathExtension.isEmpty { return name + "." + defaultExtension }
        return name
    }

    /// Charge raw input before interpreting it. A file can be referenced repeatedly through macros or several
    /// branches, so the allowance belongs to the document, including bibliography and verbatim listings.
    private func localText(_ path: String, defaultExtension: String?, asInput: Bool) -> (URL, String)? {
        guard let name = Self.localName(path, defaultExtension: defaultExtension),
            document.reserveExpansion()
        else { return nil }
        for base in document.searchDirectories {
            let url = base.appending(path: name).standardizedFileURL
            if asInput {
                let identity = document.fileIdentity(url)
                if (document.inputChain + [document.mainURL].compactMap { $0 }).contains(where: {
                    document.fileIdentity($0) == identity
                }) {
                    return nil
                }
            }
            guard let data = document.readFile(url) else { continue }
            // Four bytes per scalar covers UTF-8/32. Reject larger buffers before decoding or allocating tokens.
            guard data.count <= 4 * (2_000_000 - document.expandedCharacters) + 4 else {
                document.stopsExpanding = true
                return nil
            }
            let text = TextDecoding.decode(data).text
            guard document.reserveExpansion(characters: text.unicodeScalars.count) else { return nil }
            return (url, text)
        }
        return nil
    }

    func readLocalText(_ path: String, defaultExtension: String? = nil) -> String? {
        localText(path, defaultExtension: defaultExtension, asInput: false)?.1
    }

    func fileNote(_ path: String) -> String {
        let message = document.isJapanese ? "ファイル \(path) を読み込めません" : "\(path) could not be read"
        document.reportFileIssue(message)
        return unsupported(message)
    }

    func keepFileNote(_ html: String) {
        if inPreamble {
            document.preambleFileNotes += html
        } else {
            appendBlock(html)
        }
    }

    func retireFileFrames() {
        while let frame = fileFrames.last, characters.count - index <= frame.tail {
            document.inputChain.removeLast(document.inputChain.count - frame.chainDepth)
            fileFrames.removeLast()
        }
    }

    func handleFileCommand(_ name: String) -> Bool {
        switch name {
        case "includeonly":
            document.includeOnly = Set(
                (argument() ?? "").split(separator: ",").compactMap {
                    Self.localName(String($0), defaultExtension: "tex")
                })
        case "input", "include", "subfile", "import":
            var path = argument() ?? ""
            if name == "import" {
                let file = argument() ?? ""
                path = path.isEmpty || path.hasSuffix("/") ? path + file : path + "/" + file
            }
            let filename = Self.localName(path, defaultExtension: "tex") ?? path
            if name == "include", let only = document.includeOnly, !only.contains(filename) { return true }
            guard document.inputChain.count < 20,
                let (url, source) = localText(path, defaultExtension: "tex", asInput: true)
            else {
                keepFileNote(fileNote(filename))
                return true
            }
            if name == "include" { appendBlock("<div class=\"latex-pagebreak\"></div>\n") }
            let body = name == "subfile" ? subfileBody(source) : source
            // Splicing lets a command or an environment in the input take its remaining tokens from its caller.
            // TeX terminates the last input line even if the file has no final newline. In particular, a
            // trailing comment must not swallow the caller's next command.
            let needsNewline = !body.isEmpty && !body.hasSuffix("\n")
            let remaining = characters.count - index
            let cost = body.utf8.count + remaining
            guard cost <= 50_000_000 - document.expansionWork else {
                document.stopsExpanding = true
                return true
            }
            document.expansionWork += cost
            fileFrames.append((remaining, document.inputChain.count))
            document.inputChain.append(url)
            characters.insert(contentsOf: needsNewline ? body + "\n" : body, at: index)
        case "tikzexternalize":
            for item in (optional() ?? "").split(separator: ",") {
                let pair = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, pair[0] == "prefix" {
                    document.picturePrefix = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                }
            }
        case "tikzsetnextfilename": document.nextPictureName = argument()
        default: return false
        }
        return true
    }

    /// A subfiles chapter can also be a standalone document. Its private preamble and end marker belong only
    /// to that standalone run. Skip quoted boundaries inside definitions, comments and verbatim examples.
    private func subfileBody(_ source: String) -> String {
        let scanner = LaTeXReader(source, document: document, isBlock: false)
        while let next = scanner.peek() {
            if let end = LaTeXLexer.opaqueEnd(scanner.characters, at: scanner.index) {
                scanner.index = end
            } else if next == "{" {
                _ = scanner.argument()
            } else if next == "\\" {
                if scanner.controlToken() == "\\begin", scanner.argument() == "document" {
                    return scanner.environmentBody("document")
                }
            } else {
                scanner.index += 1
            }
        }
        return source
    }

    func externalPicture() -> String {
        // PGF numbers pictures, not successful lookups; even a named or missing figure consumes its slot.
        let index = document.pictureIndex
        document.pictureIndex += 1
        let explicit = document.nextPictureName
        document.nextPictureName = nil
        let job = document.mainURL?.deletingPathExtension().lastPathComponent
        let lookupCost = document.picturePrefix.utf8.count + (explicit?.utf8.count ?? 0) + (job?.utf8.count ?? 0)
        guard document.reserveExpansion(characters: lookupCost) else { return missingPicture() }
        let automatic = job.map { "\($0)-figure\(index)" }
        var candidates: [String] = []
        func addVariants(_ stem: String) {
            if ["pdf", "png", "svg"].contains((stem as NSString).pathExtension.lowercased()) {
                candidates.append(stem)
            } else {
                candidates += ["pdf", "png", "svg"].map { stem + "." + $0 }
            }
        }
        if let explicit {
            addVariants(document.picturePrefix + explicit)
            if !document.picturePrefix.isEmpty { addVariants(explicit) }
        }
        if let automatic {
            addVariants(document.picturePrefix + automatic)
            candidates.append(automatic + ".pdf")
        }
        if let directory = document.directory {
            for candidate in candidates {
                guard let name = Self.localName(candidate) else { continue }
                let url = directory.appending(path: name)
                guard document.imageExists(url) else { continue }
                if let date = document.modificationDate(url),
                    [document.mainURL, document.inputChain.last].compactMap({ $0 }).contains(where: {
                        document.modificationDate($0).map { date < $0 } == true
                    })
                {
                    document.reportFileIssue(
                        document.isJapanese ? "図 \(name) は古い可能性があります" : "Figure \(name) may be out of date")
                }
                let src = document.resourceSource(url, relativeTo: directory)
                return "<img class=\"latex-graphic\" src=\"\(HTML.escape(src))\" alt=\"\">\n"
            }
        }
        return missingPicture()
    }

    private func missingPicture() -> String {
        let hint = #"\usetikzlibrary{external}\tikzexternalize"#
        document.reportFileIssue(
            document.isJapanese
                ? "外部化した図が見つかりません。\(hint) で図を保存できます。"
                : "Externalized picture not found. Generate it with \(hint).")
        return unsupported(
            document.isJapanese ? "TikZ などの図（Surimono では描けません）" : "TikZ picture (Surimono cannot draw it)")
    }
}

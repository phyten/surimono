import Foundation

public enum MediaWikiConverter {
    /// The callbacks run on the converter's own thread while the caller waits for it (`StackSpace.onLargeStack`):
    /// they must not need the caller's thread or actor, and do not see its task-local values.
    public static func convert(
        _ source: String, directory: URL? = nil, contentsDepth: Int = 3,
        imageExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> HTMLFragment {
        // On a stack of known size, so a document reads the same on every thread.
        StackSpace.onLargeStack {
            convertInPlace(source, directory: directory, contentsDepth: contentsDepth, imageExists: imageExists)
        }
    }

    private static func convertInPlace(
        _ source: String, directory: URL?, contentsDepth: Int, imageExists: @escaping (URL) -> Bool
    )
        -> HTMLFragment
    {
        guard source.utf8.count <= DocumentSizeLimits.markupReaderBytes else {
            let message = String(localized: "MediaWiki exceeds 5 MB. Showing the original text.")
            return HTMLFragment(body: "<p>\(HTML.escape(message))</p>" + PlainTextConverter.convert(source).body)
        }
        let reader = WikiReader(directory: directory, imageExists: imageExists)
        return reader.document(TextDecoding.normalizeNewlines(source), contentsDepth: contentsDepth)
    }

    package static func detects(_ text: String) -> Bool {
        let sample = String(text.prefix(8192))
        guard !sample.contains("```"), !sample.contains("~~~"), !sample.contains("#+"),
            !sample.hasPrefix(":doctype:")
        else { return false }
        let signals = [
            #"(?m)^(={1,6})(?!=)[^\n=][^\n]*?(?<![=])\1[ \t]*$"#,
            #"\[\[[^\[\]\n]+\]\]"#, #"\{\{[^{}\n]+\}\}"#,
            #"(?ms)^\{\|[^\n]*\n.*?^\|-"#, #"'''[^'\n]+'''"#, #"<ref(?:\s|>)"#,
        ]
        // A Markdown code example or an HTML comment contributes no evidence about the surrounding document.
        let visible = sample.replacingOccurrences(
            of: #"`[^`\n]*`|(?s:<!--.*?-->)"#, with: " ", options: .regularExpression)
        return signals.filter { visible.range(of: $0, options: .regularExpression) != nil }.count >= 2
    }
}

extension String {
    fileprivate var wikiPlain: String {
        HTML.unescape(replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
    }
    var wikiTrim: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

final class WikiReader {
    struct Atom {
        let kind: String
        let body: String
        var attrs: [String: String] = [:]
    }
    let directory: URL?
    let imageExists: (URL) -> Bool
    var adjacentNames: [String: String]?
    var atoms: [Atom] = []
    var anchors: [MarkdownExtensions.HeadingAnchor] = []
    var headingIDs: Set<String> = []
    var counts: [String: Int] = [:]
    var title: String?
    var japanese = false
    var categories: [String] = []
    var categorySet: Set<String> = []
    var external = 0
    var references = WikiReferences()
    let nonce = UUID().uuidString
    private var escapedMarker: String { "\u{E004}" + nonce + "\u{E005}" }
    var referencePlaces: [String] = []
    var deferred: [() -> String] = []
    var hideTOC = false
    var explicitTOC = false
    var forceTOC = false
    var depth = 0
    /// Whether some text stayed unread because it nested deeper than the stack allows.
    var reachedNestingLimit = false

    init(directory: URL?, imageExists: @escaping (URL) -> Bool) {
        self.directory = directory
        self.imageExists = imageExists
    }

    func atom(_ kind: String, _ body: String, _ attrs: [String: String] = [:]) -> String {
        atoms.append(Atom(kind: kind, body: body, attrs: attrs))
        return "\u{E000}\(atoms.count - 1)\u{E001}"
    }

    func later(_ produce: @escaping () -> String) -> String {
        deferred.append(produce)
        return "\u{E002}\(nonce)\(deferred.count - 1)\u{E003}"
    }

    func document(_ source: String, contentsDepth: Int) -> HTMLFragment {
        japanese = source.prefix(8192).range(of: #"[ぁ-ヿ]"#, options: .regularExpression) != nil
        // Keep literal private-use characters, including inside nowiki, distinct from parser tokens.
        let hasMarker = source.contains("\u{E000}")
        let prepared = tokenize(hasMarker ? source.replacingOccurrences(of: "\u{E000}", with: escapedMarker) : source)
        var result = blocks(prepared)
        if forceTOC && !hideTOC && !explicitTOC,
            let first = result.range(of: #"<h[1-6] id=""#, options: .regularExpression)
        {
            result.insert(
                contentsOf: ReaderContentsKind.lead.mark(
                    MarkdownExtensions.tableOfContents(anchors, levels: contentsDepth)),
                at: first.lowerBound)
        }
        result += references.remainder()
        if !categories.isEmpty {
            result +=
                "<p class=\"wiki-categories\"><small>\(japanese ? "カテゴリ" : "Categories"): "
                + categories.map(HTML.escape).joined(separator: " · ") + "</small></p>"
        }
        if !referencePlaces.isEmpty {
            result = WikiPattern("\u{E002}" + nonce + "r([0-9]+)\u{E003}").replace(result) { parts in
                guard let i = Int(parts[1]), referencePlaces.indices.contains(i) else { return "" }
                return references.list(referencePlaces[i])
            }
        }
        let marker = "\u{E002}" + nonce
        if !deferred.isEmpty {
            result = WikiPattern(marker + "([0-9]+)\u{E003}").replace(result) { parts in
                guard let index = Int(parts[1]), deferred.indices.contains(index) else { return "" }
                return deferred[index]()
            }
            deferred.removeAll()
        }
        if hasMarker {
            result = result.replacingOccurrences(of: escapedMarker, with: "\u{E000}")
            title = title?.replacingOccurrences(of: escapedMarker, with: "\u{E000}")
        }
        let fonts = MathRenderer.fontFaces(for: result)
        var fragment = HTMLFragment(
            body: result + (fonts.isEmpty ? "" : "<style>\(fonts)</style>"), title: title,
            readingIssues: reachedNestingLimit ? [StackSpace.limitIssue] : []
        ).recordingContents(
            .init(
                present: hideTOC ? .init(false) : (forceTOC ? .init(true) : nil)))
        fragment.coalescesContentsInLegacy = forceTOC && explicitTOC && !hideTOC
        return fragment
    }

    func heading(_ level: Int, _ source: String) -> String {
        let content = inline(source)
        let text = content.replacingOccurrences(
            of: "\u{E002}" + nonce + "[0-9]+\u{E003}", with: "", options: .regularExpression
        ).wikiPlain.replacingOccurrences(of: escapedMarker, with: "\u{E000}")
        let slug = MarkdownExtensions.slug(text)
        let base = slug.isEmpty ? "section" : slug
        var id = base
        while !headingIDs.insert(id).inserted {
            counts[base, default: 0] += 1
            id = "\(base)-\(counts[base, default: 0])"
        }
        anchors.append(.init(level: level, id: id, text: text))
        if title == nil, level == 1 { title = text }
        return "<h\(level) id=\"\(id)\">\(content)</h\(level)>"
    }
}

// ICU offsets stay in UTF-16 throughout a pass, including when the page contains non-ASCII text.
struct WikiPattern {
    let regex: NSRegularExpression?
    init(_ pattern: String) { regex = try? NSRegularExpression(pattern: pattern) }

    func replace(_ input: String, plain: (String) -> String = { $0 }, _ transform: ([String]) -> String) -> String {
        let source = input as NSString
        var output = ""
        var cursor = 0
        for match in regex?.matches(in: input, range: NSRange(location: 0, length: source.length)) ?? [] {
            output += plain(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            output += transform(
                (0..<match.numberOfRanges).map {
                    let range = match.range(at: $0)
                    return range.location == NSNotFound ? "" : source.substring(with: range)
                })
            cursor = NSMaxRange(match.range)
        }
        return output + plain(source.substring(from: cursor))
    }
}

import Foundation

public enum RSTConverter {
    /// Begins a reading issue that names a file a directive asked for and the reader could not read.
    public static let unreadableFileIssuePrefix = "unreadable-file:"

    /// The root directory is the source file's directory. The caller may further restrict file access.
    /// The callbacks run on the converter's own thread while the caller waits for it (`StackSpace.onLargeStack`):
    /// they must not need the caller's thread or actor, and do not see its task-local values.
    public static func convert(
        _ source: String, directory: URL? = nil, reading: FormatReadingSettings = .init(),
        permitsFile: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) -> HTMLFragment {
        convert(
            source, directory: directory, readsIncludes: true, reading: reading, permitsFile: permitsFile)
    }

    package static func convert(
        _ source: String, directory: URL?, readsIncludes: Bool, reading: FormatReadingSettings = .init(),
        permitsFile: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) -> HTMLFragment {
        // On a stack of known size, so a document reads the same on every thread.
        StackSpace.onLargeStack {
            convertInPlace(
                source, directory: directory, readsIncludes: readsIncludes, reading: reading,
                permitsFile: permitsFile)
        }
    }

    private static func convertInPlace(
        _ source: String, directory: URL?, readsIncludes: Bool, reading: FormatReadingSettings,
        permitsFile: @escaping (URL) -> Bool
    )
        -> HTMLFragment
    {
        let document = RSTDocument(directory: directory, readsIncludes: readsIncludes, permitsFile: permitsFile)
        var normalized = TextDecoding.normalizeNewlines(source)
        if normalized.first == "\u{feff}" { normalized.removeFirst() }
        var lines: [String] = []
        document.sourceLines = normalized.components(separatedBy: "\n")[...]
        for line in document.sourceLines {
            if PreviewConversion.expired { return HTMLFragment(body: "") }
            lines.append(RSTDocument.expandTabs(line))
        }
        document.japanese =
            DocumentLanguage.primary(
                DocumentLanguage.detect(html: HTML.escape(String(normalized.prefix(20_000))), fallback: "en").code)
            == "ja"
        let body = document.blocks(lines)
        if PreviewConversion.expired { return HTMLFragment(body: "") }
        document.finishHeadingText()
        let directive = document.directives.lead
        let lead = reading.keepsRSTLeadInText ? nil : directive
        let options = reading.resolve(
            for: .rst, numbers: document.directives.numbers, contents: lead?.instructions ?? .init(), contentsDepth: nil
        )
        let html = document.finishReferences(document.finishDirectives(body, options: options, leadID: lead?.id))
        let fonts = MathRenderer.fontFaces(for: html)
        var fragment = HTMLFragment(
            body: html + (fonts.isEmpty ? "" : "<style>\(fonts)</style>"), title: document.title,
            readingIssues: (document.issueCount > 0 ? [String(document.issueCount)] : [])
                + document.unreadableFiles.map { unreadableFileIssuePrefix + $0 },
            decidesHeadingNumbers: options.ownsNumbers
        ).recordingContents(directive?.instructions ?? .init())
        fragment.numberInstructions = document.directives.numbers
        fragment.contentsTitle = lead.flatMap { $0.label.isEmpty ? nil : $0.label }
        fragment.inTextContentsMarker = document.directives.contents.first(where: { $0.id != directive?.id }).map {
            $0.local ? ":local:" : ($0.instructions.present?.source?.rawText ?? ".. contents::")
        }
        return lead == nil ? fragment.addingLeadContents(depth: options.lead) : fragment
    }
}

final class RSTDocument {
    let directory: URL?
    let permitsFile: (URL) -> Bool
    let readsIncludes: Bool
    var references = RSTReferences()
    var directives = RSTDirectiveState()
    var sourceLines: ArraySlice<String> = []
    weak var blockReader: RSTBlockReader?
    var anchors: [MarkdownExtensions.HeadingAnchor] = []
    var title: String?
    var promotedHeadingIDs: Set<String> = []
    var issueCount = 0
    /// Files named by a directive that could not be read, missing or outside the permitted folder.
    var unreadableFiles: [String] = []
    var japanese = false
    private var adornments: [String: Int] = [:]
    var depth = 0

    init(directory: URL?, readsIncludes: Bool = true, permitsFile: @escaping (URL) -> Bool) {
        // Anchor all later relative reads to the directory identified when conversion starts.
        self.directory = directory.flatMap { url in
            guard url.isFileURL, let path = try? ConfinedFile.canonicalPath(url) else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        self.readsIncludes = readsIncludes
        self.permitsFile = permitsFile
    }

    static func expandTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var result = ""
        var column = 0
        for character in line {
            if character == "\t" {
                let count = 8 - column % 8
                result += String(repeating: " ", count: count)
                column += count
            } else {
                result.append(character)
                column += 1
            }
        }
        return result
    }

    struct Attributes {
        var classes: [String]
        var targets: [String]
    }

    enum Part {
        case heading(index: Int, content: String, attributes: Attributes)
        case fields([(String, String)], attributes: Attributes)
        case body(String)
    }

    func heading(adornment: String, text: String, attributes: Attributes) -> Part {
        let level = adornments[adornment] ?? (adornments.count + 1)
        adornments[adornment] = level
        let content = inline(text)
        let plain = rstHeadingText(content)
        let id = references.id(plain, kind: "section")
        if content.contains(references.prefix) { references.headingContent[id] = content }
        anchors.append(.init(level: level, id: id, text: plain))
        return .heading(index: anchors.count - 1, content: content, attributes: attributes)
    }

    /// Wait until sibling sections are known before promoting the title and subtitle.
    func assemble(_ parts: [Part]) -> String {
        var counts: [Int: Int] = [:]
        for case .heading(let index, _, _) in parts { counts[anchors[index].level, default: 0] += 1 }
        var promotion = 0
        if case .heading(let first, _, _) = parts.first, anchors[first].level == 1, counts[1] == 1 {
            promotion = 1
            if title == nil { title = anchors[first].text }
            if parts.count > 1, case .heading(let second, _, _) = parts[1], anchors[second].level == 2, counts[2] == 1 {
                promotion = 2
            }
        }
        var output = ""
        var front = depth == 1
        var beforeSections = front
        var open: [Int] = []
        for part in parts {
            switch part {
            case .body(let body):
                if beforeSections, let first = directives.contents.first, !first.local,
                    body == directives.marker(0)
                {
                    directives.lead = first
                }
                output += body
                beforeSections = false
                front = false
            case .fields(let rows, let attributes):
                let html = renderFields(rows, docinfo: front)
                output += rstAttachTargets(attributes.targets, to: applyDirectiveClasses(attributes.classes, to: html))
                front = false
            case .heading(let index, let content, let attributes):
                let anchor = anchors[index]
                let level = anchor.level
                let visible = min(6, max(1, level - promotion + 1))
                let id = HTML.escape(anchor.id)
                var heading: String
                if level <= promotion {
                    promotedHeadingIDs.insert(anchor.id)
                    heading =
                        level == 1
                        ? "<h1 class=\"title\" id=\"\(id)\">\(content)</h1>"
                        : "<p class=\"subtitle\" id=\"\(id)\">\(content)</p>"
                } else {
                    beforeSections = false
                    front = false
                    while let last = open.last, last >= level {
                        open.removeLast()
                        output += "</section>"
                    }
                    open.append(level)
                    output += "<section>"
                    heading = "<h\(visible) id=\"\(id)\">\(content)</h\(visible)>"
                }
                anchors[index] = .init(level: level <= promotion ? level : visible, id: anchor.id, text: anchor.text)
                for target in attributes.targets {
                    output += "<span id=\"\(HTML.escape(target))\"></span>"
                }
                output += applyDirectiveClasses(attributes.classes, to: heading)
            }
        }
        return output + String(repeating: "</section>", count: open.count)
    }
}

extension String {
    var rstStripped: String { trimmingCharacters(in: .whitespaces) }
    var rstIndent: Int { utf8.prefix { $0 == 32 }.count }
}

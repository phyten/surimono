import Foundation

public enum RSTConverter {
    /// The root directory is the source file's directory. The caller may further restrict file access.
    /// The callbacks run on the converter's own thread while the caller waits for it (`StackSpace.onLargeStack`):
    /// they must not need the caller's thread or actor, and do not see its task-local values.
    public static func convert(
        _ source: String, directory: URL? = nil, permitsFile: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) -> HTMLFragment {
        // On a stack of known size, so a document reads the same on every thread.
        StackSpace.onLargeStack { convertInPlace(source, directory: directory, permitsFile: permitsFile) }
    }

    private static func convertInPlace(_ source: String, directory: URL?, permitsFile: @escaping (URL) -> Bool)
        -> HTMLFragment
    {
        let document = RSTDocument(directory: directory, permitsFile: permitsFile)
        var normalized = TextDecoding.normalizeNewlines(source)
        if normalized.first == "\u{feff}" { normalized.removeFirst() }
        let lines = normalized.components(separatedBy: "\n").map(RSTDocument.expandTabs)
        let body = document.blocks(lines)
        document.finishHeadingText()
        let html = document.finishReferences(document.finishDirectives(body))
        let fonts = MathRenderer.fontFaces(for: html)
        return HTMLFragment(
            body: html + (fonts.isEmpty ? "" : "<style>\(fonts)</style>"), title: document.title,
            readingIssues: document.issueCount > 0 ? [String(document.issueCount)] : [])
    }
}

final class RSTDocument {
    let directory: URL?
    let permitsFile: (URL) -> Bool
    var references = RSTReferences()
    var directives = RSTDirectiveState()
    var anchors: [MarkdownExtensions.HeadingAnchor] = []
    var title: String?
    var promotedHeadingIDs: Set<String> = []
    var issueCount = 0
    private var adornments: [String: Int] = [:]
    var depth = 0

    init(directory: URL?, permitsFile: @escaping (URL) -> Bool) {
        // Anchor all later relative reads to the directory identified when conversion starts.
        self.directory = directory.flatMap { url in
            guard url.isFileURL, let path = try? ConfinedFile.canonicalPath(url) else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
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
        var open: [Int] = []
        for part in parts {
            switch part {
            case .body(let body):
                output += body
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

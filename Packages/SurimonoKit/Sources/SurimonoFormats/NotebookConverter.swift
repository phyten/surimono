import CoreFoundation
import Foundation

public enum NotebookError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSON
    case invalidStructure
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "The notebook is not valid JSON."
        case .invalidStructure: "The notebook is missing its version or cells, or contains an invalid cell."
        case .unsupportedVersion(let version): "Notebook format \(version) is not supported. Save it as nbformat 4."
        }
    }
}

/// Reads saved cells and outputs only; no kernel, code execution or external process is involved.
public enum NotebookConverter {
    /// Cell metadata from extensions nests a few levels more than nbformat's own; 100 is far beyond either. Measured
    /// in a debug build, Foundation reads 100 levels with about 150 KB of stack.
    static let maximumNesting = 100

    /// The JSON value of `text`, read by Foundation after every array or object nested deeper than
    /// `maximumNesting` has been replaced by `null`, and whether any was. Foundation's reader recurses once per level,
    /// and ten thousand nested objects ran out of the 512 KiB stack the app reads on. A notebook's own structure is a
    /// few levels deep, so what is cut is extension data the notebook does not print. Both opening a notebook and
    /// recognizing one on the clipboard read through here.
    package static func jsonObject(_ text: String) throws -> (value: Any, pruned: Bool) {
        let (data, pruned) = prunedNesting(Array(text.utf8))
        return (try JSONSerialization.jsonObject(with: data), pruned)
    }

    /// One pass outside strings: an array or object that opens below the limit is skipped to its end and replaced by
    /// `null`. An unterminated one is skipped to the end of the text, which then no longer parses.
    private static func prunedNesting(_ bytes: [UInt8]) -> (Data, Bool) {
        var depth = 0
        var inString = false
        var escaped = false
        var output: [UInt8] = []
        var skipFrom: Int?
        var copiedTo = 0
        for (offset, byte) in bytes.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    inString = false
                }
            } else if byte == 34 {
                inString = true
            } else if byte == 91 || byte == 123 {
                depth += 1
                if depth == maximumNesting + 1, skipFrom == nil {
                    output += bytes[copiedTo..<offset]
                    skipFrom = offset
                }
            } else if byte == 93 || byte == 125 {
                if depth == maximumNesting + 1, skipFrom != nil {
                    output += Array("null".utf8)
                    copiedTo = offset + 1
                    skipFrom = nil
                }
                depth -= 1
            }
        }
        guard skipFrom != nil || copiedTo > 0 else { return (Data(bytes), false) }
        if skipFrom == nil { output += bytes[copiedTo...] }
        return (Data(output), true)
    }

    public static func convert(_ text: String, pageBreakLine: String = "", proof: ProofMarks = .shown) throws
        -> HTMLFragment
    {
        // One conversion thread for the whole notebook; its Markdown cells then run on it in place.
        try StackSpace.onLargeStack { () throws -> HTMLFragment in
            try convertInPlace(text, pageBreakLine: pageBreakLine, proof: proof)
        }
    }

    private static func convertInPlace(_ text: String, pageBreakLine: String, proof: ProofMarks) throws
        -> HTMLFragment
    {
        let object: Any
        let pruned: Bool
        do { (object, pruned) = try jsonObject(text) } catch {
            throw NotebookError.invalidJSON
        }
        guard let root = object as? [String: Any], let version = version(root) else {
            throw NotebookError.invalidStructure
        }
        guard version == 4 else { throw NotebookError.unsupportedVersion(version) }
        guard let cells = root["cells"] as? [[String: Any]] else { throw NotebookError.invalidStructure }
        let metadata = root["metadata"] as? [String: Any] ?? [:]
        let codeLanguage =
            (metadata["language_info"] as? [String: Any])?["name"] as? String
            ?? (metadata["kernelspec"] as? [String: Any])?["language"] as? String
        let prose = cells.filter { $0["cell_type"] as? String == "markdown" }.map { string($0["source"]) }.joined(
            separator: "\n")
        let language = DocumentLanguage.detect(html: HTML.escape(prose), fallback: "en").code
        var context = NotebookContext(language: language, pageBreakLine: pageBreakLine, proof: proof)
        var title = metadata["title"] as? String
        var pieces: [String] = []
        for cell in cells {
            guard let type = cell["cell_type"] as? String,
                cell["source"] is String || cell["source"] is [String]
            else { throw NotebookError.invalidStructure }
            let metadata = cell["metadata"] as? [String: Any] ?? [:]
            let tags = Set(metadata["tags"] as? [String] ?? [])
            let jupyter = metadata["jupyter"] as? [String: Any] ?? [:]
            func hidden(_ part: String) -> Bool {
                tags.contains("remove-\(part)") || tags.contains("hide-\(part)")
            }
            if hidden("cell") { continue }
            let source = string(cell["source"])
            let hidesInput = hidden("input") || jupyter["source_hidden"] as? Bool == true
            switch type {
            case "markdown":
                if !hidesInput {
                    let fragment = context.markdown(source, attachments: cell["attachments"] as? [String: Any] ?? [:])
                    if title == nil { title = fragment.title }
                    pieces.append(fragment.body)
                }
            case "raw":
                if !hidesInput { pieces.append("<pre class=\"notebook-raw\">\(HTML.escape(source))</pre>\n") }
            case "code":
                if !hidesInput {
                    let prompt = (cell["execution_count"] as? NSNumber).map { $0.stringValue } ?? ""
                    let highlighted = codeLanguage.flatMap { SyntaxHighlighter.highlight(source, language: $0) }
                    let attribute =
                        codeLanguage.map {
                            " class=\"language-\(HTML.escape($0))\(highlighted == nil ? "" : " hl")\""
                        } ?? ""
                    let short = source.utf8.count <= 2_000 && source.filter { $0 == "\n" }.count < 12
                    pieces.append(
                        "<div class=\"notebook-input\(short ? " notebook-short" : "")\">"
                            + "<div class=\"notebook-prompt\">[\(HTML.escape(prompt))]</div>"
                            + "<pre><code\(attribute)>\(highlighted ?? HTML.escape(source))</code></pre></div>\n")
                }
                if !hidden("output"), jupyter["outputs_hidden"] as? Bool != true, metadata["collapsed"] as? Bool != true
                {
                    if let outputs = cell["outputs"] as? [[String: Any]] {
                        for output in outputs { pieces.append(context.output(output)) }
                    } else if cell["outputs"] != nil {
                        throw NotebookError.invalidStructure
                    }
                }
            default:
                pieces.append(context.note("Unsupported notebook cell: \(type)", japanese: "未対応のセル: \(type)"))
            }
        }
        var body = context.resolvingLinks(in: pieces.joined())
        let headings = DocumentOutline.headings(inHTML: body).compactMap {
            heading -> MarkdownExtensions.HeadingAnchor? in
            guard let id = heading.id else { return nil }
            return .init(level: heading.level, id: id, text: heading.text)
        }
        body = body.replacingOccurrences(of: context.tocMarker, with: MarkdownExtensions.tableOfContents(headings))
        let fonts = MathRenderer.fontFaces(for: body)
        if !fonts.isEmpty { body += "<style>\n\(fonts)\n</style>\n" }
        return HTMLFragment(body: body, title: title, language: language).notingLimit(context.reachedLimit)
            .notingOmission(pruned)
    }

    package static func version(_ root: [String: Any]) -> Int? {
        guard let number = root["nbformat"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue < Double(Int.max),
            number.doubleValue.rounded() == number.doubleValue
        else { return nil }
        return number.intValue
    }

    static func string(_ value: Any?) -> String {
        (value as? String) ?? (value as? [String])?.joined() ?? ""
    }
}

struct NotebookContext: Sendable {
    let language: String
    let pageBreakLine: String
    let proof: ProofMarks
    let tocMarker = "<!--notebook-toc-\(UUID().uuidString)-->"
    var cellIndex = 0
    var firstAnchor: [String: String] = [:]
    var anchorIDs = Set<String>()
    var linkTargets: [String: String] = [:]
    /// Whether a Markdown cell or output was printed in part as text because it nested too deeply.
    var reachedLimit = false

    func resolvingLinks(in html: String) -> String {
        var result = ""
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .text(let text), .opaque(let text): result += text
            case .tag(let tag):
                if let href = tag.attribute("href"), href.hasPrefix("#"),
                    let original = linkTargets[String(href.dropFirst())],
                    !anchorIDs.contains(String(href.dropFirst())), let target = firstAnchor[original]
                {
                    result += NotebookHTML.setting("href", value: "#" + target, in: tag.source)
                } else {
                    result += tag.source
                }
            }
        }
        return result
    }

    func note(_ english: String, japanese: String) -> String {
        "<div class=\"notebook-note\">\(HTML.escape(language == "ja" ? japanese : english))</div>\n"
    }

    mutating func markdown(_ source: String, attachments: [String: Any] = [:]) -> HTMLFragment {
        cellIndex += 1
        let fragment = MarkdownConverter.notebookCell(
            source, pageBreakLine: pageBreakLine, proof: proof, toc: tocMarker)
        if fragment.readingIssues.contains(StackSpace.limitIssue) { reachedLimit = true }
        let prefix = "nb-\(cellIndex)-"
        var body = ""
        // Namespace all anchors, including footnotes, so independent Markdown documents cannot collide.
        for token in HTMLScanner.tokens(fragment.body) {
            switch token {
            case .text(let text), .opaque(let text): body += text
            case .tag(let tag):
                var source = tag.source
                for name in ["id", "href"] {
                    if let value = tag.attribute(name), name == "id" || value.hasPrefix("#") {
                        let original =
                            name == "id"
                            ? value : (String(value.dropFirst()).removingPercentEncoding ?? String(value.dropFirst()))
                        let target = prefix + original
                        if name == "id" {
                            anchorIDs.insert(target)
                            if firstAnchor[original] == nil { firstAnchor[original] = target }
                        } else {
                            linkTargets[target] = original
                        }
                        let replacement = name == "id" ? target : "#" + target
                        source = NotebookHTML.setting(name, value: replacement, in: source)
                    }
                }
                if let src = tag.attribute("src"), src.hasPrefix("attachment:") {
                    let key =
                        String(src.dropFirst("attachment:".count)).removingPercentEncoding ?? String(src.dropFirst(11))
                    if let bundle = attachments[key] as? [String: Any], let image = NotebookImage.first(in: bundle) {
                        source = NotebookHTML.setting("src", value: image.uri, in: source)
                    } else {
                        body += note("Attachment is not available: \(key)", japanese: "添付画像を読み込めません: \(key)")
                    }
                }
                body += source
            }
        }
        return HTMLFragment(body: body, title: DocumentOutline.headings(inHTML: body).first { $0.level == 1 }?.text)
    }

    mutating func output(_ output: [String: Any]) -> String {
        switch output["output_type"] as? String {
        case "stream":
            return text(
                NotebookConverter.string(output["text"]),
                kind: output["name"] as? String == "stderr" ? "stderr" : "stream")
        case "error":
            let heading = NotebookConverter.string(output["ename"]) + ": " + NotebookConverter.string(output["evalue"])
            let traceback =
                (output["traceback"] as? [String])?.joined(separator: "\n")
                ?? NotebookConverter.string(output["traceback"])
            return text(heading + "\n" + traceback, kind: "error")
        case "execute_result", "display_data":
            return bundle(
                output["data"] as? [String: Any] ?? [:], metadata: output["metadata"] as? [String: Any] ?? [:])
        default:
            return note("Unsupported notebook output", japanese: "未対応の出力です")
        }
    }

    mutating func bundle(_ data: [String: Any], metadata: [String: Any]) -> String {
        if let image = NotebookImage.first(in: data) { return image.html(metadata: metadata) }
        let plain = NotebookConverter.string(data["text/plain"])
        let interactive = data.keys.contains {
            $0 == "application/javascript" || $0.hasPrefix("application/vnd.jupyter.widget")
                || $0.hasPrefix("application/vnd.plotly") || $0.hasPrefix("application/vnd.bokehjs")
        }
        if let value = data["text/html"] {
            let original = NotebookConverter.string(value)
            if NotebookText.needsLimit(original) { return text(original, kind: "plain") }
            let cleaned = NotebookHTML.clean(original)
            if cleaned.hasContent {
                return "<div class=\"notebook-output\">\(cleaned.html)</div>\n"
                    + (cleaned.removedContent
                        ? note("Part of this output is not shown on paper", japanese: "この出力の一部は紙に表示できません") : "")
            }
            if !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || interactive {
                return interactiveNote(plain)
            }
        }
        if let value = data["text/markdown"] {
            let source = NotebookConverter.string(value)
            if NotebookText.needsLimit(source) { return text(source, kind: "plain") }
            return markdown(source).body
        }
        if let value = data["text/latex"] {
            let source = NotebookConverter.string(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !NotebookText.needsLimit(source), let math = NotebookText.math(source) { return math }
            return text(source, kind: "plain")
        }
        if interactive { return interactiveNote(plain) }
        if data["text/plain"] != nil { return text(plain, kind: "plain") }
        return note("Unsupported notebook output", japanese: "未対応の出力です")
    }

    func interactiveNote(_ plain: String) -> String {
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        let repr =
            trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
            || trimmed.range(of: #"\A(?:\w+\.)?(?:\w*Widget|\w*Slider|\w*Box|Figure)\("#, options: .regularExpression)
                != nil
        return note("Interactive output is not shown on paper", japanese: "対話型の出力は紙に表示できません")
            + (trimmed.isEmpty || repr ? "" : text(plain, kind: "plain"))
    }

    func text(_ source: String, kind: String) -> String {
        let clean = NotebookText.terminal(source)
        let parts = NotebookText.limited(clean)
        func block(_ value: String) -> String {
            let short = value.utf8.count <= 2_000 && value.filter { $0 == "\n" }.count < 12
            return
                "<pre class=\"notebook-output notebook-\(kind)\(short ? " notebook-short" : "")\">\(HTML.escape(value))</pre>\n"
        }
        guard let omitted = parts.omitted else { return block(clean) }
        return block(parts.first) + note("… \(omitted) lines omitted", japanese: "… \(omitted) 行を省略しました")
            + block(parts.last)
    }
}

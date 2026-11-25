import Foundation

public enum ComputationalMarkdown {
    public static func convert(_ text: String, pageBreakLine: String = "", proof: ProofMarks = .shown) -> HTMLFragment {
        var lines = TextDecoding.normalizeNewlines(text).components(separatedBy: "\n")
        var metadata = ComputationalMetadata(lines: &lines)
        let language =
            metadata.values["lang"].flatMap(DocumentLanguage.normalized)
            ?? proseLanguage(lines, metadata: metadata)
        metadata.japanese = DocumentLanguage.primary(language) == "ja"
        var document = ComputationalBody(metadata: metadata)
        let source = document.prepare(lines)
        if PreviewConversion.expired { return HTMLFragment(body: "") }
        let fragment = MarkdownConverter.convert(source, pageBreakLine: pageBreakLine, proof: proof)
        if PreviewConversion.expired { return HTMLFragment(body: "") }
        let fallback = metadata.unreadable.map { MarkupHTML.listing($0, language: "yaml") } ?? ""
        return HTMLFragment(
            body: fallback + metadata.header + document.contents + document.resolve(fragment.body),
            title: metadata.values["title"]
                ?? fragment.title.map { HTML.unescape(document.resolve($0, plainText: true)) }, language: language,
            readingIssues: fragment.readingIssues)
    }

    private static func proseLanguage(_ lines: [String], metadata: ComputationalMetadata) -> String {
        var sample = ["title", "subtitle", "abstract"].compactMap { metadata.values[$0] }
        var active: ComputationalFence?
        for line in lines {
            if let fence = active {
                if fence.closes(line) { active = nil }
            } else if let fence = ComputationalFence(line) {
                active = fence
            } else if !line.isEmpty {
                sample.append(line)
                if sample.count >= 120 { break }
            }
        }
        return DocumentLanguage.detect(html: HTML.escape(sample.joined(separator: "\n")), fallback: "en").code
    }

    package static func clipboardKind(_ text: String) -> DocumentFormat? {
        let prefix = String(decoding: text.utf8.prefix(32_768), as: UTF8.self)
        guard prefix.contains("```") || prefix.contains("~~~") else { return nil }
        var lines = TextDecoding.normalizeNewlines(prefix).components(separatedBy: "\n")
        let metadata = ComputationalMetadata(lines: &lines)
        var active: ComputationalFence?
        var executable = false
        var found = false
        var comma = false
        var pipe = false
        for line in lines {
            if let fence = active {
                if fence.closes(line) {
                    active = nil
                } else if executable && ComputationalChunk.option(line) != nil {
                    pipe = true
                }
            } else if let fence = ComputationalFence(line) {
                active = fence
                executable = fence.chunk?.isStatic == false
                if executable {
                    found = true
                    comma = comma || fence.chunk?.knitr == true
                }
            }
        }
        guard found else { return nil }
        return !metadata.keys.contains("format") && !pipe && (metadata.keys.contains("output") || comma)
            ? .rMarkdown : .quarto
    }
}

struct ComputationalBody {
    let metadata: ComputationalMetadata
    var defaults: [String: String]
    var output: [String] = []
    var divisions: [ComputationalDivision] = []
    var notes: [String] = []
    var counts: [String: Int] = [:]
    var labels: [String: ComputationalLabel] = [:]
    var insertions: [ComputationalInsertion] = []
    var headings: [(level: Int, id: String, text: String)] = []
    var headingIDs: Set<String> = []
    var sectionNumbers = Array(repeating: 0, count: 6)
    // A document cannot collide with the deferred references and generated footnote IDs.
    let token = "surimono" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var previousHiddenResult = false

    init(metadata: ComputationalMetadata) {
        self.metadata = metadata
        defaults = metadata.defaults
    }

    mutating func prepare(_ lines: [String]) -> String {
        if let abstract = metadata.values["abstract"] {
            block("<div class=\"abstract\"><p class=\"abstract-title\">\(metadata.japanese ? "要旨" : "Abstract")</p>")
            output.append(inline(abstract))
            block("</div>")
        }
        var index = 0
        while index < lines.count {
            if PreviewConversion.expired { return "" }
            let line = lines[index]
            index += 1
            if let fence = ComputationalFence(line) {
                let start = index
                while index < lines.count && !fence.closes(lines[index]) { index += 1 }
                let body = lines[start..<index]
                if index < lines.count { index += 1 }
                guard divisions.last?.hidden != true else { continue }
                if let chunk = fence.chunk {
                    render(chunk, body: body, fence: fence)
                } else if ["r", "julia"].contains(fence.info.lowercased()) {
                    block(
                        MarkupHTML.listing(
                            body.joined(separator: "\n"), language: fence.info.lowercased(), computational: true))
                } else if fence.info.hasPrefix("{=") {
                    if fence.info == "{=html}" {
                        // Preserve raw HTML byte-for-byte across the Markdown parser, including its blank lines.
                        let placeholder = deferInsertion(.literal(body.joined(separator: "\n")))
                        block("<!--\(placeholder)-->")
                    }
                } else {
                    previousHiddenResult = false
                    output += lines[(start - 1)..<index]
                }
            } else if line.trimmingCharacters(in: .whitespaces) == "$$",
                let close = lines[index...].firstIndex(where: {
                    $0.firstMatch(of: /^\s*\$\$(?:\s*\{#eq-[\w:.-]+\})?\s*$/) != nil
                })
            {
                if divisions.last?.hidden != true {
                    output += lines[(index - 1)..<close]
                    prose(lines[close])
                }
                index = close + 1
            } else if division(line, lines: lines, index: &index) {
                continue
            } else if divisions.last?.hidden != true {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { previousHiddenResult = false }
                prose(line)
            }
        }
        while !divisions.isEmpty { closeDivision() }
        if metadata.values["bibliography"] != nil {
            block(notice(metadata.japanese ? "参考文献は解決されません。" : "Bibliography references are unresolved."))
        }
        output.append("")
        output += notes
        return output.joined(separator: "\n")
    }

    mutating func block(_ html: String) {
        output += ["", html, ""]
        previousHiddenResult = false
    }

    func notice(_ text: String, result: Bool = false) -> String {
        "<div class=\"\(result ? "chunk-result-note" : "computational-note")\">\(HTML.escape(text))</div>"
    }

    mutating func render(_ chunk: ComputationalChunk, body: ArraySlice<String>, fence: ComputationalFence) {
        var code = body
        var options = defaults.merging(chunk.options) { _, value in value }
        while !chunk.isStatic, let line = code.first, let (key, value) = ComputationalChunk.option(line) {
            options[key] = ComputationalMetadata.scalar(value)
            code = code.dropFirst()
        }
        let source = code.joined(separator: "\n")
        let lang = chunk.language == "ojs" ? "javascript" : chunk.language
        if chunk.isStatic {
            if let name = chunk.options["filename"] { block("<div class=\"code-filename\">\(HTML.escape(name))</div>") }
            block(MarkupHTML.listing(source, language: lang, computational: true))
            return
        }
        let label = options["label"]
        let setup = label == "setup"
        func enabled(_ key: String) -> Bool { options[key]?.lowercased() != "false" }
        if (setup || !enabled("include")) && lang == "r" && enabled("eval") {
            defaults.merge(ComputationalChunk.setupDefaults(source)) { _, value in value }
        }
        guard enabled("include") else { return }
        let diagram = ["dot", "mermaid"].contains(lang)
        var drawing = ""
        if diagram || enabled("echo") {
            let listing =
                options["echo"] == "fenced" && !diagram
                ? MarkupHTML.listing("\(fence.marker)\(fence.info)\n\(source)\n\(fence.marker)", language: nil)
                : MarkupHTML.listing(source, language: lang, computational: true)
            if diagram { drawing = listing } else { block(listing) }
        }
        guard diagram || (!setup && enabled("eval") && enabled("output") && options["results"] != "hide") else {
            return
        }
        let caption = options["fig-cap"] ?? options["fig.cap"] ?? options["tbl-cap"]
        var id = label ?? ""
        let kind = ComputationalLabel.kind(id) ?? (caption == nil ? nil : (options["tbl-cap"] == nil ? "fig" : "tbl"))
        let message =
            metadata.japanese ? "コードを実行しないため、結果は表示されません。" : "Results are unavailable because the code is not run."
        let note = diagram ? drawing : notice(message, result: true)
        if let kind {
            if ComputationalLabel.kind(id) == nil && !id.isEmpty { id = kind + ":" + id }
            let target = register(id, kind: kind)
            block(
                "<figure\(target.attribute)>\(note)<figcaption>\(target.text) \(HTML.escape(caption ?? ""))</figcaption></figure>"
            )
        } else if diagram {
            block(drawing)
        } else {
            let hidden = !enabled("echo")
            if !hidden || !previousHiddenResult { block(note) }
            previousHiddenResult = hidden
        }
    }
}

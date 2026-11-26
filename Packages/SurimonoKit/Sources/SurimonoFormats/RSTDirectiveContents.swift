import Foundation

extension RSTDocument {
    func finishDirectives(_ html: String, options: FormatReadingSettings.Options) -> String {
        guard options.numbers != nil || !directives.contents.isEmpty else { return html }
        let sections = anchors.filter { !promotedHeadingIDs.contains($0.id) }
        let numbers = rstSectionNumbers(sections, depth: options.numbers)
        var nextEntry = 1
        var rendered: [String] = []
        for toc in directives.contents {
            let isLead = toc.id == directives.lead?.id
            if isLead && options.lead == nil {
                rendered.append("")
                continue
            }
            let limit = isLead ? options.lead?.headingLevels ?? toc.depth : toc.depth
            let position = min(anchors.count, toc.position)
            var entries: [MarkdownExtensions.HeadingAnchor]
            if toc.local, position > 0, !promotedHeadingIDs.contains(anchors[position - 1].id) {
                let level = anchors[position - 1].level
                entries = Array(anchors[position...].prefix { $0.level > level })
            } else {
                entries = sections
            }
            guard let top = entries.map(\.level).min(), nextEntry <= 50_000 else {
                rendered.append("")
                continue
            }
            entries = entries.filter { $0.level - top < limit }
            var body = ""
            var depth = 0
            for entry in entries {
                let adjusted = entry.level - top + 1
                if adjusted > depth {
                    body += String(repeating: "<ul>", count: adjusted - depth)
                } else {
                    body += "</li>" + String(repeating: "</ul></li>", count: depth - adjusted)
                }
                let id = references.id("", kind: "toc-entry")
                nextEntry += 1
                body +=
                    "<li><a href=\"#\(HTML.escape(entry.id))\" id=\"\(id)\">"
                    + HTML.escape((numbers[entry.id] ?? "") + entry.text) + "</a>"
                depth = adjusted
            }
            body += String(repeating: "</li></ul>", count: depth)
            let label = toc.label.isEmpty ? (toc.local ? "" : "Contents") : toc.label
            let heading = label.isEmpty ? "" : "<p class=\"topic-title\">\(inline(label))</p>"
            let nav = "<nav class=\"toc\" id=\"\(HTML.escape(toc.id))\" role=\"doc-toc\">\(heading)\(body)</nav>"
            rendered.append((isLead ? ReaderContentsKind.lead : .text).mark(nav))
        }
        var result = html
        if !numbers.isEmpty {
            let heading = WikiPattern(#"(?s)(<h[1-6]\b[^>]*\bid="([^"]+)"[^>]*>)(.*?)(</h[1-6]>)"#)
            result = heading.replace(result) { parts in
                let id = HTML.unescape(parts[2])
                let number = numbers[id].map { "<span class=\"sectnum\">\(HTML.escape($0))</span>" } ?? ""
                return parts[1] + number + parts[3] + parts[4]
            }
        }
        let marker = WikiPattern("<!--" + directives.token + #"toc([0-9]+)-->"#)
        return marker.replace(result) { parts in
            guard let index = Int(parts[1]), rendered.indices.contains(index) else { return "" }
            return rendered[index]
        }
    }

    private func rstSectionNumbers(_ entries: [MarkdownExtensions.HeadingAnchor], depth: ReadingDepth?) -> [String:
        String]
    {
        guard let depth, let top = entries.map(\.level).min() else { return [:] }
        let options = directives.numbering ?? [:]
        let first = min(1_000_000, max(1, Int(options["start"] ?? "") ?? 1))
        var counters = SectionNumbers(start: first)
        var numbers: [String: String] = [:]
        for entry in entries {
            let index = entry.level - top
            guard index < depth.headingLevels else { continue }
            numbers[entry.id] =
                (options["prefix"] ?? "") + counters.next(level: index + 1, trailingDot: false)
                + (options["suffix"] ?? "") + " "
        }
        return numbers
    }
}

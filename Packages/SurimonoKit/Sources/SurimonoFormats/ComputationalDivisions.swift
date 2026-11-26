import Foundation

struct ComputationalAttributes {
    var classes: [String] = []
    var id = ""
    var options: [String: String] = [:]

    init(_ source: String) {
        for token in source.matches(of: /(?:[^\s"']+|"[^"]*"|'[^']*')+/) {
            let word = token.output
            if word.first == "." {
                classes.append(String(word.dropFirst()))
            } else if word.first == "#" {
                id = String(word.dropFirst())
            } else if let split = word.firstIndex(of: "=") {
                options[String(word[..<split])] = ComputationalMetadata.scalar(
                    String(word[word.index(after: split)...]))
            }
        }
    }

    var html: String {
        (id.isEmpty ? "" : " id=\"\(HTML.escape(id))\"")
            + (classes.isEmpty ? "" : " class=\"\(HTML.escape(classes.joined(separator: " ")))\"")
    }

    var hidden: Bool {
        if classes.contains("notes") || classes.contains("hidden") { return true }
        func printFormat(_ key: String) -> Bool? {
            options[key].map { value in
                value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).contains {
                    ["pdf", "print", "latex"].contains($0)
                }
            }
        }
        let matches = (printFormat("when-format") ?? true) && !(printFormat("unless-format") ?? false)
        return classes.contains("content-visible") && !matches || classes.contains("content-hidden") && matches
    }
}

struct ComputationalDivision {
    let width: Int
    let hidden: Bool
    let contentStart: Int
    let target: ComputationalLabel?
}

extension ComputationalBody {
    mutating func division(_ line: String, lines: [String], index: inout Int) -> Bool {
        guard line.utf8.first(where: { $0 != 32 }) == 58, let match = line.wholeMatch(of: /^ {0,3}(:{3,})\s*(.*?)\s*$/)
        else { return false }
        let width = match.1.count
        if match.2.isEmpty {
            guard let current = divisions.last, current.width <= width else { return false }
            closeDivision()
            return true
        }
        let spec = String(match.2)
        let attributes: ComputationalAttributes
        if spec.hasPrefix("{"), spec.hasSuffix("}") {
            attributes = ComputationalAttributes(String(spec.dropFirst().dropLast()))
        } else if spec.hasPrefix(".") || spec.hasPrefix("callout-") || spec == "panel-tabset" {
            attributes = ComputationalAttributes(spec.first == "." ? spec : "." + spec)
        } else {
            return false
        }
        let hidden = divisions.last?.hidden == true || attributes.hidden
        var target: ComputationalLabel?
        if !hidden {
            if let kind = ComputationalLabel.kind(attributes.id) {
                target = register(attributes.id, kind: kind)
            }
            if let name = attributes.classes.first(where: { $0.hasPrefix("callout-") }) {
                let kind = MarkdownCallouts.Kind(name: String(name.dropFirst(8)))
                var first = index
                while first < lines.count && lines[first].trimmingCharacters(in: .whitespaces).isEmpty { first += 1 }
                var heading: String?
                if first < lines.count, let match = lines[first].wholeMatch(of: /^#{1,6}\s+(.+)$/) {
                    heading = String(match.1)
                    index = first + 1
                }
                let title = HTML.escape(attributes.options["title"] ?? heading ?? kind.defaultTitle)
                let tag =
                    attributes.options["icon"] == "false"
                    ? "<p class=\"callout-title\">\(title)</p>" : kind.title(title)
                let id = attributes.id.isEmpty ? "" : " id=\"\(HTML.escape(attributes.id))\""
                let appearance = attributes.options["appearance"]
                let style = ["simple", "minimal"].contains(appearance) ? "callout-" + (appearance ?? "") : ""
                block(kind.opening(extraClasses: style, attributes: id) + tag)
            } else if let target, ["fig", "tbl"].contains(target.kind) {
                block("<figure\(attributes.html)>")
            } else {
                block("<div\(attributes.html)>" + (target.map { "<strong>\($0.text)</strong>" } ?? ""))
            }
        }
        divisions.append(.init(width: width, hidden: hidden, contentStart: output.count, target: target))
        return true
    }

    mutating func closeDivision() {
        guard let current = divisions.popLast(), !current.hidden else { return }
        if let target = current.target, ["fig", "tbl"].contains(target.kind) {
            var end = output.count
            while end > current.contentStart && output[end - 1].isEmpty { end -= 1 }
            var start = end
            while start > current.contentStart && !output[start - 1].isEmpty { start -= 1 }
            var caption = ""
            if start < end && !output[start].hasPrefix("<") && !output[start].hasPrefix("!")
                && !output[start].hasPrefix("|")
            {
                caption = output[start..<end].joined(separator: " ")
                output.removeSubrange(start...)
            }
            block("<figcaption>")
            output.append(target.text + (caption.isEmpty ? "" : " " + caption))
            block("</figcaption></figure>")
        } else {
            block("</div>")
        }
    }

    mutating func prose(_ line: String) {
        if line.trimmingCharacters(in: .whitespaces) == #"\newpage"# {
            block("<div class=\"page-break\"></div>")
        } else if line.hasPrefix("#"), let match = line.wholeMatch(of: /^(#{1,6})\s+(.*?)(?:\s+\{([^{}]+)\})?\s*$/) {
            let level = match.1.count
            let attrs = ComputationalAttributes(match.3.map(String.init) ?? "")
            let title = String(match.2)
            let requested = attrs.id.isEmpty ? MarkdownExtensions.slug(title) : attrs.id
            let id = MarkdownExtensions.headingID(requested, used: &headingSuffixes)
            if ComputationalLabel.kind(id) == "sec" { _ = register(id, kind: "sec") }
            if attrs.classes.contains("unnumbered") { unnumbered.insert(id) }
            if attrs.classes.contains("unlisted") { unlisted.insert(id) } else { headings.append((level, id, title)) }
            output.append("\(match.1) \(inline(title)) {#\(id)}")
        } else if line.contains("{#fig-"),
            let match = line.wholeMatch(of: /^\s*(!\[([^\]]*)\]\(.+\))\s*\{#(fig-[\w:.-]+)\}\s*$/)
        {
            let target = register(String(match.3), kind: "fig")
            block("<figure\(target.attribute)>")
            output.append(String(match.1))
            block("<figcaption>\(target.text) \(HTML.escape(String(match.2)))</figcaption></figure>")
        } else if line.hasPrefix(":"), let match = line.wholeMatch(of: /^:\s+(.+?)\s+\{#(tbl-[\w:.-]+)\}\s*$/) {
            let target = register(String(match.2), kind: "tbl")
            block(
                "<div\(target.attribute) class=\"table-caption\">\(target.text) \(HTML.escape(String(match.1)))</div>")
        } else if line.contains("{#eq-"), let match = line.wholeMatch(of: /^(.*\$\$)\s*\{#(eq-[\w:.-]+)\}\s*$/) {
            let target = register(String(match.2), kind: "eq")
            output.append(String(match.1))
            block("<div\(target.attribute) class=\"equation-number\">(\(target.number))</div>")
        } else if line.hasPrefix("| "), !line.dropFirst().contains("|") {
            output.append(inline(String(line.dropFirst(2))) + "  ")
        } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
            output.append(line)
        } else {
            output.append(inline(line))
        }
    }

    mutating func resolveHeadings(_ anchors: [MarkdownExtensions.HeadingAnchor], numbered: Bool) {
        // Keep the native list's original title spelling, including inline markup.
        let titles = Dictionary(uniqueKeysWithValues: headings.map { ($0.id, $0.text) })
        headings = anchors.compactMap { anchor in
            if let requested = anchor.customID, var label = labels[requested], label.kind == "sec" {
                label.id = anchor.id
                if !anchor.number.isEmpty { label.number = String(anchor.number.dropLast()) }
                labels[requested] = label
            }
            let title = anchor.customID.flatMap { titles[$0] }
            guard numbered || title != nil, !unlisted.contains(anchor.customID ?? "") else { return nil }
            return (anchor.level, anchor.id, anchor.number + (title ?? anchor.text))
        }
    }

    func contents(depth: Int) -> String {
        let items = headings.filter { $0.level <= depth }.map {
            "<li><a href=\"#\(HTML.escape($0.id))\">\(HTML.escape($0.text))</a></li>"
        }
        guard !items.isEmpty else { return "" }
        let title = metadata.values["toc-title"] ?? (metadata.japanese ? "目次" : "Contents")
        return "<nav class=\"toc\"><p>\(HTML.escape(title))</p><ul>\(items.joined())</ul></nav>\n"
    }
}

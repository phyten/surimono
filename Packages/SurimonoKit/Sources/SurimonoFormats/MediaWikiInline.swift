import Foundation

extension WikiReader {
    static let inlineTokens = WikiPattern(
        "\u{E000}([0-9]+)\u{E001}([a-z]*)"
            + #"|(?:https?://|mailto:)[^\s"<>\[\]\uE000]+"#
            + #"|&(?:#\d+|#[xX][a-fA-F0-9]+|[a-zA-Z][a-zA-Z0-9]*);|__[A-Z][A-Z0-9_]*?__"#
    )
    // Separator whitespace never belongs to the label, even when the closing bracket is missing.
    private static let bracketLink = WikiPattern(#"\[((?:https?://|mailto:)[^\s\[\]<>]++)(?:[ \t]++([^\[\]\n]*+))?\]"#)
    private static let quotes = WikiPattern("'{2,}")
    private static let languages = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))

    func inline(_ sourceText: String) -> String {
        if PreviewConversion.expired { return "" }
        // Templates, links and references nest through here; when the stack runs short the rest stays as text.
        guard StackSpace.hasRoom else {
            reachedNestingLimit = true
            return HTML.escape(sourceText)
        }
        if sourceText.contains("\n") {
            return inlineLines(sourceText, separator: " ")
        }
        let text =
            sourceText.contains("[")
            ? Self.bracketLink.replace(sourceText) { m in
                atom("external", m[2], ["url": m[1]])
            } : sourceText
        guard text.contains("''") else { return pieces(text) }
        let source = text as NSString
        var runs: [(range: NSRange, count: Int)] = []
        var oddBold = false
        var oddItalic = false
        var best: (index: Int, rank: Int)?
        // Four quotes carry one literal apostrophe. If both styles have odd parity, MediaWiki
        // prefers a contraction after a single letter, then a longer word, then whitespace.
        Self.quotes.forEachMatch(in: text) { match in
            let count = match.range.length == 4 ? 3 : min(match.range.length, 5)
            if count != 2 { oddBold.toggle() }
            if count != 3 { oddItalic.toggle() }
            if count == 3 {
                let pos = match.range.location
                let rank =
                    pos == 0 || source.character(at: pos - 1) == 32
                    ? 2 : (pos == 1 || source.character(at: pos - 2) == 32 ? 0 : 1)
                if rank < (best?.rank ?? 3) { best = (runs.count, rank) }
            }
            runs.append((match.range, count))
        }
        if PreviewConversion.expired { return "" }
        if oddBold, oddItalic, let best { runs[best.index].count = 2 }
        var stack: [String] = []
        var output = ""
        var cursor = 0
        func toggle(_ tag: String) {
            if let start = stack.firstIndex(of: tag) {
                let inside = Array(stack[(start + 1)...])
                for current in stack[start...].reversed() { output += "</\(current)>" }
                stack.removeSubrange(start...)
                for current in inside {
                    stack.append(current)
                    output += "<\(current)>"
                }
            } else {
                output += "<\(tag)>"
                stack.append(tag)
            }
        }
        for (i, mark) in runs.enumerated() {
            if i.isMultiple(of: 128), PreviewConversion.expired { return "" }
            output += pieces(source.substring(with: NSRange(location: cursor, length: mark.range.location - cursor)))
            let run = mark.count
            output += String(repeating: "&#39;", count: mark.range.length - run)
            if run == 5 {
                if stack.count == 2 {
                    for tag in stack.reversed() { output += "</\(tag)>" }
                    stack.removeAll()
                } else {
                    let first = stack.last ?? (i + 1 < runs.count && runs[i + 1].count == 2 ? "strong" : "em")
                    toggle(first)
                    toggle(first == "em" ? "strong" : "em")
                }
            } else {
                toggle(run == 2 ? "em" : "strong")
            }
            cursor = NSMaxRange(mark.range)
        }
        return output + pieces(source.substring(from: cursor)) + stack.reversed().map { "</\($0)>" }.joined()
    }

    private func inlineLines(_ text: String, separator: String) -> String {
        var output = ""
        for (index, line) in text.wikiFields(separatedBy: "\n").enumerated() {
            if index.isMultiple(of: 128), PreviewConversion.expired { return "" }
            if index > 0 { output += separator }
            output += inline(line)
        }
        return output
    }

    private func pieces(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return Self.inlineTokens.replace(text, plain: HTML.escape) { m in
            if let i = Int(m[1]), atoms.indices.contains(i) {
                let a = atoms[i]
                return a.kind == "link" ? render(a, trail: m[2]) : render(a) + m[2]
            }
            if m[0].hasPrefix("&") { return m[0] }
            if m[0].hasPrefix("__") {
                switch m[0] {
                case "__FORCETOC__":
                    forceTOC = true
                    if switchOffsets[m[0]] == nil { switchOffsets[m[0]] = activeSwitches[m[0]] }
                case "__TOC__" where !explicitTOC:
                    explicitTOC = true
                    return later { [self] in ReaderContentsKind.text.mark(MarkdownExtensions.tableOfContents(anchors)) }
                case "__NOTOC__":
                    hideTOC = true
                    if switchOffsets[m[0]] == nil { switchOffsets[m[0]] = activeSwitches[m[0]] }
                default: break
                }
                return ""
            }
            var url = m[0][...]
            var excess = 0
            for (index, char) in url.enumerated() {
                if index.isMultiple(of: 128), PreviewConversion.expired { return "" }
                if char == ")" { excess += 1 } else if char == "(" { excess -= 1 }
            }
            var removed = 0
            while let last = url.last {
                if removed.isMultiple(of: 128), PreviewConversion.expired { return "" }
                if last == ")" && excess > 0 { excess -= 1 } else if !".,;:!?。、「」".contains(last) { break }
                url = url.dropLast()
                removed += 1
            }
            return anchor(String(url), HTML.escape(String(url))) + HTML.escape(String(m[0].dropFirst(url.count)))
        }
    }

    func anchor(_ url: String, _ label: String) -> String {
        guard ["https://", "http://", "mailto:"].contains(where: url.lowercased().hasPrefix) else { return label }
        return "<a href=\"\(HTML.escape(url))\">\(label)</a>"
    }

    func link(_ body: String, trail: String = "") -> String {
        let parts = body.components(separatedBy: "|")
        let target = parts[0].wikiTrim
        let ns = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let prefix = ns.count == 2 ? ns[0].lowercased() : ""
        if ["file", "image", "ファイル", "画像"].contains(prefix) {
            return image(String(ns[1]), options: Array(parts.dropFirst())) + trail
        }
        if ["category", "カテゴリ", "カテゴリー"].contains(prefix) {
            let category = String(ns[1])
            if categorySet.insert(category).inserted { categories.append(category) }
            return trail
        }
        if Self.languages.contains(prefix) { return trail }
        let page = target.hasPrefix(":") ? String(target.dropFirst()) : target
        var label = parts.count == 1 ? page : parts.dropFirst().joined(separator: "|")
        if label.isEmpty {
            label = (ns.last.map(String.init) ?? page).replacingOccurrences(
                of: #"\s*\([^()]*\)$|,.*$"#, with: "", options: .regularExpression)
        }
        let content = inline(label) + trail
        let plain = "<span class=\"wiki-link\">\(content)</span>"
        if target.hasPrefix("#") {
            let section = String(target.dropFirst())
            let literal = MarkdownExtensions.slug(section)
            let normalized = MarkdownExtensions.slug(section.replacingOccurrences(of: "_", with: " "))
            func destination() -> String? {
                if headingIDs.contains(literal) { return literal }
                return headingIDs.contains(normalized) ? normalized : nil
            }
            let open = later {
                destination().map { "<a href=\"#\($0)\">" } ?? "<span class=\"wiki-link\">"
            }
            let close = later { destination() != nil ? "</a>" : "</span>" }
            return open + content + close
        }
        return plain
    }

    func render(_ a: Atom, block: Bool = false, display: Bool = false, trail: String = "") -> String {
        let parent = activeSwitches
        activeSwitches = a.switches
        defer { activeSwitches = parent }
        switch a.kind {
        case "external":
            if a.body.isEmpty { external += 1 }
            return anchor(a.attrs["url"] ?? "", a.body.isEmpty ? "[\(external)]" : inline(a.body))
        case "html": return a.body
        case "nowiki", "literal": return HTML.escape(a.body)
        case "pre": return "<pre>\(HTML.escape(a.body))</pre>"
        case "chem": return "<code>\(HTML.escape(a.body))</code>"
        case "poem":
            return "<div class=\"wiki-poem\">"
                + inlineLines(a.body, separator: "<br>") + "</div>"
        case "syntaxhighlight", "source": return MarkupHTML.listing(a.body, language: a.attrs["lang"]?.lowercased())
        case "math":
            let block = display || a.attrs["display"] == "block"
            return MathRenderer.html(a.body, display: block) ?? MathRenderer.fallback(a.body, display: block)
        case "ref":
            let content = a.body.isEmpty ? nil : inline(a.body)
            return references.add(content, name: a.attrs["name"], group: a.attrs["group"] ?? "")
        case "references": return referenceList(a.attrs["group"] ?? "")
        case "link": return link(a.body, trail: trail)
        case "template", "parameter": return template(a.body, block: block)
        case "gallery":
            var figures = ""
            for (index, line) in a.body.wikiFields(separatedBy: "\n").enumerated() {
                if index.isMultiple(of: 128), PreviewConversion.expired { return "" }
                if !line.isEmpty { figures += "<li>" + link(line.wikiTrim) + "</li>" }
            }
            return "<ul class=\"wiki-gallery\">" + figures + "</ul>"
        default:
            let tag = HTML.escape(a.body)
            return note(japanese ? "この文書では &lt;\(tag)&gt; を表示できません。" : "This document cannot display &lt;\(tag)&gt;.")
        }
    }

    func note(_ content: String) -> String { "<span class=\"wiki-note\">\(content)</span>" }
}

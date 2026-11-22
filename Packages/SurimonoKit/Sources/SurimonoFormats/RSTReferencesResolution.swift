import Foundation

extension RSTDocument {
    /// Docutils names a section from its unexpanded text, while the title and the contents
    /// display the expansion. Neither pass should register links or allocate footnote numbers.
    func rstHeadingText(_ html: String) -> String {
        var expansion = RSTExpansion()
        let content = headingLabels(html, expanding: false, expansion: &expansion)
        return DocumentOutline.plainText(ofHTML: content)
    }

    func finishHeadingText() {
        var expansion = RSTExpansion()
        for i in anchors.indices {
            let heading = anchors[i]
            guard let content = references.headingContent[heading.id], content.contains(references.prefix) else {
                continue
            }
            let text = DocumentOutline.plainText(ofHTML: headingLabels(content, expanding: true, expansion: &expansion))
            let name = RSTReferences.name(heading.text)
            if references.targets[name] == nil { references.targets[name] = .address("#" + heading.id) }
            if promotedHeadingIDs.contains(heading.id), title == heading.text { title = text }
            anchors[i] = .init(level: heading.level, id: heading.id, text: text)
        }
    }

    private func headingLabels(_ html: String, expanding: Bool, expansion: inout RSTExpansion) -> String {
        rstWalk(html) { _, token in
            switch token {
            case .link(_, let label, _): return label
            case .noteUse(let name): return HTML.escape("[\(name)]")
            case .substitution(let name, _):
                let key = references.substitutionKey(name)
                guard expanding, !expansion.names.contains(key), expansion.names.count < 32,
                    let sub = references.substitutions[key], expansion.visitsRemaining > 0,
                    expansion.bytesRemaining >= (sub.html ?? sub.value).utf8.count
                else { return HTML.escape(name) }
                expansion.names.insert(key)
                expansion.visitsRemaining -= 1
                expansion.bytesRemaining -= (sub.html ?? sub.value).utf8.count
                defer { expansion.names.remove(key) }
                return headingLabels(rstSubstitution(sub), expanding: true, expansion: &expansion)
            default: return ""
            }
        }
    }

    func finishReferences(_ html: String) -> String {
        guard !references.tokens.isEmpty else { return html }
        for anchor in anchors {
            let key = RSTReferences.name(anchor.text)
            if references.targets[key] == nil { references.targets[key] = .address("#" + anchor.id) }
        }
        var expansion = RSTExpansion()
        let expanded = rstExpand(html, depth: 0, expansion: &expansion)
        if references.tokens.contains(where: { if case .targetNotes = $0 { true } else { false } }) {
            var urls: [String: String] = [:]
            for i in references.renderedLinks {
                let token = references.tokens[i]
                guard case .link(let name, _, _) = token, let url = references.destination(name),
                    url.contains("://") || url.hasPrefix("mailto:")
                else { continue }
                let key: String
                if let existing = urls[url] {
                    key = existing
                } else {
                    // This key cannot collide with a label written in the source.
                    key = "#\u{0}url\(i)"
                    urls[url] = key
                    let index = references.notes.count
                    let id = references.id("", kind: "footnote")
                    let content = "<p>\(rstLink(url, label: HTML.escape(url)))</p>"
                    references.notes.append(.init(name: key, id: id, label: "", body: content))
                    references.targetNoteDefinitions.append(index)
                }
                references.targetNoteRefs[i] = references.addNoteRef(key)
            }
        }
        issueCount += references.numberNotes()
        return rstResolve(expanded)
    }

    /// Keep both the work and the amount of generated prose bounded even for a substitution graph
    /// which doubles at every level. Direct source text and later paragraphs remain readable.
    private struct RSTExpansion {
        var names: Set<String> = []
        var bytesRemaining = 8_000_000
        var visitsRemaining = 100_000
    }

    private func rstWalk(
        _ html: String, trimmingSubstitutions: Bool = false, transform: (Int, RSTReferences.Token) -> String
    ) -> String {
        guard html.contains(references.prefix), let pattern = references.pattern else { return html }
        let source = html as NSString
        var cursor = 0
        var result = ""
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            guard let i = Int(source.substring(with: match.range(at: 1))), references.tokens.indices.contains(i)
            else { continue }
            let start = match.range.location
            var gap = source.substring(with: NSRange(location: cursor, length: max(0, start - cursor)))
            cursor = NSMaxRange(match.range)
            let token = references.tokens[i]
            if trimmingSubstitutions, case .substitution(let label, _) = token,
                let sub = references.substitutions[references.substitutionKey(label)]
            {
                if sub.options["trim"] != nil || sub.options["ltrim"] != nil {
                    while gap.last?.isWhitespace == true { gap.removeLast() }
                }
                if sub.options["trim"] != nil || sub.options["rtrim"] != nil {
                    while cursor < source.length, let scalar = UnicodeScalar(source.character(at: cursor)),
                        CharacterSet.whitespacesAndNewlines.contains(scalar)
                    { cursor += 1 }
                }
            }
            result += gap
            result += transform(i, token)
        }
        return result + source.substring(from: cursor)
    }

    private func rstExpand(_ html: String, depth: Int, expansion: inout RSTExpansion) -> String {
        rstWalk(html, trimmingSubstitutions: true) { i, token in
            switch token {
            case .link(let name, let label, let original):
                var key = name
                if name == "\u{0}anon" {
                    references.anonymousReferences += 1
                    key = "\u{0}anon\(references.anonymousReferences)"
                }
                references.renderedLinks.append(references.tokens.count)
                return references.mark(.link(name: key, label: label, source: original))
            case .substitution(let name, let suffix):
                let key = references.substitutionKey(name)
                guard let sub = references.substitutions[key], depth < 32, !expansion.names.contains(key),
                    expansion.visitsRemaining > 0, expansion.bytesRemaining >= (sub.html ?? sub.value).utf8.count
                else {
                    issueCount += 1
                    return HTML.escape("|\(name)|" + String(repeating: "_", count: suffix))
                }
                expansion.names.insert(key)
                expansion.visitsRemaining -= 1
                expansion.bytesRemaining -= (sub.html ?? sub.value).utf8.count
                let text = rstSubstitution(sub)
                let resolved = rstExpand(text, depth: depth + 1, expansion: &expansion)
                expansion.names.remove(key)
                if suffix > 0 {
                    let mark = rstNamedLink(
                        name, label: resolved, source: "|\(name)|" + String(repeating: "_", count: suffix),
                        anonymous: suffix == 2)
                    return rstExpand(mark, depth: depth + 1, expansion: &expansion)
                }
                return resolved
            case .noteUse(let name):
                return references.mark(.noteReference(references.addNoteRef(name)))
            case .note(let index):
                let text = rstExpand(references.notes[index].body, depth: depth + 1, expansion: &expansion)
                references.notes[index].body = text
            default: break
            }
            return references.prefix + String(i) + ";"
        }
    }

    private func rstResolve(_ html: String) -> String {
        rstWalk(html) { i, token in
            switch token {
            case .link(let name, let label, let original):
                guard let url = references.destination(name) else {
                    issueCount += 1
                    return HTML.escape(original)
                }
                var linked = rstLink(url, label: rstResolve(label))
                if let ref = references.targetNoteRefs[i] { linked += " " + rstNoteReference(ref) }
                return linked
            case .noteReference(let index): return rstNoteReference(index)
            case .note(let index): return rstResolve(rstNote(index))
            case .targetNotes: return references.targetNoteDefinitions.map { rstNote($0) }.joined(separator: "\n")
            case .substitution, .noteUse: return ""
            }
        }
    }

    private func rstNoteReference(_ index: Int) -> String {
        let ref = references.noteRefs[index]
        guard let definition = ref.definition else {
            issueCount += 1
            return HTML.escape("[\(ref.name)]_")
        }
        let note = references.notes[definition]
        let role = note.citation ? "doc-biblioref" : "doc-noteref"
        return "<a role=\"\(role)\" id=\"\(ref.id)\" href=\"#\(note.id)\">[\(HTML.escape(note.label))]</a>"
    }

    private func rstNote(_ index: Int) -> String {
        let note = references.notes[index]
        let label = HTML.escape(note.label)
        let role = note.citation ? "doc-biblioentry" : "doc-footnote"
        let tag = note.citation ? "div" : "aside"
        let header = "<span class=\"label\">[\(label)]</span>"
        return "<\(tag) role=\"\(role)\" id=\"\(note.id)\">\(header)\(note.body)</\(tag)>"
    }

    private func rstSubstitution(_ substitution: RSTReferences.Substitution) -> String {
        if let html = substitution.html { return html }
        let value = substitution.value
        switch substitution.kind {
        case "unicode":
            var output = ""
            for token in value.split(whereSeparator: \.isWhitespace) {
                let code = String(token)
                let prefixes = ["u+", "u", "0x", "x", "\\x", "&#x"]
                let lowercase = code.lowercased()
                var scalar: UnicodeScalar?
                if let prefix = prefixes.first(where: { lowercase.hasPrefix($0) }) {
                    let digits = code.dropFirst(prefix.count).prefix(while: { $0 != ";" })
                    scalar = UInt32(digits, radix: 16).flatMap(UnicodeScalar.init)
                } else if let integer = UInt32(code) {
                    scalar = UnicodeScalar(integer)
                }
                output += scalar.map(String.init) ?? code
            }
            return HTML.escape(output)
        case "date":
            var date = time(nil)
            var parts = tm()
            guard localtime_r(&date, &parts) != nil else { return HTML.escape(value) }
            var buffer = [CChar](repeating: 0, count: 2048)
            let count = strftime(&buffer, buffer.count, value.isEmpty ? "%Y-%m-%d" : value, &parts)
            return HTML.escape(String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        default: return HTML.escape(value)
        }
    }
}

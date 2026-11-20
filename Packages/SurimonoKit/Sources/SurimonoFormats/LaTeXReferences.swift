import Foundation

extension LaTeXDocument {
    /// A use can precede its target and needs the naming conventions that were in force when it was read.
    struct Reference {
        let command: String
        let keys: [String]
        let names: [String: ReferenceNames]
        var text: String?
    }

    /// Store the kind and plain title alongside the numbered destination for typed references and \nameref.
    struct TargetDescription {
        let kind: String
        let title: String
    }

    /// Authors can specify both forms, including irregular plurals that cannot be inferred from the singular.
    struct ReferenceNames {
        let singular: String
        let plural: String
    }

    /// References can point forward. Freeze the naming conventions at the use, independently of the target.
    func setReferenceNames(_ key: String, names: ReferenceNames?) {
        if sharesReferenceNames {
            let cost = referenceNames.count
            // Stop expansion after 200,000 copied entries so repeated renaming cannot keep cloning a large dictionary.
            guard cost <= 200_000 - nameCopies else {
                stopsExpanding = true
                return
            }
            nameCopies += cost
            sharesReferenceNames = false
        }
        referenceNames[key] = names
    }

    /// Save a redefined \<kind>autorefname with the other names a forward reference will need.
    func didDefineMacro(_ name: String) {
        if LaTeXLanguage.captions["en"]?[name] != nil || name == "today" {
            macros[name]?.captionLanguage = language
        }
        guard name.hasSuffix("autorefname") else { return }
        let kind = String(name.dropLast("autorefname".count))
        let text = macros[name].map { String($0.body.prefix(300)) }
        setReferenceNames("auto:" + kind, names: text.map { .init(singular: $0, plural: $0) })
    }

    /// Keep title text for \nameref so copying a caption into a link cannot duplicate its markup or anchors.
    func describeTarget(_ id: String, kind: String, title: String) {
        let plain = title.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        targetDescriptions[id] = TargetDescription(kind: kind, title: HTML.unescape(String(plain.prefix(4_000))))
    }

    // A link interrupts WebKit's Japanese–Latin spacing on both sides of a generated counter.
    func spacedReference(_ index: Int, in source: NSString, range: NSRange) -> String {
        let html = referenceHTML(index)
        guard classInfo.profile.body.spacesLinkedCounters, language == "ja", references.indices.contains(index),
            ["ref", "pageref"].contains(references[index].command),
            let key = references[index].keys.first, let number = labels[key]?.number,
            number.first?.isASCII == true, number.last?.isASCII == true
        else { return html }

        func skip(at offset: Int) -> String {
            guard offset >= 0, offset < source.length,
                let scalar = Unicode.Scalar(source.character(at: offset)),
                scalar.properties.generalCategory == .otherLetter,
                LaTeXSymbols.isCJK(Character(scalar))
            else { return "" }
            return #"<span class="latex-xkanjiskip"></span>"#
        }
        return skip(at: range.location - 1) + html + skip(at: NSMaxRange(range))
    }

    /// Group by kind in first-use order so each run of numbers shares a name and each number retains its own link.
    func referenceHTML(_ index: Int) -> String {
        guard references.indices.contains(index) else { return "" }
        guard resolvingReferences.count < Self.maximumDepth, resolvingReferences.insert(index).inserted else {
            return "??"
        }
        defer { resolvingReferences.remove(index) }
        let reference = references[index]
        var groups: [[String]] = []
        var positions: [String: Int] = [:]
        for key in reference.keys {
            let kind = labels[key].flatMap { targetDescriptions[$0.id]?.kind } ?? ""
            if let position = positions[kind] {
                groups[position].append(key)
            } else {
                positions[kind] = groups.count
                groups.append([key])
            }
        }
        return groups.map { groupHTML($0, reference: reference) }.joined(separator: isJapanese ? "、" : " and ")
    }

    /// English joins lists with a final “and” and ranges with “to”. Japanese uses ・ and 〜 with one shared name.
    private func groupHTML(_ keys: [String], reference: Reference) -> String {
        guard let first = keys.first, let target = labels[first] else {
            return "<span class=\"latex-missing\">??</span>"
        }
        let metadata = targetDescriptions[target.id]
        let command = reference.command
        let kind = metadata?.kind ?? ""
        let name = referenceName(kind, reference: reference, plural: keys.count > 1)
        let typed = ["cref", "Cref", "autoref", "vref", "crefrange"].contains(command)
        var html = ""
        for (index, key) in keys.enumerated() {
            guard let target = labels[key] else { continue }
            if index > 0 {
                if command == "crefrange" {
                    html += isJapanese ? "〜" : " to "
                } else if isJapanese {
                    html += "・"
                } else {
                    html += index == keys.count - 1 ? " and " : ", "
                }
            }
            let number = target.number.utf8.count > 300 ? String(target.number.prefix(100)) + "…" : target.number
            var text = HTML.escape(number)
            let japaneseSection =
                isJapanese && ["chapter", "section", "subsection", "subsubsection"].contains(kind)
                && name == defaultName(kind)
            if command == "eqref" || kind == "equation" && (typed || command == "labelcref") { text = "(" + text + ")" }
            if typed && index == 0 && !name.isEmpty { text = (japaneseSection ? "第" : HTML.escape(name)) + " " + text }
            // For the default Japanese heading name, 第 and 節 (or 章) enclose the whole list or range.
            if typed && japaneseSection && index == keys.count - 1 { text += " " + HTML.escape(name) }
            if command == "namecref" { text = HTML.escape(name) }
            if command == "nameref" { text = HTML.escape(String((metadata?.title ?? "").prefix(4_000))) }
            if let own = reference.text { text = own }
            if text.contains("\u{E000}\(nonce)") {
                // A heading or custom link caption can refer forward, even to itself. Keep its resolved
                // words inside the outer link without nesting anchors or expanding a cycle.
                // Use an ellipsis past 20 KB in one caption so repeated titles cannot dominate the link text.
                guard nestedReferenceWork >= text.utf8.count else { return "…" }
                nestedReferenceWork -= text.utf8.count
                text =
                    filled(text, below: citations.count, limit: 20_000)?.replacingOccurrences(
                        of: #"</?a\b[^>]*>"#, with: "", options: .regularExpression) ?? "…"
            }
            // Pagination comes later. The initial text reserves space until the measured page label replaces it.
            let attribute: String
            if command == "pageref" {
                attribute = " class=\"latex-pageref\""
            } else if command == "nameref" || command == "namecref" || reference.text != nil {
                attribute = ""
            } else {
                // A counter reference keeps its upright form inside an italic theorem, regardless of
                // the target's kind or the author's choice of digits, letters, or Roman numerals.
                attribute = " class=\"latex-number-ref\""
            }
            html += "<a\(attribute) href=\"#\(HTML.escape(target.id))\">\(text)</a>"
        }
        return html
    }

    private func defaultName(_ kind: String) -> String {
        if let theorem = theorems[kind] { return String(theorem.title.prefix(300)) }
        if isJapanese {
            return [
                "part": "部", "chapter": "章", "section": "節", "subsection": "小節", "subsubsection": "小節",
                "appendix": "付録", "figure": "図", "table": "表", "equation": "式", "listing": "リスト",
                "footnote": "脚注", "item": "項目",
            ][kind] ?? kind
        }
        return kind
    }

    /// Supplied forms take precedence. English inflects the default name for a group, while Japanese reuses it.
    private func referenceName(_ kind: String, reference: Reference, plural: Bool) -> String {
        let command = reference.command
        if command == "autoref" {
            if let custom = reference.names["auto:" + kind] { return custom.singular }
            let name = defaultName(kind)
            return isJapanese ? name : name.prefix(1).uppercased() + name.dropFirst()
        }
        let upper = command == "Cref"
        if let names = reference.names[(upper ? "C:" : "c:") + kind] {
            return plural ? names.plural : names.singular
        }
        let lowerNames = reference.names["c:" + kind]
        var name = lowerNames.map { plural ? $0.plural : $0.singular } ?? defaultName(kind)
        if !isJapanese {
            if lowerNames == nil {
                name = name.prefix(1).lowercased() + name.dropFirst()
                if plural {
                    name =
                        name == "appendix"
                        ? "appendices" : name.hasSuffix("y") ? String(name.dropLast()) + "ies" : name + "s"
                }
            }
            if upper { name = name.prefix(1).uppercased() + name.dropFirst() }
        }
        return name
    }
}

extension LaTeXReader {
    /// Save the reference here and fill its placeholder once even forward labels have acquired destinations.
    func handleReference(_ name: String) -> Bool {
        switch name {
        case "crefname", "Crefname":
            let key = (name == "crefname" ? "c:" : "C:") + (argument() ?? "")
            let singular = inline(argument() ?? "")
            let plural = inline(argument() ?? "")
            func plain(_ html: String) -> String {
                let text = html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                return String(HTML.unescape(text).prefix(300))
            }
            document.setReferenceNames(key, names: .init(singular: plain(singular), plural: plain(plural)))
        case "ref", "eqref", "autoref", "cref", "Cref", "pageref", "vref", "nameref", "namecref", "labelcref",
            "crefrange", "hyperref":
            var keys: [String]
            var text: String?
            if name == "hyperref" {
                keys = [optional() ?? ""]
                text = inline(argument() ?? "")
            } else {
                let key = argument() ?? ""
                keys = ["cref", "Cref", "labelcref"].contains(name) ? key.components(separatedBy: ",") : [key]
                if name == "crefrange" { keys.append(argument() ?? "") }
            }
            document.sharesReferenceNames = true
            document.references.append(
                .init(
                    command: name, keys: keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                    names: document.referenceNames, text: text))
            appendHTML(styledLinks(document.placeholder("R", document.references.count - 1)))
        case "hypertarget", "hyperlink":
            let id = HTML.escape(argument() ?? "")
            let text = inline(argument() ?? "")
            appendHTML(
                name == "hypertarget"
                    ? "<span id=\"\(id)\">\(text)</span>" : styledLinks("<a href=\"#\(id)\">\(text)</a>"))
        default: return false
        }
        return true
    }
}

extension LaTeXDocument {
    /// A formula that refers forward must keep the math definitions in effect at its source position.
    struct ReferencedFormula {
        let latex: String
        let display: Bool
        let fallback: String
        let macros: String
        let numbers: [String?]
    }

    private static let mathReference = try? NSRegularExpression(pattern: #"\\(eqref|ref)\s*\{([^{}]*)\}"#)

    /// Only formulae containing references wait for the label pass. Save the macros in force at their source.
    func renderFormula(_ index: Int) -> String {
        guard deferredMath.indices.contains(index), let regex = Self.mathReference else { return "" }
        let formula = deferredMath[index]
        let source = formula.latex as NSString
        var latex = ""
        var cursor = 0
        for match in regex.matches(in: formula.latex, range: NSRange(location: 0, length: source.length)) {
            latex += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let key = source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let number = String((labels[key]?.number ?? "??").prefix(100))
            let escaped = LaTeXSymbols.mathText(number)
            latex +=
                source.substring(with: match.range(at: 1)) == "eqref" ? "\\text{(\(escaped))}" : "\\text{\(escaped)}"
            cursor = NSMaxRange(match.range)
        }
        latex += source.substring(from: cursor)
        return mathHTML(
            latex, display: formula.display, macros: formula.macros, source: formula.fallback, numbers: formula.numbers)
    }

    /// Failed equations keep their source on paper. Limit the diagnostic excerpts so a damaged
    /// document cannot fill the print check panel with a second copy of its entire math source.
    func mathHTML(_ latex: String, display: Bool, macros: String, source: String, numbers: [String?]) -> String {
        if let rendered = MathRenderer.html(
            latex, display: display, macros: macros, rowNumberHTML: numbers,
            measureRows: classInfo.profile.body.alignsDisplayRows)
        {
            return rendered
        }
        let issue = (isJapanese ? "数式を描けません: " : "Formula could not be typeset: ") + String(source.prefix(100))
        if !seenFormulaIssues.contains(issue), reserveExpansion(characters: issue.utf8.count) {
            seenFormulaIssues.insert(issue)
            failedFormulas.append(issue)
        }
        return MathRenderer.fallback(source, display: display)
    }
}

extension LaTeXReader {
    /// Give labels in unnumbered math a destination without adding an equation number to the page.
    func mathAnchor(_ labels: [String], tag: String?) -> String {
        guard !labels.isEmpty else { return "" }
        // An unnumbered formula may label the surrounding numbered object. A standalone label still gets a link.
        let number = tag ?? document.labelTarget?.number ?? "??"
        return "<span id=\"\(registerTag(number, labels: labels))\"></span>"
    }
}

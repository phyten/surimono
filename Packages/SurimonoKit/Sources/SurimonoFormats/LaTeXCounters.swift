import Foundation

/// Reset relationships are independent of printed prefixes: a counter declared with `\newcounter{x}[section]`
/// starts over each section, but only `\counterwithin{x}{section}` changes how its number is printed.
final class LaTeXCounters {
    static let levels = ["chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph"]
    static let listLevels = ["enumi", "enumii", "enumiii", "enumiv"]

    // Built-in and user counters share values so \setcounter affects the next heading, caption or item too.
    var defaultSectionDepth = 3
    private var values: [String: Int] = [:]
    private var children: [String: Set<String>] = [:]
    private var prefixes: [String: (parent: String, omitNonpositiveParent: Bool)] = [:]
    private var usedAnchors: Set<String> = []
    private var nextAnchor = 0
    var formatting: Set<String> = []

    init() {
        for name in Self.levels + Self.listLevels + [
            "part", "figure", "table", "equation", "footnote", "listing",
        ] {
            values[name] = 0
        }
        for (parent, child) in zip(Self.levels.dropFirst(), Self.levels.dropFirst(2)) {
            within(child, parent: parent, prefix: true)
        }
    }

    subscript(_ name: String) -> Int {
        get { values[name] ?? (name == "secnumdepth" || name == "tocdepth" ? defaultSectionDepth : 0) }
        set { values[name] = newValue }
    }

    func contains(_ name: String) -> Bool { values[name] != nil || name == "secnumdepth" || name == "tocdepth" }

    /// Saturate on overflow so adding to an extreme counter value cannot abort conversion.
    func add(_ amount: Int, to name: String) {
        let (sum, overflow) = self[name].addingReportingOverflow(amount)
        self[name] = overflow ? (amount < 0 ? Int.min : Int.max) : sum
    }

    /// Record the reset even when the starred command preserves the current printed form.
    func within(_ name: String, parent: String, prefix: Bool, omitNonpositiveParent: Bool = false) {
        guard !name.isEmpty, !parent.isEmpty, name != parent else { return }
        children[parent, default: []].insert(name)
        if prefix { prefixes[name] = (parent, omitNonpositiveParent) }
    }

    func printedParent(of name: String) -> String? {
        guard let prefix = prefixes[name], !prefix.omitNonpositiveParent || self[prefix.parent] > 0 else { return nil }
        return prefix.parent
    }

    /// Removing one reset relationship should leave a printed prefix supplied by a different parent intact.
    func without(_ name: String, parent: String, removePrefix: Bool) {
        children[parent]?.remove(name)
        if removePrefix, prefixes[name]?.parent == parent { prefixes[name] = nil }
    }

    /// Stepping a parent starts every counter that counts within it, including indirect descendants, back at zero.
    func advance(_ name: String) {
        add(1, to: name)
        // User-defined counters can form a graph. Walk it once, even when a malformed reset list has a cycle.
        var parents = [name]
        var seen: Set<String> = [name]
        while let parent = parents.popLast(), let descendants = children[parent] {
            for child in descendants where seen.insert(child).inserted {
                self[child] = 0
                if children[child] != nil { parents.append(child) }
            }
        }
    }

    /// Keep familiar IDs for ordinary numbers. Redefining the printed form or resetting a counter must not give
    /// two targets the same destination, or let punctuation in a number change the HTML.
    func anchor(_ prefix: String, suffix: String) -> String {
        let safe = suffix.prefix(150).map { char in
            char.isASCII && (char.isLetter || char.isNumber || "-_.".contains(char)) ? char : "-"
        }
        let base = prefix + "-" + String(safe)
        var id = base
        while !usedAnchors.insert(id).inserted {
            nextAnchor += 1
            id = "\(base)-\(nextAnchor)"
        }
        return id
    }
}

extension LaTeXReader {
    /// Counter commands in prose use the same state that supplies printed numbers and references.
    func handleCounter(_ name: String) -> Bool {
        if handleRegister(name) { return true }
        func key() -> String { (argument() ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        switch name {
        case "newcounter":
            let counter = key()
            document.counters[counter] = 0
            if let parent = optional() { document.counters.within(counter, parent: parent, prefix: false) }
        case "setcounter", "addtocounter":
            let counter = key()
            let operand = key()
            guard let value = integerArgument(operand) else { return true }
            if name == "setcounter" {
                if counter == "page" { pageAction("page", String(value)) }
                document.counters[counter] = value
            } else {
                document.counters.add(value, to: counter)
            }
        case "stepcounter": document.counters.advance(key())
        case "refstepcounter":
            let counter = key()
            let number = stepCounter(counter)
            let id = document.counters.anchor("counter", suffix: counter + "-" + number)
            // \refstepcounter creates a destination even without a heading, so a following \label names this step.
            document.labelTarget = (number, id)
            document.describeTarget(id, kind: counter, title: "")
            appendDestination("<span id=\"\(id)\"></span>")
        case "value", "arabic", "roman", "Roman", "alph", "Alph", "fnsymbol":
            appendText(LaTeXSymbols.format(document.counters[key()], as: name))
        case "counterwithin", "counterwithout", "numberwithin":
            let preserveFormat = star()
            let counter = key()
            let parent = key()
            if !preserveFormat { document.macros["the" + counter] = nil }
            if name == "counterwithout" {
                document.counters.without(counter, parent: parent, removePrefix: !preserveFormat)
            } else {
                document.counters.within(counter, parent: parent, prefix: !preserveFormat)
            }
        case "newtheorem": newTheorem()
        case "declaretheorem": declareTheorem()
        case "theoremstyle": document.theoremStyle = key()
        default:
            guard name.hasPrefix("the") else { return false }
            let counter = String(name.dropFirst(3))
            guard document.counters.contains(counter) || document.theorems[counter]?.counter != nil else {
                return false
            }
            appendText(formattedCounter(counter))
        }
        return true
    }

    /// Return the new printed value, including its parent when numbered within one (theorem 2.3 is the third in §2).
    func stepCounter(_ name: String) -> String {
        document.counters.advance(name)
        return formattedCounter(name)
    }

    /// The current counter as \the<name> prints it. For a heading, \thesection includes the configured levels above it.
    func formattedCounter(_ name: String, forMath: Bool = false) -> String {
        let counters = document.counters
        guard counters.formatting.count < LaTeXDocument.maximumDepth, StackSpace.hasRoom,
            counters.formatting.insert(name).inserted
        else {
            document.stopExpanding(.depth)
            return String(counters[name])
        }
        defer { counters.formatting.remove(name) }
        if name == "equation", let prefix = document.subequationPrefix {
            return prefix + LaTeXSymbols.format(counters[name], as: "alph")
        }
        if !document.stopsExpanding, document.macros["the" + name] != nil {
            // Keep the macro token until the math pass can substitute it, without running text-mode assignments.
            if forMath { return "\\the" + name }
            let html = inline("\\the" + name)
            let text = HTML.unescape(html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            return text.utf8.count > 300 ? String(text.prefix(100)) + "…" : text
        }
        if let shared = document.theorems[name]?.counter, shared != name {
            return formattedCounter(shared, forMath: forMath)
        }
        let style: String
        if document.isAppendix, name == (document.hasChapters ? "chapter" : "section") {
            style = "Alph"
        } else {
            switch name {
            case "part": style = "Roman"
            case "enumii": style = "alph"
            case "enumiii": style = "roman"
            case "enumiv": style = "Alph"
            default: style = "arabic"
            }
        }
        let value = LaTeXSymbols.format(counters[name], as: style)
        // jsarticle prefixes only the appendix section itself. Its subsections keep A.1, A.2, etc.
        if name == "section", document.classInfo.profile.headings.labelsAppendixSection, document.isAppendix,
            document.language == "ja",
            !counters.formatting.contains("subsection")
        {
            let caption = captionName("appendixname")
            let plain = HTML.unescape(
                caption.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            return plain.isEmpty ? value : plain + " " + value
        }
        let form = document.classInfo.profile.headings.counterForm
        if form == .spacedHierarchy {
            switch name {
            case "section": return value + "."
            case "paragraph": return LaTeXSymbols.format(counters[name], as: "alph") + " )"
            case "subparagraph": return LaTeXSymbols.format(counters[name], as: "roman") + " )"
            case "subsection", "subsubsection":
                if let parent = counters.printedParent(of: name) {
                    let prefix = formattedCounter(parent, forMath: forMath)
                    return prefix + (prefix.hasSuffix(".") ? " " : ". ") + value
                }
            default: break
            }
        } else if form == .parenthesizedParagraph {
            if name == "paragraph" { return "(" + value + ")" }
            if name == "subparagraph" {
                return "(" + formattedCounter("paragraph", forMath: forMath) + "." + value + ")"
            }
        }
        guard let parent = counters.printedParent(of: name) else { return value }
        return formattedCounter(parent, forMath: forMath) + "." + value
    }

    /// Reserve one parent equation number so lettered children do not advance the next ordinary equation.
    func subequations(_ body: String) {
        let prefix = stepCounter("equation")
        let value = document.counters["equation"]
        let outerPrefix = document.subequationPrefix
        let formatter = document.macros.removeValue(forKey: "theequation")
        defer {
            document.counters["equation"] = value
            document.subequationPrefix = outerPrefix
            document.macros["theequation"] = formatter
        }
        let id = document.counters.anchor("eq", suffix: prefix)
        document.describeTarget(id, kind: "equation", title: "")
        document.labelTarget = (prefix, id)
        document.subequationPrefix = prefix
        document.counters["equation"] = 0
        appendBlock("<div id=\"\(id)\">\n\(blocks(body))</div>\n")
    }

    /// `\newtheorem{name}{Title}`, `\newtheorem{name}[shared]{Title}`, `\newtheorem{name}{Title}[parent]` and
    /// `\newtheorem*{name}{Title}`.
    private func newTheorem() {
        let starred = star()
        guard let name = argument()?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        let shared = optional()?.trimmingCharacters(in: .whitespaces)
        let title = argument() ?? ""
        let parent = shared == nil ? optional()?.trimmingCharacters(in: .whitespaces) : nil
        registerTheorem(
            name, title: title, shared: shared, parent: parent, style: document.theoremStyle, numbered: !starred)
    }

    /// Translate thmtools options to the same counter and style choices as an amsthm declaration.
    private func declareTheorem() {
        let options = optional()
        guard let name = argument()?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        registerTheorem(
            name, title: option("name", in: options) ?? name.capitalized, shared: option("sibling", in: options),
            parent: option("numberwithin", in: options), style: option("style", in: options) ?? document.theoremStyle,
            numbered: true)
    }

    /// A sibling may already share its counter. Use that underlying counter so the entire group advances together.
    private func registerTheorem(
        _ name: String, title: String, shared: String?, parent: String?, style: String, numbered: Bool
    ) {
        let counter = numbered ? (shared.flatMap { document.theorems[$0]?.counter } ?? shared ?? name) : nil
        if let counter {
            if !document.counters.contains(counter) { document.counters[counter] = 0 }
            if let parent { document.counters.within(counter, parent: parent, prefix: true) }
        }
        let style = ["plain", "definition", "remark"].contains(style) ? style : "plain"
        document.theorems[name] = .init(title: title, counter: counter, style: style)
        document.theoremHeadings[name] = nil
    }

    private static let theoremNames = [
        "theorem": "定理", "lemma": "補題", "proposition": "命題", "corollary": "系", "definition": "定義",
        "example": "例", "remark": "注意", "note": "注意", "claim": "主張", "conjecture": "予想", "axiom": "公理",
        "assumption": "仮定", "exercise": "演習", "problem": "問題", "solution": "解答",
    ]

    /// Some classes supply these environments without a declaration in the paper. Create them on first use.
    func conventionalTheorem(_ name: String) -> LaTeXDocument.Theorem? {
        let title: String
        if let translation = Self.theoremNames[name] {
            let nameMacro = name + "name"
            title =
                document.macros[nameMacro] != nil
                ? "\\" + nameMacro : document.isJapanese ? translation : name.capitalized
        } else if document.isJapanese && Self.theoremNames.values.contains(name) {
            title = name
        } else {
            return nil
        }
        let style =
            ["remark", "note", "注意"].contains(name)
            ? "remark" : ["definition", "example", "定義", "例"].contains(name) ? "definition" : "plain"
        registerTheorem(name, title: title, shared: nil, parent: nil, style: style, numbered: true)
        return document.theorems[name]
    }
}

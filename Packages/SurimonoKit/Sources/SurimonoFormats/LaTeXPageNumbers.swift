import Foundation

/// TeX changes page counters at the point where a page is shipped. The reader knows the
/// preamble state; only pagination can assign subsequent commands to actual pages.
public struct LaTeXPageNumbers: Equatable, Sendable {
    public private(set) var counter = 1
    public private(set) var format = "arabic"
    private var style = "plain"
    private var thisPageStyle: String?
    private var twoSided = false
    private var fields: [String: String] = [:]
    struct Definition: Codable, Equatable, Sendable {
        var name: String
        var base: String?
        var snapshotsFields: Bool
        var fields: [String: String] = [:]
        var snapshot: [String: String]?
    }

    private var definitions: [String: Definition] = [:]
    private var leftMark = ""
    private var rightMark = ""
    private var firstRightMark: String?

    public init() {
        fields = [
            "OLH": #"\rightmark"#, "ORH": #"\leftmark"#, "ELH": #"\rightmark"#, "ERH": #"\leftmark"#,
            "OCF": #"\thepage"#, "ECF": #"\thepage"#,
        ]
    }

    init(name: String, options: [String]) {
        self.init()
        twoSided =
            (options.last { $0 == "twoside" || $0 == "oneside" }).map { $0 == "twoside" }
            ?? ["book", "jsbook", "ltjsbook", "llncs"].contains(name)
        if twoSided {
            fields["OLH"] = #"\leftmark"#
            fields["ORH"] = #"\rightmark"#
        }
        if name == "IEEEtran" && options.contains("conference") || name == "llncs" {
            style = name == "llncs" && options.contains("runningheads") ? "runningheads" : "empty"
        }
    }

    public var label: String { LaTeXSymbols.format(counter, as: format) }
    public var showsFooter: Bool { footer.contains { !$0.isEmpty } }

    package var needsRunningMarks: Bool {
        func usesMarks(_ fields: [String: String]) -> Bool {
            fields.values.contains { $0.contains(#"\leftmark"#) || $0.contains(#"\rightmark"#) }
        }
        // A later thispagestyle can select a preamble definition using marks from earlier pages.
        return (usesClassPlain || thisPageStyle == "fancy" || !definitions.isEmpty)
            && (usesMarks(fields)
                || definitions.values.contains { usesMarks($0.fields) || $0.snapshot.map(usesMarks) == true })
    }

    package var usesClassPlain: Bool { style == "fancy" || definitions["plain"] != nil }

    private func selectedFields(_ name: String) -> [String: String]? {
        var chain: [Definition] = []
        var seen: Set<String> = []
        var next: String? = name
        var result = fields
        while let key = next, let definition = definitions[key], seen.insert(key).inserted {
            chain.append(definition)
            if let snapshot = definition.snapshot { result = snapshot }
            next = definition.base
        }
        guard !chain.isEmpty else { return name == "fancy" ? fields : nil }
        for definition in chain.reversed() {
            result.merge(definition.fields) { _, replacement in replacement }
        }
        return result
    }

    package var header: [String] { row("H") }
    package var footer: [String] { row("F") }

    private var activeFields: [String: String]? {
        selectedFields(thisPageStyle ?? style)
    }

    // Store rule macros alongside the six fields so named and starred page styles
    // inherit, override and snapshot them at the same time as their header text.
    package func ruleWidth(_ name: String) -> Double {
        guard let selected = activeFields else { return 0 }
        let length = selected[name] ?? (name == "headrulewidth" ? "0.4pt" : "0pt")
        return max(0, (LaTeXPageSettings.millimetres(length) ?? 0) * 72 / 25.4)
    }

    private func row(_ location: String) -> [String] {
        let even = twoSided && counter.isMultiple(of: 2)
        if let selected = activeFields {
            return ["L", "C", "R"].map { side in
                let source = selected[(even ? "E" : "O") + side + location] ?? ""
                return Self.text(source, page: label, left: leftMark, right: firstRightMark ?? rightMark)
            }
        }
        switch thisPageStyle ?? style {
        case "empty": return ["", "", ""]
        case "runningheads":
            return location == "F" ? ["", "", ""] : even ? [label, "", ""] : ["", "", label]
        default: return location == "F" ? ["", label, ""] : ["", "", ""]
        }
    }

    /// Furniture is plain PDF text. Read literal characters, escaped symbols and the three
    /// page-dependent commands without evaluating arbitrary macros at every shipout.
    static func text(_ source: String, page: String = "", left: String = "", right: String = "") -> String {
        var rest = source[...]
        var output = ""
        while let ch = rest.popFirst() {
            guard ch == "\\" else {
                if ch != "{" && ch != "}" { output.append(ch == "~" ? " " : ch) }
                continue
            }
            let word = rest.prefix { $0.isASCII && $0.isLetter }
            if word.isEmpty {
                if let symbol = rest.popFirst() { output.append(symbol == "," || symbol == "\\" ? " " : symbol) }
            } else {
                rest = rest.dropFirst(word.count).drop(while: { $0.isWhitespace })
                switch word {
                case "thepage": output += page
                case "leftmark": output += left
                case "rightmark": output += right
                case "quad", "qquad", "enspace": output += " "
                default: output += LaTeXSymbols.text[String(word)] ?? ""
                }
            }
        }
        return output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    mutating func define(_ definition: Definition) {
        var definition = definition
        if definition.snapshotsFields { definition.snapshot = fields }
        definitions[definition.name] = definition
    }

    package mutating func apply(_ action: String, value: String) {
        switch action {
        case "headrulewidth", "footrulewidth": fields[action] = value
        case "fancyStyle":
            if let definition = try? JSONDecoder().decode(Definition.self, from: Data(value.utf8)) {
                define(definition)
            }
        case "pagestyle":
            if let selected = selectedFields(value) {
                // pagestyle installs the fields in the running style. thispagestyle below applies
                // them only while shipping its page, leaving subsequent pages' fields untouched.
                fields = selected
                style = "fancy"
            } else {
                style = value
            }
        case "classPlain":
            if usesClassPlain { thisPageStyle = "plain" }
        case "thispagestyle": thisPageStyle = value
        case "pagenumbering":
            format = value
            counter = 1
        case "page": counter = Int(value) ?? counter
        case "leftmark": leftMark = value
        case "rightmark":
            rightMark = value
            if firstRightMark == nil { firstRightMark = value }
        default:
            if action.hasPrefix("fancy:") { Self.setFields(action.dropFirst(6), value: value, in: &fields) }
        }
    }

    static func setFields(_ selectors: Substring, value: String, in fields: inout [String: String]) {
        for selector in selectors.split(separator: ",", omittingEmptySubsequences: false) {
            guard selector.allSatisfy({ "OEHFLCR".contains($0) }) else { continue }
            func selected(_ letter: Character, group: String) -> Bool {
                selector.contains(letter) || !selector.contains(where: group.contains)
            }
            for parity in "OE" where selected(parity, group: "OE") {
                for location in "HF" where selected(location, group: "HF") {
                    for side in "LCR" where selected(side, group: "LCR") {
                        fields[String([parity, side, location])] = value
                    }
                }
            }
        }
    }

    package mutating func advance() {
        if counter < Int.max { counter += 1 }
        thisPageStyle = nil
        firstRightMark = nil
    }
}

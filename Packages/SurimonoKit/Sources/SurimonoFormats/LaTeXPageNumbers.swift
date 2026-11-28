import Foundation

/// TeX changes page counters at the point where a page is shipped. The reader knows the
/// preamble state; only pagination can assign subsequent commands to actual pages.
public struct LaTeXPageNumbers: Equatable, Sendable {
    public private(set) var counter = 1
    public private(set) var format = "arabic"
    private var style = "plain"
    private var thisPageStyle: String?
    private var amsHeadings = false
    private var japanesePlain = false
    private var twoSided = false
    private var examFirst: [String: String]?
    private var examRunning = [String: String]()
    // Like runningTitle, journal metadata belongs to the active page style's text fields.
    // A named fancy style can replace those fields without altering the document's title.
    private var journalLayout: LaTeXJournalPage.Layout? {
        get { fields["journalLayout"].flatMap(LaTeXJournalPage.Layout.init(rawValue:)) }
        set { fields["journalLayout"] = newValue?.rawValue }
    }
    package var usesJournalFurniture: Bool { journalLayout != nil }
    package var journalPageRange: String {
        get { fields["journalPageRange"] ?? "" }
        set { fields["journalPageRange"] = newValue }
    }

    mutating func setJournalIssue(_ issue: LaTeXJournalIssue) {
        issue.store(in: &fields)
    }

    package var journalPage: LaTeXJournalPage? {
        guard (thisPageStyle ?? style) == "journalIssue", let journalLayout else { return nil }
        return LaTeXJournalIssue(fields: fields).page(
            journalLayout, first: firstSheet, even: counter.isMultiple(of: 2), label: label,
            range: journalPageRange.isEmpty ? label : journalPageRange,
            doiPrefix: fields["journalDOIPrefix"], runningType: fields["runningArticleType"])
    }
    private var firstSheet = true
    var examTotals: [String: String] = [:]
    package var needsExamTotals: Bool {
        guard let examFirst else { return false }
        return [examFirst, examRunning].contains { fields in
            fields.values.contains { $0.contains(#"\numquestions"#) || $0.contains(#"\numpoints"#) }
        }
    }
    private var fields: [String: String] = [:]
    struct Definition: Codable, Equatable, Sendable {
        var name: String
        var base: String?
        var snapshotsFields: Bool
        var fields: [String: String] = [:]
        var snapshot: [String: String]?

        // Built-in styles start with an empty snapshot so fancyhdr declarations cannot leak into them.
        var isClassStyle: Bool { !snapshotsFields && snapshot?.isEmpty == true }
    }

    private var definitions: [String: Definition] = [:]
    /// The style a chapter opening its page uses while headings run, when the class names one other than plain.
    private var chapterOpeningStyle: String?
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
        self.init(LaTeXClassRegistry.resolve(.init(name: name, options: options)).pageStyle)
    }

    init(_ policy: LaTeXClassProfile.PageStyle) {
        self.init()
        japanesePlain = policy.japanesePlain
        twoSided = policy.twoSidedNumbers
        if policy.twoSidedFields {
            fields["OLH"] = #"\leftmark"#
            fields["ORH"] = #"\rightmark"#
        }
        switch policy.running {
        case .plain: break
        case .ams(let size):
            amsHeadings = true
            style = "headings"
            headerFont = LaTeXElementFont(sizeInPoints: size)
            numberFont = headerFont
        case .markedBook(let numberInHead, let ruled):
            // Independent definitions keep class furniture out of the user's fancyhdr fields.
            let number = #"\thepage"#
            var plain =
                numberInHead
                ? ["ELH": number, "ORH": number]
                : ["ELF": number, twoSided ? "ORF" : "OCF": number]
            plain["headrulewidth"] = "0pt"
            if ruled { plain["fullwidth"] = "true" }
            var running = plain
            if numberInHead {
                running["ERH"] = #"\leftmark"#
                running["OLH"] = ruled && !twoSided ? #"\leftmark"# : #"\rightmark"#
                if ruled {
                    numberFont = LaTeXElementFont(weight: "bold")
                    running["headrulewidth"] = "0.4pt"
                }
            } else {
                running["ELH"] = #"\leftmark"#
                running[twoSided ? "ORH" : "OCH"] = twoSided ? #"\rightmark"# : #"\leftmark"#
            }
            for (name, rows) in [("headings", running), ("plain", plain)] {
                definitions[name] = Definition(name: name, snapshotsFields: false, fields: rows, snapshot: [:])
            }
            style = "headings"
        case .verticalHead(let outer, let marks):
            let number = #"\thepage"#
            // pLaTeX's tbook mirrors jbook's head number, since recto pages are on the left. jlreq's tate plain
            // is its head number; tbook keeps plain's centred foot and opens a chapter under headings with
            // headnombre (\ps@jpl@in), so an explicit plain stays at the foot.
            let head = outer ? ["OLH": number, "ERH": number] : ["OCH": number, "ECH": number]
            var styles: [(String, [String: String])]
            if marks {
                var running = head
                running["ELH"] = #"\leftmark"#
                running["ORH"] = #"\rightmark"#
                styles = [
                    ("headings", running), ("headnombre", head), ("footnombre", ["OLF": number, "ERF": number]),
                    ("plain", ["OCF": number, "ECF": number]),
                ]
                chapterOpeningStyle = "headnombre"
                style = "headings"
            } else {
                styles = [("plain", head)]
                style = "plain"
            }
            for (name, fields) in styles {
                var rows = fields
                rows["headrulewidth"] = "0pt"
                definitions[name] = Definition(name: name, snapshotsFields: false, fields: rows, snapshot: [:])
            }
        case .exam:
            style = "headandfoot"
            examFirst = [:]
            examRunning["CF"] = #"Page \thepage"#
        case .empty: style = "empty"
        case .runningHeads: style = "runningheads"
        case .journalIssueLine: journalLayout = .issueAndCopyright
        case .journalReportTitle(let bilingual): journalLayout = bilingual ? .bilingualReport : .reportTitle
        case .ruledArticleType: journalLayout = .ruledType
        case .outerHeadNumber: journalLayout = .outerHeaderNumber
        case .technicalReportNotice: journalLayout = .reportNotice
        }
        if journalLayout != nil {
            style = "journalIssue"
            fields["journalDOIPrefix"] = policy.journalDOIPrefix
            fields["runningArticleType"] = policy.runningArticleType
        }
    }

    // Keep the title measurement with the fancy fields that it describes.
    package var runningTitle: String? { fields["runningTitle"] }
    package var runningTitleFallback: String? {
        get { fields["runningTitleFallback"] }
        set { fields["runningTitleFallback"] = newValue }
    }

    mutating func setRunningTitle(_ title: String) {
        // Flattening a line break would hide the reason the measured title box exceeds its height.
        let multiline = LaTeXLexer.split(title, at: [#"\\"#, #"\newline"#]).count > 1
        let header = multiline ? runningTitleFallback ?? title : title
        fields["runningTitle"] = Self.text(header)
        apply("pagestyle", value: "fancy")
        apply("fancy:H", value: "")
        apply("fancy:CH", value: header)
        apply("headrulewidth", value: "1pt")
        headerFont = LaTeXElementFont(weight: "bold", sizeInPoints: 9)
    }

    public var label: String { LaTeXSymbols.format(counter, as: format) }
    public var showsFooter: Bool { footer.contains { !$0.isEmpty } }
    var writesContentsMark: Bool { style == "headings" || style == "fancy" }

    package var needsRunningMarks: Bool {
        func usesMarks(_ fields: [String: String]) -> Bool {
            fields.values.contains { $0.contains(#"\leftmark"#) || $0.contains(#"\rightmark"#) }
        }
        // A later thispagestyle can select a preamble definition using marks from earlier pages.
        return amsHeadings && style == "headings"
            || (usesClassPlain || thisPageStyle == "fancy" || !definitions.isEmpty)
                && (usesMarks(fields)
                    || definitions.values.contains { usesMarks($0.fields) || $0.snapshot.map(usesMarks) == true })
    }

    package var usesClassPlain: Bool { amsHeadings || style == "fancy" || definitions["plain"] != nil }

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

    package var spansOuterMargin: Bool { activeFields?["fullwidth"] == "true" }

    package var usesFancyFields: Bool {
        activeFields != nil && definitions[thisPageStyle ?? style]?.isClassStyle != true
    }

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

    package private(set) var headerFont: LaTeXElementFont?
    package private(set) var numberFont: LaTeXElementFont?

    package func numberRanges(header: Bool) -> [[NSRange]] {
        guard numberFont != nil else { return [] }
        // Resolve the same field with a marker so a chapter number equal to the page is left alone.
        let marker = "\u{0}"
        return row(header ? "H" : "F", page: marker).map { field in
            let parts = field.components(separatedBy: marker)
            var offset = 0
            return parts.dropLast().map { prefix in
                offset += prefix.utf16.count
                let range = NSRange(location: offset, length: label.utf16.count)
                offset += range.length
                return range
            }
        }
    }

    private func row(_ location: String, page: String? = nil) -> [String] {
        if let journalPage { return location == "H" ? journalPage.top : journalPage.bottom }
        let label = page ?? self.label
        let even = twoSided && counter.isMultiple(of: 2)
        if let selected = activeFields {
            return ["L", "C", "R"].map { side in
                let source = selected[(even ? "E" : "O") + side + location] ?? ""
                return Self.text(source, page: label, left: leftMark, right: firstRightMark ?? rightMark)
            }
        }
        let currentStyle = thisPageStyle ?? style
        if let examFirst, ["head", "foot", "headandfoot"].contains(currentStyle) {
            let source = firstSheet ? examFirst : examRunning
            if currentStyle == "head" && location == "F" || currentStyle == "foot" && location == "H" {
                return ["", "", ""]
            }
            return ["L", "C", "R"].map { Self.text(source[$0 + location] ?? "", page: label, totals: examTotals) }
        }
        switch currentStyle {
        case "headings" where amsHeadings:
            guard location == "H" else { return ["", "", ""] }
            return even ? [label, leftMark.uppercased(), ""] : ["", rightMark.uppercased(), label]
        case "empty": return ["", "", ""]
        case "plainhead", "runningheads":
            return location == "F" ? ["", "", ""] : even ? [label, "", ""] : ["", "", label]
        default: return location == "F" ? ["", label, ""] : ["", "", ""]
        }
    }

    /// Furniture is plain PDF text. Read literal characters, escaped symbols and the three
    /// page-dependent commands without evaluating arbitrary macros at every shipout.
    static func text(
        _ source: String, page: String = "", left: String = "", right: String = "", totals: [String: String] = [:]
    ) -> String {
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
                case "numquestions", "numpoints": output += totals[String(word)] ?? "?"
                case "leftmark": output += left
                case "rightmark": output += right
                case "quad", "qquad", "enspace": output += " "
                default: output += LaTeXSymbols.text[String(word)] ?? ""
                }
            }
        }
        // TeX collapses source whitespace. Spaces with explicit widths in running marks survive shipout.
        return output.split { $0.isASCII && $0.isWhitespace }.joined(separator: " ")
    }

    mutating func define(_ definition: Definition) {
        var definition = definition
        if definition.snapshotsFields { definition.snapshot = fields }
        definitions[definition.name] = definition
    }

    package mutating func apply(_ action: String, value: String) {
        switch action {
        case "koma:pagehead", "koma:pagenumber":
            if let font = try? JSONDecoder().decode(LaTeXElementFont.self, from: Data(value.utf8)) {
                if action == "koma:pagehead" { headerFont = font } else { numberFont = font }
            }
        case "headrulewidth", "footrulewidth": fields[action] = value
        case "fancyStyle":
            if let definition = try? JSONDecoder().decode(Definition.self, from: Data(value.utf8)) {
                define(definition)
            }
        case "pagestyle":
            if definitions[value]?.isClassStyle == true {
                style = value
            } else if let selected = selectedFields(value) {
                // pagestyle installs the fields in the running style. thispagestyle below applies
                // them only while shipping its page, leaving subsequent pages' fields untouched.
                fields = selected
                style = "fancy"
            } else {
                style = value
            }
        case "classPlain":
            if style == "headings", definitions["headings"] != nil {
                thisPageStyle = chapterOpeningStyle ?? "plain"
            } else if japanesePlain {
                // plainifnotempty preserves empty front matter and uses the outer header
                // for a page number when the running style has installed a header.
                if style != "empty" {
                    thisPageStyle = style == "fancy" || style == "headings" ? "plainhead" : "plainfoot"
                }
            } else if usesClassPlain {
                thisPageStyle = "plain"
            }
        case "thispagestyle": thisPageStyle = value
        case "journalSupplement": style = "empty"
        case "pagenumbering":
            format = value
            counter = 1
        case "page": counter = Int(value) ?? counter
        case "leftmark": leftMark = value
        case "rightmark":
            rightMark = value
            if firstRightMark == nil { firstRightMark = value }
        default:
            if action.hasPrefix("exam:first:") { examFirst?[String(action.dropFirst(11))] = value }
            if action.hasPrefix("exam:running:") { examRunning[String(action.dropFirst(13))] = value }
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
        firstSheet = false
        if counter < Int.max { counter += 1 }
        thisPageStyle = nil
        firstRightMark = nil
    }
}

import Foundation

public struct ContentsFinish: Codable, Hashable, Sendable {
    public enum Edit: Sendable { case lead, finish }
    public enum Placement: String, Codable, Sendable { case inline, page }
    public enum InText: String, Codable, Sendable { case asWritten, hidden }

    public var placement = Placement.inline
    public var look = PaperTOC.Look.dotted
    public var inText = InText.asWritten
    public var showsContents = true
    public var showsFigures = true
    public var showsTables = true

    public init() {}

    init(legacy: PaperTOC) {
        placement = legacy.mode == .front ? .page : .inline
        look = legacy.look
        inText = legacy.showsSourceContents ? .asWritten : .hidden
        showsContents = legacy.showsSourceContents
        showsFigures = legacy.showsSourceContents
        showsTables = legacy.showsSourceContents
    }
}

extension PaperTOC {
    public var readingDepth: ReadingDepth { depth == .chapters ? .levels(1) : .levels(2) }

    /// Decide against the original reader output, before the finish hides or adds anything.
    public func canMigrate(format: DocumentFormat, facts: DocumentFacts) -> Bool {
        if mode == .source { return !facts.coalescesContentsInLegacy }
        guard format != .latex, !facts.contentsKinds.contains(.lead),
            facts.contentsInstructions.present?.value != true,
            OrgReadingSettings().resolve(.tableOfContents, file: facts.orgInstructions ?? .init()).source == nil
        else { return false }
        if mode == .hidden { return true }
        guard !facts.hasSourceContents, facts.contentsInstructions.present == nil,
            facts.contentsInstructions.depth == nil
        else { return false }
        // These readers can exclude, number or promote headings differently from the old front page.
        if [.org, .quarto, .rMarkdown].contains(format) {
            guard facts.proposedLeadDepth == readingDepth.headingLevels, let proposed = facts.leadEntries else {
                return false
            }
            let old = PaperContents.legacyHeadings(facts.headings, depth: readingDepth)
            guard old.count == proposed.count else { return false }
            // Org creates missing anchors only when a lead is requested. Without an old anchor,
            // a unique label is sufficient to identify the same heading and page.
            let counts = Dictionary(facts.headings.map { ($0.text, 1) }, uniquingKeysWith: +)
            return zip(old, proposed).allSatisfy { before, after in
                before.level == after.level && before.text == after.text
                    && (before.id.map { $0 == after.id } ?? (counts[before.text] == 1))
            }
        }
        return true
    }
}

extension PrintFinish {
    /// A legacy record runs the old CSS and page assembly until the document can adopt the new settings.
    public func contentsBody(
        _ fragment: HTMLFragment, facts: DocumentFacts, format: DocumentFormat, lead: ReadingDepth?,
        forPaper: Bool = false
    ) -> String {
        var facts = facts
        let prepared = preparingLead(in: fragment, facts: &facts, format: format, lead: lead)
        return placedBody(prepared, format: format, lead: lead, forPaper: forPaper)
    }

    package func preparingLead(
        in fragment: HTMLFragment, facts: inout DocumentFacts, format: DocumentFormat, lead: ReadingDepth?
    ) -> HTMLFragment {
        guard legacyTOC == nil, let lead, format != .latex, !facts.contentsKinds.contains(.lead) else {
            return fragment
        }
        if let proposed = fragment.proposedLeadContents {
            return contents.placement == .page ? fragment : fragment.prependingLead(proposed.html)
        }
        // An empty native list may mean the reader explicitly excluded every heading.
        guard format != .org,
            facts.contentsInstructions.present?.value != true
                || fragment.coalescesContentsInLegacy && format == .mediawiki
        else { return fragment }
        let prepared = fragment.addingLeadContents(headings: &facts.headings, depth: lead)
        facts.leadEntries = prepared.leadEntries
        return prepared
    }

    package func placedBody(
        _ fragment: HTMLFragment, format: DocumentFormat, lead: ReadingDepth?, forPaper: Bool = false
    ) -> String {
        guard legacyTOC == nil else { return fragment.body }
        var hidden: Set<ReaderContentsKind> = []
        if format == .latex {
            if !contents.showsContents { hidden.insert(.contents) }
            if !contents.showsFigures { hidden.insert(.figures) }
            if !contents.showsTables { hidden.insert(.tables) }
        } else {
            if contents.placement == .page || lead == nil { hidden.insert(.lead) }
            if contents.inText == .hidden { hidden.insert(.text) }
        }
        return fragment.filteringContents(hidden, forPaper: forPaper)
    }

    public func frontDepth(format: DocumentFormat, lead: ReadingDepth?) -> ReadingDepth? {
        if let legacyTOC { return legacyTOC.mode == .front ? legacyTOC.readingDepth : nil }
        return format != .latex && contents.placement == .page ? lead : nil
    }
}

extension OrgReadingDefaults.Depth {
    public init(_ depth: ReadingDepth?) {
        switch depth {
        case nil: self = .off
        case .all: self = .all
        case .levels(let n): self = .levels(n)
        }
    }

    public var readingDepth: ReadingDepth? {
        switch self {
        case .off: nil
        case .all: .all
        case .levels(let n): .levels(n)
        }
    }
}

extension DocumentSettings {
    public mutating func setLeadContents(
        _ value: OrgReadingDefaults.Depth, format: DocumentFormat, facts: DocumentFacts?,
        defaults: FormatReadingChoices, orgDefaults: OrgReadingDefaults
    ) {
        if format == .org {
            let reading = OrgReadingSettings(defaults: orgDefaults, document: orgReading ?? .init())
            let state = reading.resolve(.tableOfContents, file: facts?.orgInstructions ?? .init())
            guard !state.isLocked || value == state.value else { return }
        } else {
            let state = formatReading.resolve(
                .tableOfContents, for: format, file: facts?.contentsInstructions ?? .init(), defaults: defaults)
            guard state?.allowsOutline(present: value != .off, depth: value.readingDepth ?? .all) == true else {
                return
            }
        }
        // A refused edit must not migrate a legacy finish. An accepted edit uses the pre-edit reading values.
        printFinish?.adoptContents(editing: .lead, format: format)
        writeLeadContents(value, format: format, facts: facts, defaults: defaults, orgDefaults: orgDefaults)
    }

    private mutating func writeLeadContents(
        _ value: OrgReadingDefaults.Depth, format: DocumentFormat, facts: DocumentFacts?,
        defaults: FormatReadingChoices, orgDefaults: OrgReadingDefaults
    ) {
        if format == .org {
            var reading = OrgReadingSettings(defaults: orgDefaults, document: orgReading ?? .init())
            reading.set(value, for: .tableOfContents, file: facts?.orgInstructions ?? .init())
            orgReading = reading.document == .init() ? nil : reading.document
        } else {
            formatReading.set(
                .outline(present: value != .off, depth: value.readingDepth ?? .all),
                for: .tableOfContents, format: format, file: facts?.contentsInstructions ?? .init(), defaults: defaults)
        }
    }

    /// One transition for document restore, a global finish, a named preset and the first contents edit.
    @discardableResult
    public mutating func migrateContents(
        format: DocumentFormat, facts: DocumentFacts, defaults: FormatReadingChoices = .init(),
        orgDefaults: OrgReadingDefaults = .surimono, editing: ContentsFinish.Edit? = nil
    ) -> Bool {
        guard var finish = printFinish else { return false }
        guard let legacy = finish.legacyTOC else {
            if let editing {
                guard
                    finish.originalPresetContents != nil
                        || (format == .rst && editing == .lead && finish.keepsRSTLeadInText)
                else { return false }
                finish.adoptContents(editing: editing, format: format)
                printFinish = finish
                return true
            }
            // Older automatic migrations treated the native depth of three as a file lock.
            guard finish.originalPresetContents?.mode == .source, format == .markdown || format == .mediawiki,
                facts.contentsInstructions.present?.value == true, facts.contentsInstructions.depth == nil,
                formatReading.leadContents(for: format, file: facts.contentsInstructions, defaults: defaults)
                    != .levels(3)
            else { return false }
            writeLeadContents(.levels(3), format: format, facts: facts, defaults: defaults, orgDefaults: orgDefaults)
            return true
        }
        guard editing != nil || legacy.canMigrate(format: format, facts: facts) else { return false }
        if format != .latex {
            let value: OrgReadingDefaults.Depth?
            switch legacy.mode {
            case .front: value = .init(legacy.readingDepth)
            case .hidden: value = .off
            case .source:
                if format == .org {
                    value = nil
                } else if facts.contentsInstructions.present?.value == true,
                    case .outline(_, let depth) = FormatReadingChoices().resolve(
                        .tableOfContents, for: format, file: facts.contentsInstructions)
                {
                    value = .init(depth.value)
                } else {
                    value = .off
                }
            }
            if let value {
                writeLeadContents(value, format: format, facts: facts, defaults: defaults, orgDefaults: orgDefaults)
            }
        }
        finish.adoptContents(editing: editing, format: format)
        printFinish = finish
        return true
    }
}

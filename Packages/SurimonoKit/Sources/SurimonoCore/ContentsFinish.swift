import Foundation

public struct ContentsFinish: Codable, Hashable, Sendable {
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
        return !facts.hasSourceContents && facts.contentsInstructions.present == nil
            && facts.contentsInstructions.depth == nil
    }
}

extension PrintFinish {
    /// A legacy record runs the old CSS and page assembly until the document can adopt the new settings.
    public func contentsBody(
        _ fragment: HTMLFragment, facts: DocumentFacts, format: DocumentFormat, lead: ReadingDepth?,
        forPaper: Bool = false
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
        let body = fragment.filteringContents(hidden, forPaper: forPaper)
        guard let lead, contents.placement == .inline, format != .org, format != .latex,
            !facts.contentsKinds.contains(.lead),
            // An empty list from a reader can mean that the manuscript explicitly excluded all its headings.
            facts.contentsInstructions.present?.value != true
                || fragment.coalescesContentsInLegacy && format == .mediawiki
        else { return body }
        return DocumentOutline.addingLeadContents(to: body, headings: facts.headings, depth: lead)
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
        printFinish?.adoptContents(editing: true)
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
        orgDefaults: OrgReadingDefaults = .surimono, editing: Bool = false
    ) -> Bool {
        guard var finish = printFinish else { return false }
        guard let legacy = finish.legacyTOC else {
            guard editing, finish.forNewDocuments.legacyTOC != nil else { return false }
            finish.adoptContents(editing: true)
            printFinish = finish
            return true
        }
        guard editing || legacy.canMigrate(format: format, facts: facts) else { return false }
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
        finish.adoptContents(editing: editing)
        printFinish = finish
        return true
    }
}

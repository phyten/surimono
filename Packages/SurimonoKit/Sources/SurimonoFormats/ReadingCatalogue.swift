/// Shared row identity. The raw strings remain the legacy Org accessibility/search IDs.
/// The newer document map uses the format's key alongside the unqualified setting name.
public enum ReadingSettingID: String, CaseIterable, Sendable {
    case sectionNumbers = "org.num"
    case tableOfContents = "org.toc"
    case scripts = "org.scripts"
    case headlineLevels = "org.headlineLevels"
    case tags = "org.tags"
    case preserveBreaks = "org.preserveBreaks"
    case emphasis = "org.emphasis"
    case math = "org.math"
    case clocks = "org.clocks"
    case planning = "org.planning"
    case priority = "org.priority"
    case todo = "org.todo"
    case statistics = "org.statistics"
    case tasks = "org.tasks"
    case title = "org.title"
    case author = "org.author"
    case date = "org.date"
    case drawers = "org.drawers"
    case properties = "org.properties"
    case timestamps = "org.timestamps"
    case footnotes = "org.footnotes"
    case tables = "org.tables"
    case fixedWidth = "org.fixedWidth"
    case archived = "org.archived"
}

/// The order of groups and rows is also the order of the existing Org panel.
public enum OrgReadingGroup: CaseIterable, Sendable {
    case structure, information, text, tasks, details

    public var settings: [OrgSettingID] {
        switch self {
        case .structure: [.sectionNumbers, .tableOfContents, .headlineLevels, .tags]
        case .text: [.scripts, .preserveBreaks, .emphasis, .math]
        case .tasks: [.planning, .clocks, .priority, .todo, .statistics, .tasks]
        case .information: [.title, .author, .date]
        case .details: [.drawers, .properties, .timestamps, .footnotes, .tables, .fixedWidth, .archived]
        }
    }
}

/// The case identifies the control's value type. An outline retains its format's depth even when switched off.
public enum ReadingSettingValue: Equatable, Sendable {
    case outline(present: Bool, depth: ReadingDepth)
    case toggle(Bool)
    case integer(Int)
    case scripts(OrgReadingDefaults.Scripts)
    case tags(OrgReadingDefaults.Tags)
    case math(OrgReadingDefaults.Math)
    case tasks(OrgReadingDefaults.Tasks)
    case names(OrgReadingDefaults.Names)
    case timestamps(OrgReadingDefaults.Timestamps)
    case archived(OrgReadingDefaults.Archived)
}

public struct ReadingSyntax: Equatable, Sendable {
    public enum Effect: Sendable { case presence, depth, whole, note }
    public let syntax: String
    public let effect: Effect
    public let readToday: Bool

    init(_ syntax: String, _ effect: Effect, readToday: Bool = true) {
        self.readToday = readToday
        self.syntax = syntax
        self.effect = effect
    }
}

/// Syntax describes the setting contract. Readers supply the instructions they actually recognized.
/// Copy templates are format syntax (YAML fragments belong in the header), never localized UI text.
public struct ReadingCatalogueRow: Equatable, Sendable {
    public let id: ReadingSettingID
    public let shipped: ReadingSettingValue
    public let instructions: [ReadingSyntax]
    public let copySyntax: [String]

    fileprivate init(
        _ id: ReadingSettingID, _ shipped: ReadingSettingValue, _ instructions: [ReadingSyntax],
        copy: [String]
    ) {
        self.id = id
        self.shipped = shipped
        self.instructions = instructions
        self.copySyntax = copy
    }
}

public enum ReadingCatalogue {
    public static func rows(for format: DocumentFormat) -> [ReadingCatalogueRow] {
        switch format {
        case .org: org
        case .markdown: markdown
        case .quarto: quarto
        case .rMarkdown: rMarkdown
        case .rst: rst
        case .asciidoc: asciidoc
        case .mediawiki: mediawiki
        default:
            format.usesPrintTheme && format != .latex
                ? [.init(.tableOfContents, .outline(present: false, depth: .all), [], copy: [])] : []
        }
    }

    private static let bodyMarkers: [ReadingSyntax] = ["[TOC]", "[[toc]]", "[[_TOC_]]"].map { .init($0, .note) }
    private static let yamlNumbers = ReadingSyntax("number-sections", .presence)
    private static let yamlContents: [ReadingSyntax] = [
        .init("toc", .presence), .init("toc-depth", .depth), .init("toc-title", .note),
    ]
    private static let yamlTOCCopy = ["toc: {true|false}", "toc-depth: {n}"]

    // MarkdownMetadata currently reads only toc; the native list defaults to three levels from the chapter.
    private static let markdown: [ReadingCatalogueRow] = [
        .init(
            .sectionNumbers, .outline(present: false, depth: .all),
            [.init("number-sections", .presence, readToday: false)], copy: ["number-sections: {true|false}"]),
        .init(
            .tableOfContents, .outline(present: false, depth: .levels(3)),
            [
                .init("toc", .presence), .init("toc-depth", .depth, readToday: false),
                .init("toc-title", .note, readToday: false),
            ]
                + bodyMarkers, copy: yamlTOCCopy),
        .init(.preserveBreaks, .toggle(false), [], copy: []),
    ]

    // https://quarto.org/docs/output-formats/html-basics.html documents number-depth.
    // ComputationalDivisions ignores it, numbers every eligible heading and uses absolute levels for toc-depth.
    private static let quarto: [ReadingCatalogueRow] = [
        .init(
            .sectionNumbers, .outline(present: false, depth: .all),
            [yamlNumbers, .init("number-depth", .depth, readToday: false), .init(".unnumbered", .note)],
            copy: ["number-sections: {true|false}", "number-depth: {n}"]),
        .init(
            .tableOfContents, .outline(present: false, depth: .levels(3)),
            yamlContents + bodyMarkers + [.init(".unlisted", .note)], copy: yamlTOCCopy),
    ]

    // https://rmarkdown.rstudio.com/docs/reference/render.html selects the first output unless explicitly told otherwise.
    // https://rmarkdown.rstudio.com/docs/reference/html_document.html defines the underscore keys.
    // ComputationalMetadata skips the entire output/format mapping, including every output in a multi-format file.
    // The shared reader currently honors the Quarto top-level keys and body markers instead.
    private static let rMarkdown: [ReadingCatalogueRow] = [
        .init(
            .sectionNumbers, .toggle(false),
            [
                .init("output.<first>.number_sections", .presence, readToday: false), yamlNumbers,
                .init(".unnumbered", .note),
            ],
            copy: ["output:\n  {format}:\n    number_sections: {true|false}"]),
        .init(
            .tableOfContents, .outline(present: false, depth: .levels(3)),
            [
                .init("output.<first>.toc", .presence, readToday: false),
                .init("output.<first>.toc_depth", .depth, readToday: false),
            ]
                + yamlContents + bodyMarkers + [.init(".unlisted", .note)],
            copy: ["output:\n  {format}:\n    toc: {true|false}", "    toc_depth: {n}"]),
    ]

    // https://docutils.sourceforge.io/docs/ref/rst/directives.html#automatic-section-numbering
    // RSTDirectiveContents applies :depth: relative to the shallowest non-promoted section.
    // :local: scopes a contents directive to its section; it does not fix the document setting.
    private static let rst: [ReadingCatalogueRow] = [
        .init(
            .sectionNumbers, .outline(present: false, depth: .all),
            [
                .init(".. sectnum::", .presence), .init(".. section-numbering::", .presence),
                .init("sectnum :depth:", .depth),
            ],
            copy: [".. sectnum::", "   :depth: {n}"]),
        .init(
            .tableOfContents, .outline(present: false, depth: .levels(6)),
            [.init(".. contents::", .note), .init("contents :depth:", .note), .init("contents :local:", .note)],
            copy: [".. contents::", "   :depth: {n}"]),
    ]

    // https://docs.asciidoctor.org/asciidoc/latest/attributes/assignment-precedence/
    // Hard API attributes precede header entries; an @ suffix makes an API default overridable.
    // https://docs.asciidoctor.org/asciidoc/latest/sections/numbers/ documents the regional sectnums exception.
    // The bridge reads header attributes after Asciidoctor resolves them. Macro placement belongs to the body.
    private static let asciidoc: [ReadingCatalogueRow] = [
        .init(
            .sectionNumbers, .outline(present: false, depth: .levels(3)),
            [
                .init(":sectnums:", .presence), .init(":sectnums!:", .presence), .init(":sectnumlevels:", .depth),
                .init("sectnums in the body", .note),
            ],
            copy: [":sectnums:", ":sectnums!:", ":sectnumlevels: {n}"]),
        .init(
            .tableOfContents, .outline(present: false, depth: .levels(2)),
            [
                .init(":toc:", .presence), .init(":toc!:", .presence), .init(":toclevels:", .depth),
                .init(":toc: macro", .note), .init("toc::[]", .note),
            ],
            copy: [":toc:", ":toc!:", ":toclevels: {n}"]),
    ]

    private static let mediawiki: [ReadingCatalogueRow] = [
        .init(
            .tableOfContents, .outline(present: false, depth: .levels(3)),
            [.init("__FORCETOC__", .presence), .init("__NOTOC__", .presence), .init("__TOC__", .note)],
            copy: ["__FORCETOC__", "__NOTOC__"])
    ]

    private static let org = OrgReadingGroup.allCases.flatMap(\.settings).map { id in
        let syntax = "#+OPTIONS: " + id.token + ":{value}"
        var instructions = [ReadingSyntax(syntax, .whole)]
        switch id {
        case .sectionNumbers: instructions.append(.init(":UNNUMBERED:", .note))
        case .tableOfContents: instructions += [.init("#+TOC:", .note), .init(":UNNUMBERED: notoc", .note)]
        default: break
        }
        return ReadingCatalogueRow(id, orgDefault(id), instructions, copy: [syntax])
    }

    private static func orgDefault(_ id: ReadingSettingID) -> ReadingSettingValue {
        let defaults = OrgReadingDefaults.surimono
        switch id {
        case .sectionNumbers: return outline(defaults.sectionNumbers)
        case .tableOfContents: return outline(defaults.tableOfContents)
        case .title: return .toggle(defaults.title)
        case .author: return .toggle(defaults.author)
        case .date: return .toggle(defaults.date)
        case .preserveBreaks: return .toggle(defaults.preserveBreaks)
        case .emphasis: return .toggle(defaults.emphasis)
        case .clocks: return .toggle(defaults.clocks)
        case .planning: return .toggle(defaults.planning)
        case .priority: return .toggle(defaults.priority)
        case .todo: return .toggle(defaults.todo)
        case .statistics: return .toggle(defaults.statistics)
        case .footnotes: return .toggle(defaults.footnotes)
        case .tables: return .toggle(defaults.tables)
        case .fixedWidth: return .toggle(defaults.fixedWidth)
        case .headlineLevels: return .integer(defaults.headlineLevels)
        case .tags: return .tags(defaults.tags)
        case .math: return .math(defaults.math)
        case .scripts: return .scripts(defaults.scripts)
        case .tasks: return .tasks(defaults.tasks)
        case .drawers: return .names(defaults.drawers)
        case .properties: return .names(defaults.properties)
        case .timestamps: return .timestamps(defaults.timestamps)
        case .archived: return .archived(defaults.archived)
        }
    }

    private static func outline(_ depth: OrgReadingDefaults.Depth) -> ReadingSettingValue {
        switch depth {
        case .off: .outline(present: false, depth: .all)
        case .all: .outline(present: true, depth: .all)
        case .levels(let n): .outline(present: true, depth: .levels(n))
        }
    }
}

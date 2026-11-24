import Foundation
import SurimonoCore

enum OrgReadingGroup: CaseIterable {
    case structure, text, tasks, information, details

    var title: LocalizedStringResource {
        switch self {
        case .structure: "Structure"
        case .text: "Text Formatting"
        case .tasks: "Tasks"
        case .information: "Document Information"
        case .details: "Details"
        }
    }

    var settings: [OrgSettingID] {
        switch self {
        case .structure: [.sectionNumbers, .tableOfContents, .headlineLevels, .tags]
        case .text: [.scripts, .preserveBreaks, .emphasis, .math]
        case .tasks: [.planning, .clocks, .priority, .todo, .statistics, .tasks]
        case .information: [.title, .author, .date]
        case .details: [.drawers, .properties, .timestamps, .footnotes, .tables, .fixedWidth, .archived]
        }
    }
}

extension OrgSettingID {
    var label: LocalizedStringResource {
        switch self {
        case .sectionNumbers: "Heading Numbers"
        case .tableOfContents: "Table of Contents at the Top"
        case .headlineLevels: "Heading Depth"
        case .tags: "Heading Tags"
        case .scripts: "Subscripts and Superscripts"
        case .preserveBreaks: "Preserve Line Breaks"
        case .emphasis: "Text Emphasis"
        case .math: "LaTeX Formulas"
        case .planning: "Planning Lines"
        case .clocks: "Clock Lines"
        case .priority: "Priorities"
        case .todo: "TODO Keywords"
        case .statistics: "Statistics Cookies"
        case .tasks: "Include Tasks"
        case .title: "Document Title"
        case .author: "Author"
        case .date: "Document Date"
        case .drawers: "Drawers"
        case .properties: "Property Drawers"
        case .timestamps: "Standalone Timestamps"
        case .footnotes: "Footnotes"
        case .tables: "Tables"
        case .fixedWidth: "Fixed-width Sections"
        case .archived: "Archived Trees"
        }
    }
}

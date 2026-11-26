import SurimonoCore
import SwiftUI

enum ContentsFinishRow: Hashable {
    case lead, layout, look, inText, contents, figures, tables

    static func visible(
        format: DocumentFormat, hasLead: Bool, finish: PrintFinish, facts: DocumentFacts?
    ) -> Set<Self> {
        let kinds = facts?.contentsKinds ?? []
        var rows: Set<Self> = []
        if format == .latex {
            if kinds.contains(.contents) { rows.insert(.contents) }
            if kinds.contains(.figures) { rows.insert(.figures) }
            if kinds.contains(.tables) { rows.insert(.tables) }
            // This front page can exist even when the manuscript has no table of contents. Allow the reader to turn it off.
            if !kinds.contains(.contents), finish.legacyTOC?.mode == .front, facts?.headings.isEmpty == false {
                rows.insert(.contents)
            }
        } else if format.usesPrintTheme {
            if format != .org && !format.usesFormatReadingSettings { rows.insert(.lead) }
            if hasLead || finish.legacyTOC?.mode == .front {
                rows.insert(.layout)
                if finish.contents.placement == .page { rows.insert(.look) }
            }
            if kinds.contains(.text) { rows.insert(.inText) }
        }
        return rows
    }
}

extension DocumentViewModel {
    var contentsFinishRows: Set<ContentsFinishRow> {
        guard finishAppliesToText else { return [] }
        return ContentsFinishRow.visible(
            format: format, hasLead: leadContents != .off, finish: printFinish, facts: contentsFacts)
    }

    var offersContentsFinish: Bool { !contentsFinishRows.isEmpty }

    var latexContentsBinding: Binding<Bool> {
        // When only the legacy front page is present, switching it off adopts the manuscript's lists.
        controlBinding(
            get: {
                $0.printFinish.legacyTOC?.mode == .front && $0.contentsFacts?.contentsKinds.contains(.contents) == false
                    || $0.printFinish.contents.showsContents
            }, set: { $0.editContents(\.showsContents, $1) })
    }

    var leadContentsResolution: ReadingRowResolution? {
        formatReading.resolve(
            .tableOfContents, for: format, file: contentsFacts?.contentsInstructions ?? .init(),
            defaults: preferences.formatReadingDefaults)
    }

    var leadContents: OrgReadingDefaults.Depth {
        if format == .org { return orgReading.resolve(.tableOfContents, file: orgFileInstructions ?? .init()).value }
        guard case .outline(let present, let depth) = leadContentsResolution else { return .off }
        return present.value ? .init(depth.value) : .off
    }

    func matchesLeadContents(_ value: OrgReadingDefaults.Depth) -> Bool {
        // Compare with the value that applying the set in this manuscript can actually write.
        var document = rememberedSettings
        writeLead(value, to: &document)
        return document.formatReading == formatReading && document.orgReading == rememberedSettings.orgReading
    }

    private func writeLead(_ value: OrgReadingDefaults.Depth, to document: inout DocumentSettings) {
        document.setLeadContents(
            value, format: format, facts: contentsFacts, defaults: preferences.formatReadingDefaults,
            orgDefaults: preferences.orgReadingDefaults ?? .surimono)
    }

    func setLeadContents(_ value: OrgReadingDefaults.Depth) {
        var document = rememberedSettings
        writeLead(value, to: &document)
        if let finish = document.printFinish { printFinish = finish }
        orgDocumentReading = document.orgReading ?? .init()
        formatReading = document.formatReading
    }

    func migrateContents(editing: Bool = false) {
        guard editing || printFinish.originalPresetContents != nil, let contentsFacts else { return }
        var document = rememberedSettings
        guard
            document.migrateContents(
                format: format, facts: contentsFacts, defaults: preferences.formatReadingDefaults,
                orgDefaults: preferences.orgReadingDefaults ?? .surimono, editing: editing),
            let finish = document.printFinish
        else { return }
        orgDocumentReading = document.orgReading ?? .init()
        formatReading = document.formatReading
        printFinish = finish
    }

    func contentsBinding(_ key: WritableKeyPath<ContentsFinish, Bool>) -> Binding<Bool> {
        controlBinding(get: { $0.printFinish.contents[keyPath: key] }, set: { $0.editContents(key, $1) })
    }

    func editContents<Value>(_ key: WritableKeyPath<ContentsFinish, Value>, _ value: Value) {
        if printFinish.legacyTOC != nil { migrateContents(editing: true) }
        printFinish.contents[keyPath: key] = value
    }
}

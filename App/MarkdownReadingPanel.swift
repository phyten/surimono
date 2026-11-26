import SurimonoCore
import SwiftUI

extension DocumentViewModel {
    func markdownFile(_ id: ReadingSettingID) -> ReadingFileInstructions {
        switch id {
        case .tableOfContents: contentsFacts?.contentsInstructions ?? .init()
        case .sectionNumbers: contentsFacts?.numberInstructions ?? .init()
        default: .init()
        }
    }

    func markdownResolution(_ id: ReadingSettingID) -> ReadingRowResolution? {
        formatReading.resolve(id, for: .markdown, file: markdownFile(id), defaults: preferences.formatReadingDefaults)
    }

    func setMarkdownValue(_ value: ReadingSettingValue, for id: ReadingSettingID) {
        guard offersReadingPanel, format == .markdown, contentsFacts != nil else { return }
        if id == .tableOfContents, case .outline(let present, let depth) = value {
            setLeadContents(present ? .init(depth) : .off)
            return
        }
        formatReading.set(
            value, for: id, format: .markdown, file: markdownFile(id), defaults: preferences.formatReadingDefaults)
    }
}

struct MarkdownReadingPanel: View {
    let model: DocumentViewModel
    @State private var confirmation: Discard?
    private struct Discard: Identifiable {
        let id = UUID()
        let generation: Int
        let before: FormatReadingChoices
        let after: FormatReadingChoices
        let count: Int
    }

    private var ids: [ReadingSettingID] { DocumentsChapter.rows(for: .markdown).map(\.id) }
    private var unlocked: Bool { model.formatReading.allowsFileChanges(for: .markdown) }

    private func revert(_ id: ReadingSettingID) {
        if id == .tableOfContents, model.markdownResolution(id)?.isChanged == true {
            model.migrateContents(editing: true)
        }
        model.formatReading.revert(id, for: .markdown)
    }

    private func lock(confirming approval: Discard? = nil) {
        guard model.contentsFacts != nil else { return }
        var changes = model.formatReading
        var count = 0
        for id in ids {
            let before = changes
            changes.revert(id, for: .markdown, fileOnly: model.markdownFile(id))
            if changes != before { count += 1 }
        }
        changes.setAllowsFileChanges(false, for: .markdown)
        if count == 0
            || (approval?.generation == model.dataGeneration && approval?.before == model.formatReading
                && approval?.after == changes)
        {
            model.formatReading = changes
        } else {
            confirmation = Discard(
                generation: model.dataGeneration, before: model.formatReading, after: changes, count: count)
        }
    }

    private var permission: Binding<Bool>? {
        guard unlocked || ids.contains(where: { model.markdownFile($0) != .init() }) else { return nil }
        return Binding(
            get: { unlocked },
            set: { allow in
                if allow { model.formatReading.setAllowsFileChanges(true, for: .markdown) } else { lock() }
            })
    }

    var body: some View {
        ReadingPanel(
            title: "Markdown", ready: model.contentsFacts != nil, changed: model.readingChangedCount,
            countInFooter: true, allowsFileChanges: permission, close: { model.isReadingPanelOpen = false },
            revert: { for id in ids { revert(id) } }
        ) {
            EmptyView()
        } rows: {
            ReadingPanelSection(ids: ids) { id in
                if let row = model.markdownResolution(id) {
                    VStack(alignment: .leading, spacing: 4) {
                        FormatReadingControl(
                            id: id, row: row, resetHelp: row.resetHelp(format: "Markdown"),
                            documentName: model.displayName,
                            fileURL: model.fileURL, allowsFileChanges: unlocked,
                            set: { model.setMarkdownValue($0, for: id) }, revert: { revert(id) })
                        if id == .tableOfContents, let marker = model.contentsFacts?.markdownContentsMarker {
                            (Text("Contents in Text") + Text(verbatim: " · " + marker)).font(.caption).foregroundStyle(
                                .secondary)
                        }
                    }
                }
            }
        }
        .alert(item: $confirmation) { pending in
            Alert(
                title: Text("Discard changes to \(pending.count) file-specified settings? Other changes will be kept."),
                primaryButton: .destructive(Text("Discard")) { lock(confirming: pending) }, secondaryButton: .cancel())
        }
    }
}

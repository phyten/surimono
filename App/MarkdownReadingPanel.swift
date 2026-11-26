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

    var markdownNumbersInheritStyle: Bool {
        FormatReadingChoices().usesStyleForMarkdownNumbers(
            file: markdownFile(.sectionNumbers), defaults: preferences.formatReadingDefaults)
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

    func revertMarkdownValue(_ id: ReadingSettingID) {
        if id == .tableOfContents, markdownResolution(id)?.isChanged == true {
            migrateContents(editing: true)
        }
        formatReading.revert(id, for: .markdown)
    }

    func lockMarkdownFileInstructions(confirming approval: MarkdownDiscardConfirmation? = nil) -> MarkdownFileLockResult
    {
        guard offersReadingPanel, format == .markdown else { return .finished }
        var document = DocumentSettings(printFinish: printFinish, formatReading: formatReading)
        let result = document.lockMarkdownFileInstructions(
            facts: contentsFacts, generation: dataGeneration, defaults: preferences.formatReadingDefaults,
            confirming: approval)
        if result == .finished {
            if let finish = document.printFinish, finish != printFinish { printFinish = finish }
            if formatReading != document.formatReading { formatReading = document.formatReading }
        }
        return result
    }
}

struct MarkdownReadingPanel: View {
    let model: DocumentViewModel
    @State private var confirmation: MarkdownDiscardConfirmation?
    @State private var retryLock = false

    private var ids: [ReadingSettingID] { DocumentsChapter.rows(for: .markdown).map(\.id) }
    private var unlocked: Bool { model.formatReading.allowsFileChanges(for: .markdown) }

    private func lock(confirming approval: MarkdownDiscardConfirmation? = nil) {
        switch model.lockMarkdownFileInstructions(confirming: approval) {
        case .finished: retryLock = false
        case .awaitingInstructions: retryLock = true
        case .needsConfirmation(let current):
            if approval == nil { confirmation = current } else { retryLock = true }
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
            revert: { for id in ids { model.revertMarkdownValue(id) } }
        ) {
            EmptyView()
        } rows: {
            ReadingPanelSection(ids: ids) { id in
                if let row = model.markdownResolution(id) {
                    let inheritsStyle = id == .sectionNumbers && model.markdownNumbersInheritStyle
                    VStack(alignment: .leading, spacing: 4) {
                        FormatReadingControl(
                            id: id, row: row,
                            resetHelp: row.resetHelp(format: "Markdown", inheritsStyle: inheritsStyle),
                            documentName: model.displayName,
                            fileURL: model.fileURL, allowsFileChanges: unlocked, inheritsStyle: inheritsStyle,
                            set: { model.setMarkdownValue($0, for: id) }, revert: { model.revertMarkdownValue(id) })
                        if id == .tableOfContents, let marker = model.contentsFacts?.markdownContentsMarker {
                            (Text("Contents in Text") + Text(verbatim: " · " + marker)).font(.caption).foregroundStyle(
                                .secondary)
                        }
                    }
                }
            }
        }
        .task(id: retryLock && confirmation == nil && model.contentsFacts != nil) {
            guard retryLock, confirmation == nil, model.contentsFacts != nil else { return }
            retryLock = false
            lock()
        }
        .alert(item: $confirmation) { pending in
            Alert(
                title: Text("Discard changes to \(pending.count) file-specified settings? Other changes will be kept."),
                primaryButton: .destructive(Text("Discard")) { lock(confirming: pending) }, secondaryButton: .cancel())
        }
    }
}

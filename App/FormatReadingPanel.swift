import SurimonoCore
import SwiftUI

extension DocumentViewModel {
    func readingFile(_ id: ReadingSettingID) -> ReadingFileInstructions {
        switch id {
        case .tableOfContents: contentsFacts?.contentsInstructions ?? .init()
        case .sectionNumbers: contentsFacts?.numberInstructions ?? .init()
        default: .init()
        }
    }

    func readingResolution(_ id: ReadingSettingID) -> ReadingRowResolution? {
        formatReading.resolve(id, for: format, file: readingFile(id), defaults: preferences.formatReadingDefaults)
    }

    var numbersInheritStyle: Bool {
        FormatReadingChoices().usesStyleForSectionNumbers(
            for: format, file: readingFile(.sectionNumbers), defaults: preferences.formatReadingDefaults)
    }

    func setReadingValue(_ value: ReadingSettingValue, for id: ReadingSettingID) {
        guard offersReadingPanel, format.usesFormatReadingSettings, contentsFacts != nil else { return }
        if id == .tableOfContents, case .outline(let present, let depth) = value {
            setLeadContents(present ? .init(depth) : .off)
            return
        }
        formatReading.set(
            value, for: id, format: format, file: readingFile(id), defaults: preferences.formatReadingDefaults)
    }

    func revertReadingValue(_ id: ReadingSettingID) {
        if id == .tableOfContents, readingResolution(id)?.isChanged == true {
            migrateContents(editing: true)
        }
        formatReading.revert(id, for: format)
    }

    func lockReadingFileInstructions(confirming approval: ReadingDiscardConfirmation? = nil) -> ReadingFileLockResult {
        guard offersReadingPanel, format.usesFormatReadingSettings else { return .finished }
        var document = DocumentSettings(printFinish: printFinish, formatReading: formatReading)
        let result = document.lockReadingFileInstructions(
            for: format, facts: contentsFacts, generation: dataGeneration, defaults: preferences.formatReadingDefaults,
            confirming: approval)
        if result == .finished {
            if let finish = document.printFinish, finish != printFinish { printFinish = finish }
            if formatReading != document.formatReading { formatReading = document.formatReading }
        }
        return result
    }
}

struct FormatReadingPanel: View {
    let model: DocumentViewModel
    @State private var confirmation: ReadingDiscardConfirmation?
    @State private var retryLock = false

    private var ids: [ReadingSettingID] { DocumentsChapter.rows(for: model.format).map(\.id) }
    private var unlocked: Bool { model.formatReading.allowsFileChanges(for: model.format) }

    private func lock(confirming approval: ReadingDiscardConfirmation? = nil) {
        switch model.lockReadingFileInstructions(confirming: approval) {
        case .finished: retryLock = false
        case .awaitingInstructions: retryLock = true
        case .needsConfirmation(let current):
            if approval == nil { confirmation = current } else { retryLock = true }
        }
    }

    private var permission: Binding<Bool>? {
        guard unlocked || ids.contains(where: { model.readingFile($0) != .init() }) else { return nil }
        return Binding(
            get: { unlocked },
            set: { allow in
                if allow { model.formatReading.setAllowsFileChanges(true, for: model.format) } else { lock() }
            })
    }

    var body: some View {
        ReadingPanel(
            title: LocalizedStringKey(model.format.displayName), ready: model.contentsFacts != nil,
            changed: model.readingChangedCount,
            countInFooter: true, allowsFileChanges: permission, close: { model.isReadingPanelOpen = false },
            revert: { for id in ids { model.revertReadingValue(id) } }
        ) {
            EmptyView()
        } rows: {
            ReadingPanelSection(ids: ids) { id in
                if let row = model.readingResolution(id) {
                    let inheritsStyle = id == .sectionNumbers && model.numbersInheritStyle
                    VStack(alignment: .leading, spacing: 4) {
                        FormatReadingControl(
                            id: id, row: row,
                            resetHelp: row.resetHelp(
                                format: model.format.displayName, id: id, inheritsStyle: inheritsStyle),
                            documentName: model.displayName,
                            fileURL: model.fileURL, allowsFileChanges: unlocked, inheritsStyle: inheritsStyle,
                            set: { model.setReadingValue($0, for: id) }, revert: { model.revertReadingValue(id) })
                        if id == .tableOfContents, let marker = model.contentsFacts?.inTextContentsMarker {
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

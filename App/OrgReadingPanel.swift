import AppKit
import SurimonoCore
import SwiftUI

struct OrgDiscardConfirmation: Equatable {
    let generation: Int
    let overrides: OrgDocumentReadingSettings
}

enum OrgFileLockResult: Equatable {
    case finished
    case awaitingInstructions
    case needsConfirmation(OrgDiscardConfirmation)
}

extension DocumentViewModel {
    func setOrgValue<Value>(_ value: Value, for key: OrgSetting<Value>) {
        guard offersOrgReading, let orgFileInstructions else { return }
        if key.id == .tableOfContents { migrateContents(editing: .lead) }
        var settings = orgReading
        settings.set(value, for: key, file: orgFileInstructions)
        orgDocumentReading = settings.document
    }

    func enableOrgFileChanges() {
        guard offersOrgReading, let file = orgFileInstructions else { return }
        var settings = orgReading
        settings.setAllowsFileChanges(true, file: file)
        orgDocumentReading = settings.document
    }

    /// Recheck and apply together on the main actor. A reload invalidates approval even if its count is unchanged.
    func lockOrgFileInstructions(confirming approval: OrgDiscardConfirmation? = nil) -> OrgFileLockResult {
        guard offersOrgReading, orgDocumentReading.allowsFileChanges else { return .finished }
        guard let file = orgFileInstructions else { return .awaitingInstructions }
        var settings = orgReading
        let current = OrgDiscardConfirmation(generation: dataGeneration, overrides: settings.fileOverrides(file: file))
        if current.overrides.changedCount > 0 && current != approval { return .needsConfirmation(current) }
        settings.setAllowsFileChanges(false, file: file)
        orgDocumentReading = settings.document
        return .finished
    }

    func resetOrgValues() {
        guard offersOrgReading else { return }
        if orgReading.resolve(.tableOfContents, file: orgFileInstructions ?? .init()).layer == .document {
            migrateContents(editing: .lead)
        }
        orgDocumentReading.resetValues()
    }

    /// A document can promote only its own edits. A file instruction belongs to its author.
    func makeOrgDefaults() {
        guard offersOrgReading, let file = orgFileInstructions else { return }
        preferences.setOrgDefaults(orgReading.effectiveDefaults(file: file, documentOnly: true))
    }
}

struct OrgReadingPanel: View {
    let model: DocumentViewModel
    @State private var confirmation: Confirmation?
    @State private var retryLock = false
    private enum Confirmation: Identifiable {
        case discard(OrgDiscardConfirmation)
        case promote

        enum ID: Hashable {
            case discard(generation: Int, choices: String?)
            case promote
        }
        var id: ID {
            switch self {
            case .discard(let approval):
                .discard(generation: approval.generation, choices: approval.overrides.optionsLine)
            case .promote: .promote
            }
        }
    }

    private var readyToRetryLock: Bool {
        retryLock && confirmation == nil && model.orgFileInstructions != nil
    }

    var body: some View {
        ReadingPanel(
            title: "Org", ready: model.orgFileInstructions != nil, changed: model.orgDocumentReading.changedCount,
            countInFooter: true,
            allowsFileChanges: fileChangesBinding, close: { model.isReadingPanelOpen = false },
            revert: model.resetOrgValues
        ) {
            actionsMenu
        } rows: {
            OrgReadingRows(model: model, preferences: model.preferences)
        }
        .alert(item: $confirmation) { pending in
            switch pending {
            case .discard(let approval):
                let count = approval.overrides.changedCount
                return Alert(
                    title: Text("Discard changes to \(count) file-specified settings? Other changes will be kept."),
                    message: approval.overrides.optionsLine.map { Text(verbatim: $0) },
                    primaryButton: .destructive(Text("Discard")) { requestLock(confirming: approval) },
                    secondaryButton: .cancel())
            case .promote:
                return Alert(
                    title: Text("Use this document’s changes as the Org defaults?"),
                    primaryButton: .default(Text("Apply")) { model.makeOrgDefaults() }, secondaryButton: .cancel())
            }
        }
        // Wait for both SwiftUI to dismiss the previous alert and the parser to publish the current instructions.
        .task(id: readyToRetryLock) {
            guard readyToRetryLock else { return }
            retryLock = false
            requestLock()
        }
    }

    private func requestLock(confirming approval: OrgDiscardConfirmation? = nil) {
        Self.apply(
            model.lockOrgFileInstructions(confirming: approval), confirming: approval, retry: $retryLock,
            alert: $confirmation)
    }

    private static func apply(
        _ result: OrgFileLockResult, confirming approval: OrgDiscardConfirmation? = nil,
        retry: Binding<Bool>, alert: Binding<Confirmation?>
    ) {
        switch result {
        case .finished: retry.wrappedValue = false
        case .awaitingInstructions: retry.wrappedValue = true
        case .needsConfirmation(let current):
            if approval == nil {
                alert.wrappedValue = .discard(current)
            } else {
                retry.wrappedValue = true
            }
        }
    }

    private var fileChangesBinding: Binding<Bool>? {
        guard
            model.orgFileInstructions?.hasWholeDocumentInstructions == true
                || model.orgDocumentReading.allowsFileChanges
        else { return nil }
        return model.controlBinding(
            get: { $0.orgDocumentReading.allowsFileChanges },
            set: { [retry = $retryLock, alert = $confirmation] model, allow in
                if allow {
                    model.enableOrgFileChanges()
                } else {
                    Self.apply(model.lockOrgFileInstructions(), retry: retry, alert: alert)
                }
            })
    }

    private var actionsMenu: some View {
        Menu {
            Button("Make Org Defaults…") { confirmation = .promote }.disabled(
                model.orgDocumentReading.changedCount == 0 || model.orgFileInstructions == nil)
            Button("Copy as an #+OPTIONS Line") {
                if let line = model.orgDocumentReading.optionsLine { copyReadingLine(line) }
            }.disabled(model.orgDocumentReading.optionsLine == nil)
            Button("Open Org Settings…") {
                BandArrangementEditorSession.showSection(.org, preferences: model.preferences)
                AppKitShell.current?.showSettings(nil)
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PrintPalette.ink).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(PrintPalette.ink).fixedSize()
        .accessibilityLabel("More").help("More")
    }

}

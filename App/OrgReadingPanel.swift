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
        if key.id == .tableOfContents { migrateContents(editing: true) }
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
            migrateContents(editing: true)
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
    // Includes both side insets. Longer rows place their control below the label.
    static let width: CGFloat = 286
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
        SidePanel("Org", width: Self.width) {
            actionsMenu
            PanelIconButton("xmark", label: "Close") { model.isReadingPanelOpen = false }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OrgReadingRows(model: model, preferences: model.preferences)
                    fileOverride
                }
                .disabled(model.orgFileInstructions == nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            OrgReadingFooter(count: model.orgDocumentReading.changedCount, revert: model.resetOrgValues)
        }
        .overlay(alignment: .leading) { Rectangle().fill(PrintPalette.line).frame(width: 1) }
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

    @ViewBuilder private var fileOverride: some View {
        if model.orgFileInstructions?.hasWholeDocumentInstructions == true || model.orgDocumentReading.allowsFileChanges
        {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    "Allow Changes to File Instructions",
                    isOn: model.controlBinding(
                        get: { $0.orgDocumentReading.allowsFileChanges },
                        set: { [retry = $retryLock, alert = $confirmation] model, allow in
                            if allow {
                                model.enableOrgFileChanges()
                            } else {
                                Self.apply(model.lockOrgFileInstructions(), retry: retry, alert: alert)
                            }
                        })
                ).toggleStyle(.checkbox).controlSize(.small).fixedSize(horizontal: false, vertical: true)
                if model.orgDocumentReading.allowsFileChanges {
                    Text("Only changed settings take precedence. The original file is never modified.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button("Make Org Defaults…") { confirmation = .promote }.disabled(
                model.orgDocumentReading.changedCount == 0 || model.orgFileInstructions == nil)
            Button("Copy as an #+OPTIONS Line") {
                if let line = model.orgDocumentReading.optionsLine { Self.copy(line) }
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

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct OrgReadingFooter: View {
    let count: Int
    let revert: () -> Void

    var body: some View {
        if count > 0 {
            VStack(spacing: 8) {
                Divider()
                HStack(spacing: 8) {
                    Text("Changed in This Document: \(count)")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Revert All", action: revert).fixedSize()
                }
            }
            .controlSize(.small)
        }
    }
}

struct OrgFileReason: View {
    let model: DocumentViewModel
    let source: OrgInstructionSource
    let changed: Bool
    @State private var showsSource = false

    private var reason: String {
        if changed { return String(localized: "Changed (file: \(source.rawText))") }
        if model.orgDocumentReading.allowsFileChanges {
            return String(localized: "Keeping file instruction: \(source.rawText)")
        }
        return String(localized: "Specified in file: \(source.rawText)")
    }

    var body: some View {
        Button {
            showsSource.toggle()
        } label: {
            Text(verbatim: reason).underline()
        }
        .buttonStyle(.link).font(.caption)
        .popover(isPresented: $showsSource) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verbatim: source.fileName ?? model.displayName)
                    Text("Line \(source.lineNumber)").foregroundStyle(.secondary)
                }
                if let excerpt = source.excerpt {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 3) {
                            if let previous = excerpt.previous {
                                sourceLine(source.lineNumber - 1, Text(verbatim: previous))
                            }
                            sourceLine(source.lineNumber, highlighted(excerpt))
                            if let next = excerpt.next { sourceLine(source.lineNumber + 1, Text(verbatim: next)) }
                        }
                    }
                    HStack {
                        Spacer()
                        if let url = model.fileURL, url.isFileURL {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        Button("Copy Line") { OrgReadingPanel.copy(excerpt.line) }
                    }
                }
            }
            .padding(12).frame(width: 360).controlSize(.small)
        }
    }

    private func sourceLine(_ number: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: String(number)).foregroundStyle(.secondary)
            text
        }.font(.system(.caption, design: .monospaced))
    }

    private func highlighted(_ excerpt: OrgInstructionSource.Excerpt) -> Text {
        guard
            let start = excerpt.line.index(
                excerpt.line.startIndex, offsetBy: excerpt.tokenOffset, limitedBy: excerpt.line.endIndex),
            let end = excerpt.line.index(start, offsetBy: source.rawText.count, limitedBy: excerpt.line.endIndex)
        else { return Text(verbatim: excerpt.line) }
        var line = AttributedString(excerpt.line)
        if let range = Range(start..<end, in: line) {
            line[range].inlinePresentationIntent = .stronglyEmphasized
            line[range].underlineStyle = .single
        }
        return Text(line)
    }
}

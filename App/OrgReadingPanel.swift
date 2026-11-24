import AppKit
import SurimonoCore
import SwiftUI

extension DocumentViewModel {
    func setOrgValue<Value>(_ value: Value, for key: OrgSetting<Value>) {
        guard offersOrgReading, let orgFileInstructions else { return }
        var settings = orgReading
        settings.set(value, for: key, file: orgFileInstructions)
        orgDocumentReading = settings.document
    }

    func allowOrgFileChanges(_ allow: Bool) {
        guard offersOrgReading, let orgFileInstructions else { return }
        var settings = orgReading
        settings.setAllowsFileChanges(allow, file: orgFileInstructions)
        orgDocumentReading = settings.document
    }

    func resetOrgValues() {
        guard offersOrgReading else { return }
        orgDocumentReading.resetValues()
    }

    /// A document can promote only its own edits. A file instruction belongs to its author.
    func makeOrgDefaults() {
        guard offersOrgReading, let file = orgFileInstructions else { return }
        let settings = orgReading
        var defaults = settings.defaults
        let numbers = settings.resolve(.sectionNumbers, file: file)
        let contents = settings.resolve(.tableOfContents, file: file)
        let scripts = settings.resolve(.scripts, file: file)
        if numbers.layer == .document { defaults.sectionNumbers = numbers.value }
        if contents.layer == .document { defaults.tableOfContents = contents.value }
        if scripts.layer == .document { defaults.scripts = scripts.value }
        preferences.setOrgDefaults(defaults)
    }
}

struct OrgReadingPanel: View {
    static let width: CGFloat = 350
    let model: DocumentViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var confirmation: Confirmation?
    private enum Confirmation: Hashable, Identifiable {
        case discard(Int)
        case promote
        var id: Self { self }
    }

    var body: some View {
        SidePanel("Org", width: Self.width) {
            PanelIconButton("xmark", label: "Close") { model.isReadingPanelOpen = false }
        } content: {
            ScrollView {
                OrgReadingRows(model: model, preferences: model.preferences)
                    .disabled(model.orgFileInstructions == nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .overlay(alignment: .leading) { Rectangle().fill(PrintPalette.line).frame(width: 1) }
        .alert(item: $confirmation) { pending in
            switch pending {
            case .discard(let count):
                Alert(
                    title: Text("Discard changes to \(count) file-specified settings? Other changes will be kept."),
                    primaryButton: .destructive(Text("Discard")) {
                        guard let file = model.orgFileInstructions else { return }
                        let current = model.orgReading.fileOverrideCount(file: file)
                        if current > count {
                            confirmation = .discard(current)
                        } else {
                            model.allowOrgFileChanges(false)
                        }
                    }, secondaryButton: .cancel())
            case .promote:
                Alert(
                    title: Text("Use this document’s changes as the Org defaults?"),
                    primaryButton: .default(Text("Apply")) { model.makeOrgDefaults() }, secondaryButton: .cancel())
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.orgFileInstructions?.hasWholeDocumentInstructions == true
                || model.orgDocumentReading.allowsFileChanges
            {
                Toggle(
                    "Allow Changes to File Instructions",
                    isOn: Binding(
                        get: { model.orgDocumentReading.allowsFileChanges },
                        set: { allow in
                            guard let file = model.orgFileInstructions else { return }
                            let count = model.orgReading.fileOverrideCount(file: file)
                            if !allow && count > 0 {
                                confirmation = .discard(count)
                            } else {
                                model.allowOrgFileChanges(allow)
                            }
                        })
                ).toggleStyle(.checkbox).disabled(model.orgFileInstructions == nil)
                if model.orgDocumentReading.allowsFileChanges {
                    Text("Only changed settings take precedence. The original file is never modified.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Changed in This Document: \(model.orgDocumentReading.changedCount)").font(.caption)
                Spacer()
                Button("Revert Changes") { model.resetOrgValues() }.disabled(model.orgDocumentReading.changedCount == 0)
                Menu {
                    Button("Make Org Defaults…") { confirmation = .promote }.disabled(
                        model.orgDocumentReading.changedCount == 0 || model.orgFileInstructions == nil)
                    Button("Copy as an #+OPTIONS Line") {
                        if let line = model.orgDocumentReading.optionsLine { Self.copy(line) }
                    }.disabled(model.orgDocumentReading.optionsLine == nil)
                    Button("Open Org Settings…") {
                        BandArrangementEditorSession.showSection(.org, preferences: model.preferences)
                        openSettings()
                    }
                } label: {
                    Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden).fixedSize()
            }
        }.controlSize(.small)
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

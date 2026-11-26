import AppKit
import SurimonoCore
import SwiftUI

enum ReadingPanelMetrics {
    static let width: CGFloat = 286
}

struct ReadingPanel<Actions: View, Rows: View>: View {
    let title: LocalizedStringKey
    let ready: Bool
    let changed: Int
    var countInFooter = false
    let allowsFileChanges: Binding<Bool>?
    let close: () -> Void
    let revert: () -> Void
    @ViewBuilder let actions: Actions
    @ViewBuilder let rows: Rows

    var body: some View {
        SidePanel(
            title,
            subtitle: changed > 0 && !countInFooter ? String(localized: "Changed in This Document: \(changed)") : "",
            width: ReadingPanelMetrics.width
        ) {
            actions
            PanelIconButton("xmark", label: "Close", action: close)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) { rows }
                    if let allowsFileChanges {
                        ReadingPanelDivider()
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Allow Changes to File Instructions", isOn: allowsFileChanges)
                                .toggleStyle(.checkbox).controlSize(.small).fixedSize(horizontal: false, vertical: true)
                            if allowsFileChanges.wrappedValue {
                                Text("Only changed settings take precedence. The original file is never modified.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .disabled(!ready)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ReadingPanelFooter(count: changed, showsCount: countInFooter, revert: revert)
        }
        .overlay(alignment: .leading) { Rectangle().fill(PrintPalette.line).frame(width: 1) }
    }
}

struct ReadingPanelDivider: View {
    var body: some View {
        Rectangle().fill(PrintPalette.line).frame(height: 1)
            .padding(.vertical, 11)
            .accessibilityHidden(true)
    }
}

struct ReadingPanelGroups<GroupID: Hashable, Section: View>: View {
    let groups: [GroupID]
    let isFoldable: (GroupID) -> Bool
    @ViewBuilder let section: (GroupID) -> Section

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element) { index, group in
                if index > 0 {
                    let previousIsStatic = !isFoldable(groups[index - 1])
                    if previousIsStatic && isFoldable(group) {
                        ReadingPanelDivider()
                    } else {
                        Spacer().frame(height: previousIsStatic ? 23 : 16)
                    }
                }
                VStack(alignment: .leading, spacing: 16) { section(group) }
            }
        }
    }
}

/// An untitled section is a flat list. Only groups in the document panel supply a disclosure binding.
struct ReadingPanelSection<Row: View>: View {
    var title: LocalizedStringResource?
    var expanded: Binding<Bool>?
    var counts = ReadingGroupCounts()
    let ids: [ReadingSettingID]
    @ViewBuilder let row: (ReadingSettingID) -> Row

    var body: some View {
        let rows = ForEach(ids, id: \.self, content: row)
        if let title, let expanded {
            let visibleCounts = expanded.wrappedValue ? ReadingGroupCounts() : counts
            DisclosureGroup(isExpanded: expanded) {
                VStack(alignment: .leading, spacing: 16) { rows }.padding(.top, 8)
            } label: {
                ReadingGroupHeader(title: title, counts: visibleCounts)
                    .accessibilityElement(children: .combine)
                    .accessibilityRemoveTraits(.isHeader)
                    .accessibilityAction { expanded.wrappedValue.toggle() }
            }
            .disclosureGroupStyle(PanelDisclosureStyle())
        } else {
            if let title { ReadingGroupHeader(title: title).foregroundStyle(.secondary) }
            rows
        }
    }
}

struct ReadingGroupHeader: View {
    let title: LocalizedStringResource
    var counts = ReadingGroupCounts()

    var body: some View {
        let heading = Text(title).font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
        if counts.changed == 0 && counts.file == 0 {
            heading.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let detail = HStack(spacing: 6) {
                if counts.changed > 0 { Text("Changed \(counts.changed)") }
                if counts.file > 0 { Text("File \(counts.file)") }
            }.font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack {
                    heading.fixedSize()
                    Spacer(minLength: 4)
                    detail.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    heading
                    detail
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

func copyReadingLine(_ text: String, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

struct ReadingPanelFooter: View {
    let count: Int
    var showsCount = true
    let revert: () -> Void

    var body: some View {
        if count > 0 {
            VStack(spacing: 8) {
                Divider()
                HStack(spacing: 8) {
                    if showsCount {
                        Text("Changed in This Document: \(count)").font(.caption).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Revert All", action: revert).fixedSize()
                }
            }
            .controlSize(.small)
        }
    }
}

struct ReadingFileReason: View {
    let documentName: String
    let fileURL: URL?
    let allowsFileChanges: Bool
    let source: ReadingInstructionSource
    let changed: Bool
    @State private var showsSource = false

    private var reason: String {
        if changed { return String(localized: "Changed (file: \(source.rawText))") }
        if allowsFileChanges {
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
                    Text(verbatim: source.fileName ?? documentName)
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
                        if let url = fileURL, url.isFileURL {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        Button("Copy Line") { copyReadingLine(excerpt.line) }
                    }
                } else {
                    Text(verbatim: source.rawText).font(.system(.caption, design: .monospaced))
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

    private func highlighted(_ excerpt: ReadingInstructionSource.Excerpt) -> Text {
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

struct ReadingMenu<Value: Hashable, Options: View>: View {
    let label: LocalizedStringResource
    @Binding var selection: Value
    let valueLabel: Text
    @ViewBuilder let options: Options
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if !isEnabled && colorScheme == .dark {
                Picker(label, selection: $selection) {
                    options
                } currentValueLabel: {
                    valueLabel.foregroundStyle(PrintPalette.disabledInk)
                }
            } else {
                Picker(label, selection: $selection) { options }
            }
        }
        .labelsHidden().pickerStyle(.menu)
    }
}

struct ReadingSettingControl<Control: View>: View {
    let id: ReadingSettingID
    var token: String?
    let changed: Bool
    let locked: Bool
    let resetHelp: String
    let reset: () -> Void
    @ViewBuilder let control: Control

    var body: some View {
        let title = Text(id.label).fontWeight(changed ? .bold : .regular)
            .foregroundStyle(locked ? .secondary : .primary)
        let picker = control.disabled(locked).accessibilityIdentifier(id.rawValue)
        ReadingChoiceRow(title: title, token: token, picker: picker) {
            if changed {
                ReadingResetButton(help: resetHelp, name: Text("Revert \(String(localized: id.label))"), action: reset)
            } else if token != nil {
                Color.clear.frame(width: 16, height: 1).accessibilityHidden(true)
            }
        }
    }
}

struct ReadingResetButton: View {
    let help: String
    var name = Text("Restore Default")
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "arrow.counterclockwise") }
            .buttonStyle(.plain).help(help)
            .accessibilityLabel(name)
            .accessibilityHint(Text(verbatim: help))
            .frame(width: 16)
    }
}

struct ReadingChoiceRow<Title: View, Choice: View, Reset: View>: View {
    let title: Title
    var token: String?
    let picker: Choice
    @ViewBuilder let reset: Reset

    var body: some View {
        if let token {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                title
                Text(verbatim: token).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                reset
                picker.fixedSize()
            }
        } else {
            let controls = HStack(alignment: .firstTextBaseline, spacing: 6) {
                reset
                picker.fixedSize()
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    title.fixedSize()
                    Spacer(minLength: 6)
                    controls.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    title.fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        controls.fixedSize()
                        // File-specified choices can themselves be wider than the panel.
                        ScrollView(.horizontal) { controls }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

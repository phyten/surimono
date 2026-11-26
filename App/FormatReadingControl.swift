import SurimonoCore
import SwiftUI

enum ReadingResetHelp {
    static func app(format: String, value: String) -> String {
        String(localized: "Restore \(format) default: \(value)")
    }

    static func file(value: String) -> String {
        String(localized: "Restore file value: \(value)")
    }
}

extension ReadingRowResolution {
    func resetHelp(format: String) -> String {
        func help<Value>(_ component: ReadingResolution<Value>, _ value: String) -> String {
            component.source == nil
                ? ReadingResetHelp.app(format: format, value: value) : ReadingResetHelp.file(value: value)
        }
        func toggle(_ present: ReadingResolution<Bool>) -> String {
            help(present, present.inherited ? String(localized: "On") : String(localized: "Off"))
        }
        switch self {
        case .toggle(let present):
            return toggle(present)
        case .outline(let present, let depth):
            if (present.source == nil) != (depth.source == nil) {
                let levels = String(localized: ReadingOutlinePicker.title(for: depth.inherited))
                if depth.layer == .document {
                    let restoreDepth = help(depth, levels)
                    return present.layer == .document
                        ? [toggle(present), restoreDepth].joined(separator: "\n") : restoreDepth
                }
                return toggle(present)
            }
            let value = String(localized: ReadingOutlinePicker.title(for: present.inherited ? depth.inherited : nil))
            return help(present, value)
        }
    }

    var isChanged: Bool {
        switch self {
        case .toggle(let present): present.layer == .document
        case .outline(let present, let depth): present.layer == .document || depth.layer == .document
        }
    }
}

/// A single outline picker edits two independently resolved components.
struct FormatReadingControl: View {
    let id: ReadingSettingID
    let row: ReadingRowResolution
    let resetHelp: String
    let documentName: String
    let fileURL: URL?
    let allowsFileChanges: Bool
    let set: @MainActor @Sendable (ReadingSettingValue) -> Void
    let revert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch row {
            case .toggle(let present):
                control(locked: present.isLocked) {
                    Toggle(isOn: Binding(get: { present.value }, set: { set(.toggle($0)) })) { Text(id.label) }
                        .labelsHidden().toggleStyle(.checkbox)
                }
                reason(present.source, changed: present.layer == .document)
            case .outline(let present, let depth):
                let picker = ReadingOutlinePicker(label: id.label, present: present, depth: depth, set: set)
                control(locked: !picker.hasAlternative) { picker }
                reason(
                    present.source,
                    changed: present.layer == .document || present.source == depth.source && depth.layer == .document,
                    partialLock: presenceHint(present, depth: depth))
                if present.source != depth.source {
                    reason(
                        depth.source, changed: depth.layer == .document,
                        partialLock: depth.isLocked && !present.isLocked ? .depth : nil)
                }
            }
        }
    }

    private func presenceHint(_ present: ReadingResolution<Bool>, depth: ReadingResolution<ReadingDepth>)
        -> ReadingFileReason.PartialLock?
    {
        guard present.isLocked, !depth.isLocked else { return nil }
        return present.value ? .enabled : .disabled
    }

    private func control<Picker: View>(locked: Bool, @ViewBuilder picker: () -> Picker) -> some View {
        ReadingSettingControl(
            id: id, changed: row.isChanged, locked: locked, resetHelp: resetHelp,
            reset: revert, control: picker)
    }

    @ViewBuilder private func reason(
        _ source: ReadingInstructionSource?, changed: Bool, partialLock: ReadingFileReason.PartialLock? = nil
    ) -> some View {
        if let source {
            ReadingFileReason(
                documentName: documentName, fileURL: fileURL, allowsFileChanges: allowsFileChanges, source: source,
                changed: changed, partialLock: partialLock)
        }
    }
}

struct ReadingOutlinePicker: View {
    let label: LocalizedStringResource
    let present: ReadingResolution<Bool>
    let depth: ReadingResolution<ReadingDepth>
    let set: @MainActor @Sendable (ReadingSettingValue) -> Void

    private var value: ReadingDepth? { present.value ? depth.value : nil }

    func allows(_ choice: ReadingDepth?) -> Bool {
        ReadingRowResolution.outline(present: present, depth: depth)
            .allowsOutline(present: choice != nil, depth: choice ?? depth.value)
    }

    private var choices: [ReadingDepth?] {
        var values: [ReadingDepth?] = [nil] + (1...6).map { .levels($0) } + [.all]
        if !values.contains(depth.value) { values.append(depth.value) }
        return values
    }

    static func title(for value: ReadingDepth?, locale: Locale = .current) -> LocalizedStringResource {
        switch value {
        case nil: LocalizedStringResource("None", locale: locale)
        case .all: LocalizedStringResource("All Levels", locale: locale)
        case .levels(let depth): LocalizedStringResource("Up to Level \(depth)", locale: locale)
        }
    }

    var hasAlternative: Bool { choices.contains { $0 != value && allows($0) } }

    var body: some View {
        let selection = Binding(
            get: { value },
            set: { choice in
                set(.outline(present: choice != nil, depth: choice ?? depth.value))
            })
        ReadingMenu(label: label, selection: selection, valueLabel: Text(Self.title(for: value))) {
            ForEach(choices, id: \.self) { choice in
                Text(Self.title(for: choice)).tag(choice).disabled(!allows(choice))
            }
        }
    }
}

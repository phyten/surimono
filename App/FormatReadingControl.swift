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

extension ReadingResolution<Bool> {
    func value(inheritsStyle: Bool) -> Bool? {
        inheritsStyle && layer == .app ? nil : value
    }
}

extension ReadingSettingID {
    func toggleTitle(_ value: Bool?) -> LocalizedStringResource {
        guard let value else { return "From Style" }
        if self == .sectionNumbers { return value ? "All" : "None" }
        return value ? "On" : "Off"
    }
}

extension ReadingRowResolution {
    func resetHelp(format: String, id: ReadingSettingID, inheritsStyle: Bool = false) -> String {
        func help<Value>(_ component: ReadingResolution<Value>, _ value: String) -> String {
            component.source == nil
                ? ReadingResetHelp.app(format: format, value: value) : ReadingResetHelp.file(value: value)
        }
        func toggle(_ present: ReadingResolution<Bool>) -> String {
            help(present, present.inherited ? String(localized: "On") : String(localized: "Off"))
        }
        if inheritsStyle { return ReadingResetHelp.app(format: format, value: String(localized: "From Style")) }
        switch self {
        case .toggle(let present):
            return help(present, String(localized: id.toggleTitle(present.inherited)))
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
    let format: DocumentFormat
    let id: ReadingSettingID
    let row: ReadingRowResolution
    let resetHelp: String
    let documentName: String
    let fileURL: URL?
    let allowsFileChanges: Bool
    var inheritsStyle = false
    let set: @MainActor @Sendable (ReadingSettingValue) -> Void
    let revert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch row {
            case .toggle(let present):
                control(locked: present.isLocked) {
                    if id == .sectionNumbers {
                        let selection = Binding<Bool?>(
                            get: { present.value(inheritsStyle: inheritsStyle) },
                            set: { choice in
                                if let choice { set(.toggle(choice)) } else { revert() }
                            })
                        ReadingMenu(
                            label: id.label, selection: selection,
                            valueLabel: Text(id.toggleTitle(selection.wrappedValue))
                        ) {
                            if inheritsStyle { Text("From Style").tag(nil as Bool?) }
                            Text(id.toggleTitle(false)).tag(Optional(false))
                            Text(id.toggleTitle(true)).tag(Optional(true))
                        }
                    } else {
                        Toggle(isOn: Binding(get: { present.value }, set: { set(.toggle($0)) })) { Text(id.label) }
                            .labelsHidden().toggleStyle(.checkbox)
                    }
                }
                reason(present.source, changed: present.layer == .document)
            case .outline(let present, let depth):
                let picker = ReadingOutlinePicker(
                    label: id.label, present: present, depth: depth, levels: format == .asciidoc ? 0...5 : 1...6,
                    restoreStyle: inheritsStyle ? revert : nil,
                    set: set)
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
    var levels = 1...6
    var restoreStyle: (() -> Void)?
    let set: @MainActor @Sendable (ReadingSettingValue) -> Void

    enum Selection: Hashable {
        case style
        case outline(ReadingDepth?)
    }

    var selection: Selection {
        guard let enabled = present.value(inheritsStyle: restoreStyle != nil) else { return .style }
        return .outline(enabled ? depth.value : nil)
    }

    func allows(_ choice: ReadingDepth?) -> Bool {
        ReadingRowResolution.outline(present: present, depth: depth)
            .allowsOutline(present: choice != nil, depth: choice ?? depth.value)
    }

    private var choices: [ReadingDepth?] {
        var values: [ReadingDepth?] = [nil] + levels.map { .levels($0) } + [.all]
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

    var hasAlternative: Bool { restoreStyle != nil || choices.contains { .outline($0) != selection && allows($0) } }

    var body: some View {
        let binding = Binding(
            get: { selection },
            set: { choice in
                switch choice {
                case .style: restoreStyle?()
                case .outline(let limit): set(.outline(present: limit != nil, depth: limit ?? depth.value))
                }
            })
        let title: LocalizedStringResource =
            selection == .style ? "From Style" : Self.title(for: present.value ? depth.value : nil)
        ReadingMenu(label: label, selection: binding, valueLabel: Text(title)) {
            if restoreStyle != nil { Text("From Style").tag(Selection.style) }
            ForEach(choices, id: \.self) { choice in
                Text(Self.title(for: choice)).tag(Selection.outline(choice)).disabled(!allows(choice))
            }
        }
    }
}

import SurimonoCore
import SwiftUI

private protocol OrgReadingChoice: Hashable, Sendable {
    var title: String { get }
    var choices: [Self] { get }
    associatedtype Control: View
    @MainActor func control(_ label: LocalizedStringResource, selection: Binding<Self>, key: OrgSettingID) -> Control
}

extension OrgReadingChoice {
    @MainActor fileprivate func control(_ label: LocalizedStringResource, selection: Binding<Self>, key: OrgSettingID)
        -> some View
    {
        Picker(selection: selection) {
            ForEach(choices, id: \.self) { Text(verbatim: $0.title).tag($0) }
        } label: {
            Text(label)
        }
        .labelsHidden().pickerStyle(.menu)
    }
}

extension Bool: OrgReadingChoice {
    fileprivate var title: String { self ? String(localized: "On") : String(localized: "Off") }
    fileprivate var choices: [Self] { [false, true] }
    @MainActor fileprivate func control(_ label: LocalizedStringResource, selection: Binding<Self>, key: OrgSettingID)
        -> some View
    {
        Toggle(isOn: selection) { Text(label) }.labelsHidden().toggleStyle(.checkbox)
    }
}

extension Int: OrgReadingChoice {
    fileprivate var title: String {
        self == .max
            ? String(localized: "All Levels")
            : (self == 0 ? String(localized: "None") : String(localized: "Up to Level \(self)"))
    }
    fileprivate var choices: [Int] {
        let levels = Array(0...6) + [Int.max]
        return levels.contains(self) ? levels : levels + [self]
    }
}

extension OrgReadingDefaults.Depth: OrgReadingChoice {
    fileprivate var title: String {
        switch self {
        case .off: String(localized: "None")
        case .all: String(localized: "All Levels")
        case .levels(let depth): String(localized: "Up to Level \(depth)")
        }
    }

    fileprivate var choices: [Self] {
        var values: [Self] = [.off, .all] + (1...6).map { .levels($0) }
        // A file may specify a depth outside the menu's usual range.
        if !values.contains(self) { values.append(self) }
        return values
    }
}

extension OrgReadingDefaults.Scripts: OrgReadingChoice {
    fileprivate var title: String {
        switch self {
        case .braces: String(localized: "Only in { }")
        case .all: String(localized: "Even without { }")
        case .off: String(localized: "Leave as Written")
        }
    }

    fileprivate var choices: [Self] { [.braces, .all, .off] }
}

extension OrgReadingDefaults.Tags: OrgReadingChoice {
    fileprivate var title: String {
        switch self {
        case .all: String(localized: "On")
        case .off: String(localized: "Off")
        case .notInContents: String(localized: "Except in Contents")
        }
    }
    fileprivate var choices: [Self] { Self.allCases }
}

extension OrgReadingDefaults.Math: OrgReadingChoice {
    fileprivate var title: String {
        switch self {
        case .render: String(localized: "Typeset")
        case .verbatim: String(localized: "Show Source")
        case .off: String(localized: "None")
        }
    }
    fileprivate var choices: [Self] { Self.allCases }
}

extension OrgReadingDefaults.Timestamps: OrgReadingChoice {
    fileprivate var title: String {
        switch self {
        case .all: String(localized: "All")
        case .active: String(localized: "Active Only")
        case .inactive: String(localized: "Inactive Only")
        case .off: String(localized: "None")
        }
    }
    fileprivate var choices: [Self] { Self.allCases }
}

extension OrgReadingDefaults.Archived: OrgReadingChoice {
    fileprivate var title: String {
        switch self {
        case .all: String(localized: "Entire Tree")
        case .headline: String(localized: "Heading Only")
        case .off: String(localized: "None")
        }
    }
    fileprivate var choices: [Self] { Self.allCases }
}

extension OrgReadingDefaults.Tasks: OrgReadingChoice {
    fileprivate var title: String {
        switch self {
        case .all: String(localized: "All")
        case .todo: String(localized: "Unfinished Only")
        case .done: String(localized: "Completed Only")
        case .off: String(localized: "None")
        case .keywords: token
        }
    }
    fileprivate var choices: [Self] {
        let values: [Self] = [.all, .todo, .done, .off]
        return values.contains(self) ? values : values + [self]
    }
}

extension OrgReadingDefaults.Names: OrgReadingChoice {
    fileprivate var title: String {
        switch self {
        case .all: String(localized: "Show All")
        case .off: String(localized: "Don't Show")
        case .excluding(["LOGBOOK"]): String(localized: "Show All Except LOGBOOK")
        case .including, .excluding: token
        }
    }
    fileprivate var choices: [Self] { [.off, .all] }
    @MainActor fileprivate func control(_ label: LocalizedStringResource, selection: Binding<Self>, key: OrgSettingID)
        -> some View
    {
        var values = choices
        if key == .drawers { values.append(.excluding(["LOGBOOK"])) }
        if !values.contains(self) { values.append(self) }
        return Picker(selection: selection) {
            ForEach(values, id: \.self) { Text(verbatim: $0.title).tag($0) }
        } label: {
            Text(label)
        }.labelsHidden().pickerStyle(.menu)
    }
}

/// Keep the typed key and its value titles identical in the row and in the confirmation.
private protocol OrgReadingField {
    func row(in rows: OrgReadingRows) -> AnyView
    func difference(from current: OrgReadingDefaults, to target: OrgReadingDefaults) -> ReadingSettingChange?
}

extension OrgSetting: OrgReadingField where Value: OrgReadingChoice {
    fileprivate func row(in rows: OrgReadingRows) -> AnyView { AnyView(rows.setting(self)) }

    fileprivate func difference(from current: OrgReadingDefaults, to target: OrgReadingDefaults)
        -> ReadingSettingChange?
    {
        let old = current[keyPath: fallback]
        let new = target[keyPath: fallback]
        guard old != new else { return nil }
        return (String(localized: id.label), old.title, new.title)
    }
}

extension OrgSettingID {
    fileprivate var field: any OrgReadingField {
        switch self {
        case .sectionNumbers: OrgSetting.sectionNumbers
        case .tableOfContents: OrgSetting.tableOfContents
        case .headlineLevels: OrgSetting.headlineLevels
        case .tags: OrgSetting.tags
        case .scripts: OrgSetting.scripts
        case .preserveBreaks: OrgSetting.preserveBreaks
        case .emphasis: OrgSetting.emphasis
        case .math: OrgSetting.math
        case .planning: OrgSetting.planning
        case .clocks: OrgSetting.clocks
        case .priority: OrgSetting.priority
        case .todo: OrgSetting.todo
        case .statistics: OrgSetting.statistics
        case .tasks: OrgSetting.tasks
        case .title: OrgSetting.title
        case .author: OrgSetting.author
        case .date: OrgSetting.date
        case .drawers: OrgSetting.drawers
        case .properties: OrgSetting.properties
        case .timestamps: OrgSetting.timestamps
        case .footnotes: OrgSetting.footnotes
        case .tables: OrgSetting.tables
        case .fixedWidth: OrgSetting.fixedWidth
        case .archived: OrgSetting.archived
        }
    }
}

extension AppPreferences {
    func setOrgDefaults(_ defaults: OrgReadingDefaults) {
        orgReadingDefaults = defaults == .surimono ? nil : defaults
    }
}

/// Both surfaces share the same rows; only the document can inherit a file instruction.
struct OrgReadingRows: View {
    var model: DocumentViewModel?
    let preferences: AppPreferences
    var changedOnly = false
    private var file: OrgFileInstructions { model?.orgFileInstructions ?? .init() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let changed = preferences.orgReadingDefaults?.changedIDs(from: .surimono) ?? []
            ForEach(OrgReadingGroup.allCases, id: \.self) { group in
                let ids = group.settings.filter { !changedOnly || changed.contains($0) }
                if !ids.isEmpty {
                    let title = Text(group.title).font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
                    let rows = ForEach(ids, id: \.self) { $0.field.row(in: self) }
                    if let model, group == .tasks || group == .details {
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { model.orgGroupExpanded(group) },
                                set: { model.setOrgGroupExpanded($0, for: group) })
                        ) {
                            VStack(alignment: .leading, spacing: 16) { rows }.padding(.top, 8)
                        } label: {
                            title.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disclosureGroupStyle(PanelDisclosureStyle())
                    } else {
                        title
                        rows
                    }
                }
            }
        }
    }

    @ViewBuilder fileprivate func setting<Value: OrgReadingChoice>(_ key: OrgSetting<Value>) -> some View {
        let label = key.id.label
        let token = key.id.token
        let path = key.fallback
        let defaults = preferences.orgReadingDefaults ?? .surimono
        let resolved = model?.orgReading.resolve(key, file: file)
        let current = resolved?.value ?? defaults[keyPath: path]
        let inherited = resolved?.inherited ?? OrgReadingDefaults.surimono[keyPath: path]
        let changed = resolved.map { $0.layer == .document } ?? (current != inherited)
        let locked = resolved?.source != nil && model?.orgDocumentReading.allowsFileChanges == false
        let editsDefaults = model == nil
        let set: @MainActor @Sendable (Value) -> Void = { [weak model, preferences] value in
            if let model {
                if !model.isWindowClosed { model.setOrgValue(value, for: key) }
            } else if editsDefaults {
                var updated = preferences.orgReadingDefaults ?? .surimono
                updated[keyPath: path] = value
                preferences.setOrgDefaults(updated)
            }
        }
        if !changedOnly || changed {
            let title = Text(label).fontWeight(changed ? .bold : .regular).foregroundStyle(
                locked ? .secondary : .primary)
            let picker = current.control(label, selection: Binding(get: { current }, set: set), key: key.id).disabled(
                locked
            )
            .accessibilityIdentifier(key.id.rawValue)
            let row = VStack(alignment: .leading, spacing: 4) {
                OrgReadingChoiceRow(title: title, token: model == nil ? token : nil, picker: picker) {
                    if changed {
                        let help =
                            resolved?.source != nil
                            ? String(localized: "Restore file value: \(inherited.title)")
                            : (model == nil
                                ? String(localized: "Restore shipping value: \(inherited.title)")
                                : String(localized: "Restore Org default: \(inherited.title)"))
                        OrgReadingResetButton(help: help, name: Text("Revert \(String(localized: label))")) {
                            set(inherited)
                        }
                    } else if model == nil {
                        Color.clear.frame(width: 16, height: 1).accessibilityHidden(true)
                    }
                }
                if key.id == .headlineLevels {
                    Text("Deeper headings become list items.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let model, let source = resolved?.source {
                    OrgFileReason(model: model, source: source, changed: changed)
                }
                if let notes = resolved?.notes, !notes.isEmpty {
                    let marked = notes.count { $0.kind == .unnumberedHeading }
                    VStack(alignment: .leading, spacing: 4) {
                        if marked > 0 { Text("Headings marked :UNNUMBERED: \(marked)") }
                        if notes.contains(where: { $0.kind == .bodyContents }) {
                            Text("A table of contents appears at #+TOC: in the body.")
                        }
                        if notes.contains(where: { $0.kind == .excludedFromContents }) {
                            Text("Headings excluded from the table of contents: \(file.excludedHeadingCount)")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model == nil { row.settingSearchRow(label.key) } else { row }
        }
    }
}

struct OrgReadingResetButton: View {
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

struct OrgReadingChoiceRow<Title: View, Choice: View, Reset: View>: View {
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

struct OrgChangedSettingsFilter {
    var isOn = false

    func showsEmpty(_ current: OrgReadingDefaults) -> Bool { isOn && current == .surimono }

    mutating func didApply(_ values: OrgReadingDefaults) {
        if values == .surimono { isOn = false }
    }
}

struct OrgReadingDefaultsPane: View {
    let preferences: AppPreferences
    #if DEBUG
        @State private var filter = OrgChangedSettingsFilter(
            isOn: DebugSnapshot.orgDefaultsFixture?.changedOnly == true)
    #else
        @State private var filter = OrgChangedSettingsFilter()
    #endif

    static func defaults(_ current: OrgReadingDefaults) -> ReadingDefaults<OrgReadingDefaults> {
        ReadingDefaults(
            builtIn: .surimono,
            alternatives: [
                .init(
                    values: .emacs, status: "Emacs defaults", action: "Use Emacs Defaults…",
                    confirmation: "Use Emacs Defaults", question: "Use Emacs defaults?")
            ],
            current: current)
    }

    static func differences(from current: OrgReadingDefaults, to target: OrgReadingDefaults) -> [ReadingSettingChange] {
        OrgReadingGroup.allCases.flatMap(\.settings).compactMap { $0.field.difference(from: current, to: target) }
    }

    var body: some View {
        let current = preferences.orgReadingDefaults ?? .surimono
        let controls = ReadingDefaultsControls(
            defaults: Self.defaults(current), resetQuestion: "Reset Org settings to defaults?",
            differences: Self.differences,
            apply: { values in
                preferences.setOrgDefaults(values)
                filter.didApply(values)
            },
            header: {
                Toggle("Show Only Changed Settings", isOn: $filter.isOn)
                    .toggleStyle(.checkbox)
            },
            rows: {
                if filter.showsEmpty(current) {
                    Text("No settings differ from Surimono defaults").foregroundStyle(.secondary)
                } else {
                    OrgReadingRows(preferences: preferences, changedOnly: filter.isOn)
                }
            })
        #if DEBUG
            var preview = controls
            preview.snapshotTarget = DebugSnapshot.orgDefaultsFixture?.target
            return preview
        #else
            return controls
        #endif
    }
}

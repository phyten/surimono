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
        case .braces: String(localized: "Only with { }")
        case .all: String(localized: "With or without Braces")
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
        case .verbatim: String(localized: "Show Formula Source")
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
        case .all: String(localized: "All")
        case .off: String(localized: "None")
        case .excluding(["LOGBOOK"]): String(localized: "Except LOGBOOK")
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
                    Text(group.title).font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
                    ForEach(ids, id: \.self) { row($0) }
                }
            }
        }
    }

    @ViewBuilder private func row(_ id: OrgSettingID) -> some View {
        switch id {
        case .sectionNumbers: setting(OrgSetting.sectionNumbers)
        case .tableOfContents: setting(OrgSetting.tableOfContents)
        case .headlineLevels: setting(OrgSetting.headlineLevels)
        case .tags: setting(OrgSetting.tags)
        case .scripts: setting(OrgSetting.scripts)
        case .preserveBreaks: setting(OrgSetting.preserveBreaks)
        case .emphasis: setting(OrgSetting.emphasis)
        case .math: setting(OrgSetting.math)
        case .planning: setting(OrgSetting.planning)
        case .clocks: setting(OrgSetting.clocks)
        case .priority: setting(OrgSetting.priority)
        case .todo: setting(OrgSetting.todo)
        case .statistics: setting(OrgSetting.statistics)
        case .tasks: setting(OrgSetting.tasks)
        case .title: setting(OrgSetting.title)
        case .author: setting(OrgSetting.author)
        case .date: setting(OrgSetting.date)
        case .drawers: setting(OrgSetting.drawers)
        case .properties: setting(OrgSetting.properties)
        case .timestamps: setting(OrgSetting.timestamps)
        case .footnotes: setting(OrgSetting.footnotes)
        case .tables: setting(OrgSetting.tables)
        case .fixedWidth: setting(OrgSetting.fixedWidth)
        case .archived: setting(OrgSetting.archived)
        }
    }

    @ViewBuilder private func setting<Value: OrgReadingChoice>(_ key: OrgSetting<Value>) -> some View {
        let label = key.id.label
        let token = key.id.token
        let path = key.fallback
        let defaults = preferences.orgReadingDefaults ?? .surimono
        let resolved = model?.orgReading.resolve(key, file: file)
        let current = resolved?.value ?? defaults[keyPath: path]
        let inherited = resolved?.inherited ?? OrgReadingDefaults.surimono[keyPath: path]
        let changed = resolved.map { $0.layer == .document } ?? (current != inherited)
        let locked = resolved?.source != nil && model?.orgDocumentReading.allowsFileChanges == false
        let set: @MainActor @Sendable (Value) -> Void = { value in
            if let model {
                model.setOrgValue(value, for: key)
            } else {
                var updated = preferences.orgReadingDefaults ?? .surimono
                updated[keyPath: path] = value
                preferences.setOrgDefaults(updated)
            }
        }
        if !changedOnly || changed {
            let title = Text(label).fontWeight(changed ? .bold : .regular).foregroundStyle(
                locked ? .secondary : .primary)
            let picker = current.control(label, selection: Binding(get: { current }, set: set), key: key.id).disabled(
                locked)
            let row = VStack(alignment: .leading, spacing: 4) {
                OrgReadingChoiceRow(title: title, token: model == nil ? token : nil, picker: picker) {
                    if changed {
                        let help =
                            resolved?.source != nil
                            ? String(localized: "Restore file value: \(inherited.title)")
                            : (model == nil
                                ? String(localized: "Restore shipping value: \(inherited.title)")
                                : String(localized: "Restore Org default: \(inherited.title)"))
                        OrgReadingResetButton(help: help) { set(inherited) }
                    } else {
                        Color.clear.frame(width: 16, height: 1).accessibilityHidden(true)
                    }
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
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "arrow.counterclockwise") }
            .buttonStyle(.plain).help(help).accessibilityLabel(Text(verbatim: help)).frame(width: 16)
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
                picker.fixedSize()
                reset
            }
            // Keep the full title and the selected value readable in longer translations.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title.fixedSize()
                    controls
                }
                VStack(alignment: .leading, spacing: 4) {
                    title.fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        controls
                        // A file-specified depth can have many more digits than the standard choices.
                        ScrollView(.horizontal) { controls }
                    }
                }
            }
        }
    }
}

struct OrgReadingDefaultsPane: View {
    let preferences: AppPreferences
    @State private var pending: OrgReadingDefaults?
    @State private var changedOnly = false

    var body: some View {
        Section {
            OrgReadingRows(preferences: preferences, changedOnly: changedOnly)
        } header: {
            HStack {
                Toggle("Show Only Changed Settings", isOn: $changedOnly)
                    .toggleStyle(.checkbox).fixedSize()
                Spacer()
                Menu("Preset") {
                    Button("Surimono Defaults") { choose(.surimono) }
                    Button("Emacs Defaults") {
                        choose(.emacs)
                    }
                }.fixedSize()
            }
            .font(.body).textCase(nil)
        }
        .alert(
            "Replace changed Org defaults?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }), presenting: pending
        ) { preset in
            Button("Apply") { preferences.setOrgDefaults(preset) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func choose(_ preset: OrgReadingDefaults) {
        let current = preferences.orgReadingDefaults ?? .surimono
        if Self.overwritesChanges(current, with: preset) {
            pending = preset
        } else {
            preferences.setOrgDefaults(preset)
        }
    }

    static func overwritesChanges(_ current: OrgReadingDefaults, with preset: OrgReadingDefaults) -> Bool {
        preset.overwritesChanges(in: current)
    }
}

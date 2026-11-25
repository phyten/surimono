import AppKit
import SurimonoCore
import SwiftUI

struct ShortcutSettingsView: View {
    let controller: ShortcutController
    @Environment(\.settingsSearchHits) private var settingsHits
    @State private var search = ""
    @State private var restoringAll = false
    @State private var restoreSnapshot = ShortcutConfiguration()
    @State private var importDraft: ShortcutImportReview?
    @State private var fileError: String?
    @FocusState private var actionsFocused: Bool
    var files = ShortcutArchiveFiles()

    var body: some View {
        let statuses = controller.settingsStatuses
        let groups =
            search.isEmpty
            ? Self.allGroups
            : Dictionary(
                grouping: ShortcutOperation.catalog.filter { matches($0) }, by: \.group)
        ScrollViewReader { proxy in
            Form {
                archiveControls
                ForEach(SettingsCatalogue.shortcutGroups, id: \.self) { group in
                    localSection(group, rows: groups[group] ?? [], statuses: statuses)
                }
                fixedSection(hasLocalMatches: groups.keys.contains { $0 != .global })
                globalSection(rows: groups[.global] ?? [], statuses: statuses)
            }
            .modifier(SettingsSearchReveal(proxy: proxy))
            .formStyle(.grouped)
            .onChange(of: fileError) { _, value in ShortcutHints.announce(value) }
            .sheet(isPresented: $restoringAll, onDismiss: { actionsFocused = true }) {
                restoreConfirmation
            }
            .sheet(
                isPresented: Binding(get: { importDraft != nil }, set: { if !$0 { importDraft = nil } }),
                onDismiss: { actionsFocused = true }
            ) {
                if let importDraft { ShortcutImportView(controller: controller, review: importDraft) }
            }
            #if DEBUG
                .task {
                    search = DebugSnapshot.shortcutSearch ?? ""
                    if DebugSnapshot.shortcutReview == "restore" {
                        restoreSnapshot = controller.snapshot
                        restoringAll = true
                    } else if DebugSnapshot.shortcutReview == "import" {
                        importDraft = ShortcutImportReview(
                            archive: ShortcutArchive(
                                configuration: .init(overrides: [
                                    .documentReload: [.init(key: .character("p"), modifiers: .command)],
                                    .documentPrintSystem: [],
                                    .globalClipboardOpen: [
                                        .init(key: .macVirtualKey(38), modifiers: [.control, .option, .command])
                                    ],
                                ])), original: controller.snapshot)
                    }
                    if DebugSnapshot.shortcutShowGlobal {
                        // Let the form lay out the filtered rows before finding the Global section.
                        await Task.yield()
                        proxy.scrollTo("shortcut-global", anchor: .top)
                    }
                }
            #endif
        }
    }

    private var archiveControls: some View {
        Section {
            HStack(spacing: 8) {
                SettingsSearchField(title: "Search Shortcuts", text: $search)
                Menu {
                    archiveButtons
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize().focused($actionsFocused)
                .help("Shortcut Actions")
                .accessibilityLabel(Text("Shortcut Actions"))
            }
            .settingSearchRow("Search Shortcuts")
            if let fileError {
                Text(fileError).foregroundStyle(PrintPalette.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var archiveButtons: some View {
        Button("Import Shortcuts…") {
            actionsFocused = false
            fileError = nil
            files.importFile { result in
                do {
                    if let result { importDraft = try controller.importReview(result.get()) }
                } catch { fileError = ShortcutArchiveFiles.message(error) }
                actionsFocused = true
            }
        }.disabled(controller.loadError)
        Button("Export Shortcuts…") {
            actionsFocused = false
            fileError = nil
            files.exportFile(controller.snapshot) { result in
                if case .failure(let error) = result { fileError = ShortcutArchiveFiles.message(error) }
                actionsFocused = true
            }
        }.disabled(controller.loadError)
        Divider()
        Button("Restore All Defaults…") {
            actionsFocused = false
            restoreSnapshot = controller.snapshot
            fileError = nil
            restoringAll = true
        }.disabled(controller.loadError || !controller.canRestoreAll)
    }

    private var restoreConfirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore All Defaults?").font(.headline)
            Text(
                String.localizedStringWithFormat(
                    String(localized: "Custom assignments to remove: %lld"),
                    restoreSnapshot.overrides.count))
            Text(
                "Local shortcuts return to their defaults. Global shortcuts become unassigned. macOS assignments stay unchanged."
            )
            .fixedSize(horizontal: false, vertical: true)
            if let fileError { Text(fileError).foregroundStyle(PrintPalette.warn) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { restoringAll = false }.keyboardShortcut(.cancelAction)
                Button("Restore All Defaults") {
                    do {
                        try controller.restoreAll(expectedSnapshot: restoreSnapshot)
                        restoringAll = false
                    } catch {
                        fileError = ShortcutController.message(error)
                    }
                }
            }
        }.padding(24).frame(width: 440)
    }

    private static let allGroups = Dictionary(grouping: ShortcutOperation.catalog, by: \.group)

    @ViewBuilder private func localSection(
        _ group: ShortcutGroup, rows: [ShortcutOperation],
        statuses: [ShortcutOperationID: ShortcutController.SettingsStatus]
    ) -> some View {
        if !rows.isEmpty {
            let sharedScope = ShortcutText.scope(Self.groupScope(group))
            Section {
                ForEach(rows, id: \.id) { operation in
                    let rowScope = scope(operation)
                    if controller.isConnected(operation.id)
                        && (operation.id != .appCheckUpdates || AppUpdater.shared.isAvailable)
                    {
                        EditableShortcutRow(
                            controller: controller, operation: operation.id, status: statuses[operation.id] ?? .normal,
                            scope: rowScope == sharedScope ? nil : rowScope
                        )
                        .settingSearchRow(operation.id.rawValue)
                    } else {
                        ShortcutInfoRow(
                            name: ShortcutText.name(operation.id), scope: rowScope == sharedScope ? nil : rowScope,
                            keys: operation.defaults.map { controller.layout.display($0) },
                            spokenKeys: operation.defaults.map { controller.layout.spoken($0) }
                        )
                        .settingSearchRow(operation.id.rawValue)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ShortcutText.group(group))
                    Text(sharedScope).font(.caption).foregroundStyle(PrintPalette.ink2)
                }
            }
        }
    }

    /// A group's usual scope stays stable while searching; exceptions remain beside their operations.
    static func groupScope(_ group: ShortcutGroup) -> ShortcutApplicability {
        switch group {
        case .application, .global: .application
        case .documentAndPrinting, .reading: .document
        case .styles: .themedText
        case .lists: .binderOrImages
        }
    }

    // Keep native editing and window commands under their shared footer in catalog order.
    private static let fixedGroups: [(reason: String, keys: [ShortcutFixedKey])] = {
        var groups: [(reason: String, keys: [ShortcutFixedKey])] = []
        for key in ShortcutFixedKey.catalog {
            let reason = ShortcutText.fixedReason(key.behavior)
            if let index = groups.firstIndex(where: { $0.reason == reason }) {
                groups[index].keys.append(key)
            } else {
                groups.append((reason, [key]))
            }
        }
        return groups
    }()

    @ViewBuilder private func fixedSection(hasLocalMatches: Bool) -> some View {
        let groups =
            search.isEmpty
            ? Self.fixedGroups
            : Self.fixedGroups.compactMap { group in
                let keys = group.keys.filter { key in
                    settingsHits.anchors.contains(key.behavior.rawValue)
                        || matches(
                            [
                                ShortcutText.fixedName(key.behavior), String(localized: "Fixed Keys"),
                                String(localized: "In Surimono"),
                            ]
                                + key.combinations.map { controller.layout.display($0) })
                }
                return keys.isEmpty ? nil : (reason: group.reason, keys: keys)
            }
        if !groups.isEmpty {
            // One group per reason, which is its footer; the heading goes on the first.
            ForEach(Array(groups.enumerated()), id: \.element.reason) { index, group in
                Section {
                    ForEach(group.keys, id: \.behavior) { key in
                        ShortcutInfoRow(
                            name: ShortcutText.fixedName(key.behavior),
                            keys: key.combinations.map { controller.layout.display($0) },
                            spokenKeys: key.combinations.map { controller.layout.spoken($0) },
                            emptyLabel: String(localized: "Managed by macOS")
                        )
                        .settingSearchRow(key.behavior.rawValue)
                    }
                } header: {
                    if index == 0 { Text("Fixed Keys") }
                } footer: {
                    SettingsFootnote(verbatim: group.reason)
                }
            }
        }
        if groups.isEmpty && !hasLocalMatches {
            Text("No matching shortcuts").foregroundStyle(PrintPalette.ink2)
        }
    }

    private func globalSection(
        rows: [ShortcutOperation], statuses: [ShortcutOperationID: ShortcutController.SettingsStatus]
    ) -> some View {
        Section {
            if let error = controller.migrationError {
                Text(error).foregroundStyle(PrintPalette.warn).fixedSize(horizontal: false, vertical: true)
            }
            if controller.loadError {
                Text(ShortcutController.message(ShortcutController.EditError.savedDataUnavailable))
                    .foregroundStyle(PrintPalette.warn).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows, id: \.id) { operation in
                EditableShortcutRow(
                    controller: controller, operation: operation.id, status: statuses[operation.id] ?? .normal
                )
                .settingSearchRow(operation.id.rawValue)
            }
            if rows.isEmpty { Text("No matching shortcuts").foregroundStyle(PrintPalette.ink2) }
        } header: {
            HStack {
                Image(systemName: "globe").accessibilityHidden(true)
                Text("Global")
            }
        } footer: {
            SettingsFootnote("These work while Surimono is running, even when another app is in front.")
        }
        .id("shortcut-global")
    }

    private func scope(_ operation: ShortcutOperation) -> String {
        if operation.id == .appCheckUpdates && !AppUpdater.shared.isAvailable {
            return String(localized: "Updates are unavailable in this build.")
        }
        if operation.id.rawValue.hasPrefix("reading.") {
            return String(localized: "With paper focus; page turns depend on reading direction, zoom and scrolling.")
        }
        if operation.id == .documentPrint {
            return String(localized: "Opens the print screen; a new press there prints to the selected printer.")
        }
        return ShortcutText.scope(operation.applicability)
    }

    private func matches(_ operation: ShortcutOperation) -> Bool {
        if settingsHits.anchors.contains(operation.id.rawValue) { return true }
        let keys = controller.settingsKeys(for: operation.id)
        return matches(
            [
                ShortcutText.name(operation.id), ShortcutText.group(operation.group),
                operation.isGlobal ? String(localized: "Global") : String(localized: "In Surimono"),
                keys.isEmpty ? String(localized: "Unassigned") : "",
            ] + keys.map { controller.layout.display($0) })
    }

    private func matches(_ values: [String]) -> Bool {
        search.isEmpty || values.contains { $0.localizedStandardContains(search) }
    }
}

private struct ShortcutInfoRow: View {
    let name: String
    var scope: String? = nil
    let keys: [String]
    var spokenKeys: [String] = []
    var emptyLabel = String(localized: "Unassigned")

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).fixedSize(horizontal: false, vertical: true)
                if let scope {
                    Text(scope).font(.caption).foregroundStyle(PrintPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                if keys.isEmpty { Text(emptyLabel) }
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in Text(verbatim: key).monospaced() }
            }
            .fixedSize()
            .accessibilityLabel(
                spokenKeys.isEmpty
                    ? (keys.isEmpty ? emptyLabel : keys.joined(separator: ", ")) : spokenKeys.joined(separator: ", "))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EditableShortcutRow: View {
    let controller: ShortcutController
    let operation: ShortcutOperationID
    let status: ShortcutController.SettingsStatus
    var scope: String?
    @State private var error: String?
    @State private var pending: [ShortcutCombination]?
    @State private var reviewedSnapshot: ShortcutConfiguration?
    @State private var chosenKeys: [ShortcutCombination]?
    @State private var owners: [ShortcutOperationID] = []
    @State private var choosing = false
    @State private var restoring = false
    @FocusState private var chooserFocused: Bool

    private var title: String { ShortcutText.name(operation) }
    private var isGlobal: Bool { ShortcutOperation.operation(operation).isGlobal }
    private var keys: [ShortcutCombination] {
        controller.settingsKeys(for: operation)
    }
    private var hasEditableKeys: Bool {
        if controller.standardMenuKeys[operation] != nil {
            return controller.snapshot.overrides[operation]?.isEmpty == false
        }
        return !keys.isEmpty
    }
    private var previousCandidate: ShortcutCombination? {
        controller.snapshot.inactiveMigration.first(where: { $0.operation == operation })?.candidate
    }
    /// A line under the name: such a row keeps the room its chip needs.
    private var hasNote: Bool {
        if case .note = status { return true }
        return previousCandidate != nil || error != nil
    }
    /// How far the 28-point chip reaches past the row's content into the row's margins when nothing is under the name.
    private static let chipOverhang: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                    .help([title, scope].compactMap { $0 }.joined(separator: "\n"))
                    .accessibilityHint(scope ?? "")
                Spacer(minLength: 8)
                if case .inline(let text) = status {
                    Text(text).font(.caption).foregroundStyle(PrintPalette.ink2).fixedSize()
                }
                HStack(spacing: 6) { controls }
                    .fixedSize().layoutPriority(1)
                    // The key chip keeps its size and hit area but reaches into the row's own margins, so a row with
                    // nothing under its name is as high as a row in the other sections.
                    .padding(.vertical, hasNote ? 0 : -Self.chipOverhang)
                    .disabled(controller.loadError || controller.externalMenuKeys[operation] != nil)
            }
            if let candidate = previousCandidate {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "Previous shortcut: %@"), controller.layout.display(candidate))
                )
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if case .note(let text) = status {
                Text(text).font(.caption).foregroundStyle(PrintPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(PrintPalette.warn).fixedSize(
                    horizontal: false, vertical: true
                )
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    owners.isEmpty
                        ? (isGlobal
                            ? String(localized: "Assign Global Shortcut") : String(localized: "Assign Shortcut"))
                        : String(localized: "Which operation keeps this key?")
                )
                .font(.headline)
                Text(title).fixedSize(horizontal: false, vertical: true)
                Text((pending ?? []).map { controller.layout.display($0) }.joined(separator: " / ")).monospaced()
                if isGlobal {
                    Text("This shortcut works from other apps while Surimono is running. It never prints directly.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = ShortcutText.outputWarning(operation) {
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(owners, id: \.self) { owner in
                    Button(String.localizedStringWithFormat(String(localized: "Keep for %@"), ShortcutText.name(owner)))
                    {
                        pending = nil
                        chooserFocused = true
                    }
                }
                Button(
                    ShortcutOperation.operation(operation).safety == .printing
                        ? String(localized: "Assign Printing Shortcut")
                        : String.localizedStringWithFormat(String(localized: "Use for %@"), title)
                ) {
                    if let pending { apply(restoring ? nil : pending, takeConflicts: true) }
                    pending = nil
                    chooserFocused = true
                }
                Button("Cancel", role: .cancel) {
                    pending = nil
                    chooserFocused = true
                }
            }
            .padding(24).frame(width: 420)
        }
        .sheet(
            isPresented: $choosing,
            onDismiss: {
                chooserFocused = true
                if let chosenKeys {
                    self.chosenKeys = nil
                    propose(chosenKeys)
                }
            }
        ) {
            ShortcutKeyChooser(controller: controller, title: title) { value in
                do {
                    chosenKeys = try value.map { isGlobal ? $0 : try controller.logicalKey($0) }
                    choosing = false
                } catch { self.error = ShortcutController.message(error) }
            }
        }
        .onChange(of: error) { _, value in
            if let value, let application = NSApp {
                NSAccessibility.post(
                    element: application, notification: .announcementRequested,
                    userInfo: [.announcement: value, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
    }

    private static let unassigned = String(localized: "Unassigned")
    private static let more = String(localized: "More")

    @ViewBuilder private var controls: some View {
        let keys = self.keys
        let display = keys.map { controller.layout.display($0) }.joined(separator: " / ")
        let spokenKeys =
            keys.isEmpty ? Self.unassigned : keys.map { controller.layout.spoken($0) }.joined(separator: ", ")
        let scope = ShortcutText.scope(ShortcutOperation.operation(operation).applicability)
        ShortcutRecordingControl(
            title: keys.isEmpty ? Self.unassigned : display, displaysKeys: !keys.isEmpty,
            label: choice(String(localized: "Record Shortcut"), title), spokenValue: choice(scope, spokenKeys),
            hotKeys: controller.hotKeys, refuse: { error = ShortcutText.reason(.invalidKey) }
        ) { combo in
            do { propose(try combo.map { [try recorded($0)] } ?? []) } catch {
                self.error = ShortcutController.message(error)
            }
        }
        .fixedSize().frame(height: 28)
        .help(display)
        Menu {
            Button("Choose Keys…") {
                controller.refreshEnvironment()
                choosing = true
            }
            Button("Clear Shortcut") { apply([]) }.disabled(!hasEditableKeys && !hasInactive)
            Button("Restore Default") { propose(ShortcutDefaults.keys(for: operation), restoring: true) }
                .disabled(controller.snapshot.overrides[operation] == nil && !hasInactive)
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24)
        }
        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden)
        .fixedSize().focused($chooserFocused)
        .accessibilityLabel(Self.more + ": " + title)
        .help(Self.more + ": " + title)
    }

    private var hasInactive: Bool { controller.snapshot.inactiveMigration.contains { $0.operation == operation } }

    private func recorded(_ combo: KeyCombo) throws -> ShortcutCombination {
        let physical = try combo.recordedShortcutCombination()
        if isGlobal { return physical }
        return try controller.logicalKey(physical)
    }

    private func propose(_ keys: [ShortcutCombination], restoring: Bool = false) {
        self.restoring = restoring
        error = nil
        reviewedSnapshot = controller.snapshot
        if keys.isEmpty {
            apply(restoring ? nil : [])
            return
        }
        do {
            _ = try controller.proposal(operation, keys: restoring ? nil : keys)
            owners = []
            if isGlobal || ShortcutText.outputWarning(operation) != nil {
                pending = keys
            } else {
                apply(restoring ? nil : keys)
            }
        } catch ShortcutModelError.conflicts(let conflicts) {
            owners = Array(Set(conflicts.flatMap { $0.owners.map(\.operation) })).sorted { $0.rawValue < $1.rawValue }
            pending = keys
        } catch { self.error = ShortcutController.message(error) }
    }

    private func apply(_ keys: [ShortcutCombination]?, takeConflicts: Bool = false) {
        do {
            try controller.edit(
                operation, keys: keys, takeConflicts: takeConflicts,
                expectedSnapshot: takeConflicts ? reviewedSnapshot : nil)
            error = nil
        } catch { self.error = ShortcutController.message(error) }
    }
}

private struct ShortcutKeyChooser: View {
    let controller: ShortcutController
    let title: String
    let choose: ([ShortcutCombination]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code: UInt16 = 0
    @State private var modifiers: ShortcutModifiers = .command

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Keys…").font(.headline)
            Text(title).fixedSize(horizontal: false, vertical: true)
            Picker("Key", selection: $code) {
                ForEach((0..<128).map { UInt16($0) }.filter { ShortcutKey.macVirtualKey($0).isSupported }, id: \.self) {
                    code in
                    Text(controller.layout.display(.init(key: .macVirtualKey(code)))).tag(code)
                }
            }
            ForEach([ShortcutModifiers.control, .option, .shift, .command], id: \.rawValue) { flag in
                Toggle(
                    flag.spoken,
                    isOn: Binding(
                        get: { modifiers.contains(flag) },
                        set: { if $0 { modifiers.insert(flag) } else { modifiers.remove(flag) } }))
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Continue") { choose([.init(key: .macVirtualKey(code), modifiers: modifiers)]) }
            }
        }.padding(24).frame(width: 360)
    }
}

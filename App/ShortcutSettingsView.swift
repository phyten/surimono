import AppKit
import SurimonoCore
import SwiftUI

struct ShortcutSettingsView: View {
    let controller: ShortcutController
    @State private var search = ""
    @State private var restoringAll = false
    @State private var restoreSnapshot = ShortcutConfiguration()
    @State private var importDraft: ShortcutImportReview?
    @State private var fileError: String?
    @FocusState private var actionsFocused: Bool
    var files = ShortcutArchiveFiles()
    private let groups: [ShortcutGroup] = [.application, .documentAndPrinting, .reading, .styles, .lists]

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                archiveControls
                ForEach(groups, id: \.self) { group in
                    localSection(group)
                }
                fixedSection
                globalSection
            }
            .formStyle(.grouped)
            // Match the other Settings sections, including their title-bar inset correction.
            .contentMargins(.top, -28, for: .scrollContent)
            .clearsInitialFocus()
            .onAppear { controller.refresh() }
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
                searchField
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
            if let fileError {
                Text(fileError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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
            if let fileError { Text(fileError).foregroundStyle(.red) }
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("", text: $search, prompt: Text("Search Shortcuts"))
                .labelsHidden().accessibilityLabel(Text("Search Shortcuts"))
                .multilineTextAlignment(.leading)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Search"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
    }

    @ViewBuilder private func localSection(_ group: ShortcutGroup) -> some View {
        let rows = ShortcutOperation.catalog.filter { $0.group == group && matches($0) }
        if !rows.isEmpty {
            let sharedScope = ShortcutText.scope(Self.groupScope(group))
            Section {
                ForEach(rows, id: \.id) { operation in
                    let rowScope = scope(operation)
                    if controller.isConnected(operation.id)
                        && (operation.id != .appCheckUpdates || AppUpdater.shared.isAvailable)
                    {
                        EditableShortcutRow(
                            controller: controller, operation: operation.id,
                            scope: rowScope == sharedScope ? nil : rowScope)
                    } else {
                        ShortcutInfoRow(
                            name: ShortcutText.name(operation.id), scope: rowScope == sharedScope ? nil : rowScope,
                            keys: operation.defaults.map { controller.layout.display($0) },
                            spokenKeys: operation.defaults.map { controller.layout.spoken($0) })
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ShortcutText.group(group))
                    Text(sharedScope).font(.caption).foregroundStyle(.secondary)
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

    @ViewBuilder private var fixedSection: some View {
        let fixed = ShortcutFixedKey.catalog.filter { key in
            matches(
                [
                    ShortcutText.fixedName(key.behavior),
                    String(localized: "Fixed Keys"), String(localized: "In Surimono"),
                ] + key.combinations.map { controller.layout.display($0) })
        }
        if !fixed.isEmpty {
            // Native editing and window commands share explanations. Keep their catalog order.
            let reasons = fixed.map { ShortcutText.fixedReason($0.behavior) }
            let uniqueReasons = reasons.enumerated().filter { index, reason in
                !reasons.prefix(index).contains(reason)
            }.map(\.element)
            // One group per reason, which is its footer; the heading goes on the first.
            ForEach(Array(uniqueReasons.enumerated()), id: \.element) { index, reason in
                Section {
                    ForEach(fixed.filter { ShortcutText.fixedReason($0.behavior) == reason }, id: \.behavior) { key in
                        ShortcutInfoRow(
                            name: ShortcutText.fixedName(key.behavior),
                            keys: key.combinations.map { controller.layout.display($0) },
                            spokenKeys: key.combinations.map { controller.layout.spoken($0) },
                            emptyLabel: String(localized: "Managed by macOS"))
                    }
                } header: {
                    if index == 0 { Text("Fixed Keys") }
                } footer: {
                    SettingsFootnote(verbatim: reason)
                }
            }
        }
        if fixed.isEmpty && !ShortcutOperation.catalog.contains(where: { !$0.isGlobal && matches($0) }) {
            Text("No matching shortcuts").foregroundStyle(.secondary)
        }
    }

    private var globalSection: some View {
        Section {
            if let error = controller.migrationError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if controller.loadError {
                Text(ShortcutController.message(ShortcutController.EditError.savedDataUnavailable))
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            let global = ShortcutOperation.catalog.filter { $0.isGlobal && matches($0) }
            ForEach(global, id: \.id) { operation in
                EditableShortcutRow(controller: controller, operation: operation.id)
            }
            if global.isEmpty { Text("No matching shortcuts").foregroundStyle(.secondary) }
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
        let keys = controller.externalMenuKeys[operation.id].map { [$0] } ?? controller.snapshot.keys(for: operation.id)
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
                    Text(scope).font(.caption).foregroundStyle(.secondary)
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
        controller.externalMenuKeys[operation].map { [$0] } ?? controller.snapshot.keys(for: operation)
    }
    private var status: String { controller.status(for: operation) }
    private var isInlineStatus: Bool {
        status == String(localized: "Registered") || status == String(localized: "Managed in macOS")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                    .help([title, scope].compactMap { $0 }.joined(separator: "\n"))
                    .accessibilityHint(scope ?? "")
                Spacer(minLength: 8)
                if isInlineStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                HStack(spacing: 6) { controls }
                    .fixedSize().layoutPriority(1)
                    .disabled(
                        controller.loadError || controller.externalMenuKeys[operation] != nil
                            || controller.menuAmbiguities.contains(operation))
            }
            if let candidate = controller.snapshot.inactiveMigration.first(where: { $0.operation == operation })?
                .candidate
            {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "Previous shortcut: %@"), controller.layout.display(candidate))
                )
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if !status.isEmpty && status != String(localized: "Unassigned") && !isInlineStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder private var controls: some View {
        ShortcutRecorder(
            combo: nil,
            displayTitle: keys.isEmpty
                ? String(localized: "Unassigned")
                : keys.map { controller.layout.display($0) }.joined(separator: " / "),
            displaysKeys: !keys.isEmpty,
            label: String.localizedStringWithFormat(
                String(localized: "%1$@. Scope: %2$@. Shortcut: %3$@."), title,
                ShortcutText.scope(ShortcutOperation.operation(operation).applicability),
                keys.isEmpty
                    ? String(localized: "Unassigned")
                    : keys.map { controller.layout.spoken($0) }.joined(separator: ", ")),
            hotKeys: controller.hotKeys,
            refuse: { error = ShortcutText.reason(.invalidKey) }
        ) { combo in
            do { propose(try combo.map { [try recorded($0)] } ?? []) } catch {
                self.error = ShortcutController.message(error)
            }
        }
        .fixedSize().frame(height: 28)
        .help(keys.map { controller.layout.display($0) }.joined(separator: " / "))
        Menu {
            Button("Choose Keys…") {
                controller.refreshEnvironment()
                choosing = true
            }
            Button("Clear Shortcut") { apply([]) }.disabled(keys.isEmpty && !hasInactive)
            Button("Restore Default") { propose(ShortcutDefaults.keys(for: operation), restoring: true) }
                .disabled(controller.snapshot.overrides[operation] == nil && !hasInactive)
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24)
        }
        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden)
        .fixedSize().focused($chooserFocused)
        .accessibilityLabel(String(localized: "More") + ": " + title)
        .help(String(localized: "More") + ": " + title)
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

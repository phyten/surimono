import AppKit
import SurimonoCore
import SwiftUI

struct ShortcutSettingsView: View {
    let controller: ShortcutController
    @State private var search = ""
    private let groups: [ShortcutGroup] = [.application, .documentAndPrinting, .reading, .styles, .lists]

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                searchField
                Section("In Surimono") {
                    Text(
                        "Change or clear shortcuts here. Fixed keys and shortcuts managed in macOS cannot be changed here."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
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
            #if DEBUG
                .task {
                    search = DebugSnapshot.shortcutSearch ?? ""
                    if DebugSnapshot.shortcutShowGlobal {
                        // Let the form lay out the filtered rows before finding the Global section.
                        await Task.yield()
                        proxy.scrollTo("shortcut-global", anchor: .top)
                    }
                }
            #endif
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search Shortcuts", text: $search)
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
                    ShortcutText.fixedName(key.behavior), ShortcutText.fixedReason(key.behavior),
                    String(localized: "Fixed Keys"), String(localized: "In Surimono"),
                ] + key.combinations.map { controller.layout.display($0) })
        }
        if !fixed.isEmpty {
            Section("Fixed Keys") {
                // Native editing and window commands share explanations. Keep their catalog order.
                let reasons = fixed.map { ShortcutText.fixedReason($0.behavior) }
                let uniqueReasons = reasons.enumerated().filter { index, reason in
                    !reasons.prefix(index).contains(reason)
                }.map(\.element)
                ForEach(uniqueReasons, id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                    ForEach(fixed.filter { ShortcutText.fixedReason($0.behavior) == reason }, id: \.behavior) { key in
                        ShortcutInfoRow(
                            name: ShortcutText.fixedName(key.behavior),
                            keys: key.combinations.map { controller.layout.display($0) },
                            spokenKeys: key.combinations.map { controller.layout.spoken($0) },
                            emptyLabel: String(localized: "Managed by macOS"))
                    }
                }
            }
        }
        if fixed.isEmpty && !ShortcutOperation.catalog.contains(where: { !$0.isGlobal && matches($0) }) {
            Text("No matching shortcuts").foregroundStyle(.secondary)
        }
    }

    private var globalSection: some View {
        Section {
            Text("These work while Surimono is running, even when another app is in front.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Press a key combination. Escape cancels; Tab moves focus; Delete clears.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Label("Global", systemImage: "globe")
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
                ShortcutText.name(operation.id), ShortcutText.group(operation.group), scope(operation),
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
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in Text(verbatim: key) }
            }
            .monospaced().fixedSize()
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
    private var hasInlineStatus: Bool {
        status == String(localized: "Registered") || status == String(localized: "Managed in macOS")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                    .help([title, scope].compactMap { $0 }.joined(separator: "\n"))
                    .accessibilityHint(scope ?? "")
                Spacer(minLength: 8)
                if hasInlineStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                HStack(spacing: 6) { controls }
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
            if !status.isEmpty && !hasInlineStatus && status != String(localized: "Unassigned") {
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

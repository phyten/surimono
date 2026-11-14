import AppKit
import SurimonoCore
import SwiftUI

struct SettingSetMenu<Label: View>: View {
    let preferences: AppPreferences
    let library: UserLibrary
    // Resolve the active document at the action, including for AppKit-owned image bundle windows.
    var model: () -> DocumentViewModel?
    @ViewBuilder var label: () -> Label
    @Environment(\.openSettings) private var openSettings
    private var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    private func item(_ set: PrintSettingSet) -> some View {
        Toggle(
            isOn: Binding(
                get: { model()?.matchesPrintSettingSet(set) ?? false },
                set: { _ in model()?.applyPrintSettingSet(set) })
        ) {
            Text(verbatim: set.name)
            Text(verbatim: SettingSetSummary(library: library).subtitle(set))
        }
    }

    var body: some View {
        Menu {
            ForEach(PrintSettingSet.builtIns(language: language), content: item)
            if !preferences.printSettingSets.isEmpty { Divider() }
            ForEach(preferences.printSettingSets, content: item)
            Divider()
            Button("Save Current Settings…") {
                guard let model = model() else { return }
                SettingSetDialogs.save(model)
            }
            ForEach(preferences.printSettingSets.filter { model()?.matchesPrintSettingSet($0) == true }) { set in
                Button("Replace “\(set.name)” with Current Settings") {
                    model()?.savePrintSettingSet(named: set.name, parts: set.parts)
                }
            }
            Divider()
            Button("Manage Setting Sets…") {
                preferences.settingsSection = .settingSets
                openSettings()
            }
        } label: {
            label()
        }
    }
}

extension SettingSetMenu where Label == Text {
    init(preferences: AppPreferences, library: UserLibrary, model: @escaping () -> DocumentViewModel?) {
        self.init(preferences: preferences, library: library, model: model) { Text("Setting Sets") }
    }
}

enum SettingSetDialogs {
    static func save(_ model: DocumentViewModel) {
        // Let menus and popovers finish handling the click before entering AppKit's modal loop.
        Task { @MainActor in
            await Task.yield()
            let selection = SettingSetSaveAccessory(model: model)
            let alert = NSAlert()
            // The menu item's ellipsis promises this dialog; the dialog itself is titled without one.
            alert.messageText = String(localized: "Save Current Settings")
            alert.accessoryView = selection.view
            let save = alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            selection.saveButton = save
            selection.updateValidation()
            alert.window.initialFirstResponder = selection.nameField
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = selection.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !selection.parts.isEmpty else { return }
            if model.preferences.printSettingSets.contains(where: { $0.name == name }), !confirmReplacement(name) {
                return
            }
            // The parts ticked here win over those of a set being replaced: the reader has just chosen them.
            model.savePrintSettingSet(named: name, parts: selection.parts)
        }
    }

    static func rename(_ set: PrintSettingSet, preferences: AppPreferences) {
        Task { @MainActor in
            await Task.yield()
            guard
                let name = promptName(
                    title: String(localized: "Rename Setting Set"), initial: set.name,
                    validate: { name in
                        preferences.printSettingSets.contains(where: { $0.id != set.id && $0.name == name })
                            ? String(localized: "A setting set with this name already exists.") : nil
                    })
            else { return }
            preferences.renamePrintSettingSet(set.id, to: name)
        }
    }

    private static func promptName(
        title: String, initial: String, validate: (String) -> String? = { _ in nil }
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.setAccessibilityLabel(String(localized: "Setting Set Name"))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                alert.informativeText = String(localized: "Enter a name.")
            } else if let message = validate(name) {
                alert.informativeText = message
            } else {
                return name
            }
        }
        return nil
    }

    private static func confirmReplacement(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Replace “%@”?"), name)
        alert.informativeText = String(localized: "The saved setting set will be replaced with the current settings.")
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Deleting a setting set and taking the deletion back, from the notice or the window's history.
enum SettingSetRemoval {
    private static var actionName: String { String(localized: "Delete Setting Set") }

    static func delete(_ id: UUID, from preferences: AppPreferences, history: UndoManager?) {
        guard let removal = preferences.removePrintSettingSet(id) else { return }
        history?.registerUndo(withTarget: preferences) { [weak history] preferences in
            guard preferences.restorePrintSettingSet(removal) else { return }
            history?.registerUndo(withTarget: preferences) { [weak history] in
                delete(id, from: $0, history: history)
            }
            history?.setActionName(actionName)
        }
        history?.setActionName(actionName)
    }

    /// The notice's Undo. It goes through the window's history while the deletion is its latest step, so that Redo
    /// follows; otherwise it restores directly and the step left in the history does nothing.
    static func undo(_ removal: RemovedPrintSettingSet, in preferences: AppPreferences, history: UndoManager?) {
        if let history, history.canUndo, history.undoActionName == actionName {
            history.undo()
        } else {
            preferences.restorePrintSettingSet(removal)
        }
    }
}

/// Says which setting set was deleted and offers to put it back, in the look of the document windows' toasts.
struct SettingSetRemovalNotice: View {
    let preferences: AppPreferences
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack {
            if let removal = preferences.removedPrintSettingSet {
                HStack(spacing: 12) {
                    Image(systemName: "trash").font(.system(size: 16))
                    Text(verbatim: String(format: String(localized: "Deleted “%@”"), removal.set.name))
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Undo") { SettingSetRemoval.undo(removal, in: preferences, history: undoManager) }
                        .buttonStyle(ToastActionButtonStyle())
                    PanelIconButton("xmark", label: "Dismiss") { preferences.dismissRemovedPrintSettingSet() }
                }
                .foregroundStyle(PrintPalette.toastInk)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(PrintPalette.toast))
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(removal.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: preferences.removedPrintSettingSet)
    }
}

struct SettingSetsSettings: View {
    let preferences: AppPreferences
    let library: UserLibrary
    @Environment(\.undoManager) private var undoManager
    private var summary: SettingSetSummary { SettingSetSummary(library: library) }

    private func description(_ set: PrintSettingSet) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: set.name).lineLimit(2)
            Text(verbatim: summary.oneLine(set)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    var body: some View {
        Text(
            "Setting sets remember paper and layout, margins, headers and footers, finishing, notes, style and text size, and HTML presets, so you can apply them to any document at once. They do not include view layout or zoom."
        )
        .foregroundStyle(.secondary)
        Section("Built-in Sets") {
            ForEach(PrintSettingSet.builtIns(language: summary.language)) { set in
                description(set)
            }
        }
        Section("Your Sets") {
            if preferences.printSettingSets.isEmpty {
                Text(
                    "You have no setting sets of your own yet. Open a document and choose Document > Setting Sets > Save Current Settings…, or use Setting Sets on the print screen."
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(preferences.printSettingSets) { set in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        description(set)
                        Spacer()
                        Button("Rename…") { SettingSetDialogs.rename(set, preferences: preferences) }
                        Button("Delete", role: .destructive) {
                            SettingSetRemoval.delete(set.id, from: preferences, history: undoManager)
                        }
                    }
                    .contentShape(Rectangle())
                    .draggable(set.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard items.count == 1, let id = UUID(uuidString: items[0]),
                            let from = preferences.printSettingSets.firstIndex(where: { $0.id == id }),
                            let to = preferences.printSettingSets.firstIndex(where: { $0.id == set.id }), from != to
                        else { return false }
                        preferences.movePrintSettingSets(from: IndexSet(integer: from), to: from < to ? to + 1 : to)
                        return true
                    }
                }
            }
        }
    }
}

/// AppKit controls work in the modal alert even when the originating window is not owned by SwiftUI.
private final class SettingSetSaveAccessory: NSObject, NSTextFieldDelegate {
    let view = NSStackView()
    let nameField: NSTextField
    weak var saveButton: NSButton?
    private var choices: [(PrintSettingSet.Part, NSButton)] = []
    private static let width: CGFloat = 360
    /// Where a checkbox's title starts, past the box.
    private static let checkboxIndent: CGFloat = 20

    var parts: Set<PrintSettingSet.Part> {
        Set(choices.filter { $0.1.state == .on }.map { $0.0 })
    }

    init(model: DocumentViewModel) {
        nameField = NSTextField(string: model.preferences.nextPrintSettingSetName)
        super.init()
        nameField.delegate = self
        nameField.setAccessibilityLabel(String(localized: "Setting Set Name"))
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10
        view.addArrangedSubview(nameField)
        nameField.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        // The name stands apart from the parts it names.
        view.setCustomSpacing(16, after: nameField)
        let set = model.currentPrintSettingSet
        let summary = SettingSetSummary(library: model.library)
        for part in PrintSettingSet.Part.allCases where set.parts.contains(part) {
            let checkbox = NSButton(
                checkboxWithTitle: summary.title(part), target: self, action: #selector(updateValidation))
            checkbox.state = .on
            choices.append((part, checkbox))
            // Each part is its checkbox with its value under the title, not under the box.
            let group = NSStackView(views: [checkbox])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 2
            if let line = summary.line(part, in: set) {
                let label = NSTextField(wrappingLabelWithString: line)
                label.textColor = .secondaryLabelColor
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                label.widthAnchor.constraint(equalToConstant: Self.width - Self.checkboxIndent).isActive = true
                let indented = NSStackView(views: [label])
                indented.edgeInsets = NSEdgeInsets(top: 0, left: Self.checkboxIndent, bottom: 0, right: 0)
                group.addArrangedSubview(indented)
            }
            view.addArrangedSubview(group)
        }
        view.frame.size = view.fittingSize
    }

    func controlTextDidChange(_ notification: Notification) { updateValidation() }

    @objc func updateValidation() {
        saveButton?.isEnabled =
            !parts.isEmpty && !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

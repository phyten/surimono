import AppKit
import SurimonoCore
import SwiftUI

struct SettingSetMenu<Label: View>: View {
    let preferences: AppPreferences
    // Resolve the active document at the action, including for AppKit-owned image bundle windows.
    var model: () -> DocumentViewModel?
    @ViewBuilder var label: () -> Label
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            ForEach(preferences.printSettingSets) { set in
                Toggle(
                    isOn: Binding(
                        get: { model()?.matchesPrintSettingSet(set) ?? false },
                        set: { _ in model()?.applyPrintSettingSet(set) })
                ) {
                    Text(verbatim: set.name)
                }
            }
            Divider()
            Button("Save Current Settings…") {
                guard let model = model() else { return }
                SettingSetDialogs.save(model)
            }
            ForEach(preferences.printSettingSets.filter { model()?.matchesPrintSettingSet($0) == true }) { set in
                Button("Replace “\(set.name)” with Current Settings") {
                    model()?.savePrintSettingSet(named: set.name)
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
    init(preferences: AppPreferences, model: @escaping () -> DocumentViewModel?) {
        self.init(preferences: preferences, model: model) { Text("Setting Sets") }
    }
}

enum SettingSetDialogs {
    static func save(_ model: DocumentViewModel) {
        // Let menus and popovers finish handling the click before entering AppKit's modal loop.
        Task { @MainActor in
            await Task.yield()
            guard
                let name = promptName(
                    title: String(localized: "Save Current Settings…"),
                    initial: model.preferences.nextPrintSettingSetName)
            else { return }
            if model.preferences.printSettingSets.contains(where: { $0.name == name }), !confirmReplacement(name) {
                return
            }
            model.savePrintSettingSet(named: name)
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

struct SettingSetsSettings: View {
    let preferences: AppPreferences

    var body: some View {
        if preferences.printSettingSets.isEmpty {
            Text("No setting sets yet. Save the current settings from a document’s Setting Sets menu.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(preferences.printSettingSets) { set in
                HStack {
                    Text(verbatim: set.name).lineLimit(2)
                    Spacer()
                    Button("Rename…") { SettingSetDialogs.rename(set, preferences: preferences) }
                    Button("Delete", role: .destructive) { preferences.removePrintSettingSet(set.id) }
                }
            }
        }
    }
}

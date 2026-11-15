import AppKit
import SurimonoCore
import SwiftUI

/// Both entry points use the running bundle's language, even after a change awaiting relaunch.
struct LanguagePicker: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Picker(
            "Language",
            selection: Binding(
                get: { preferences.languageOverride ?? "" },
                set: { value in
                    let language = value.isEmpty ? nil : value
                    let previous = preferences.languageOverride
                    guard language != previous else { return }
                    preferences.languageOverride = language
                    LanguageRelaunch.offer(preferences: preferences, previousLanguage: previous)
                })
        ) {
            Text("System (default)").tag("")
            ForEach(UILanguage.supported, id: \.self) { language in
                Text(verbatim: UILanguage.label(for: language, in: Bundle.main.preferredLocalizations.first ?? "en"))
                    .tag(language)
            }
        }
    }
}

/// The relaunch itself, apart from its alerts: an unsaved toolbar arrangement is settled before anything launches,
/// because the new instance starts before this one quits and quitting would ask too late to stop it. Cancel leaves
/// the language as it was and launches nothing.
@MainActor
enum LanguageRelaunchFlow {
    static func relaunch(
        editor: BandArrangementEditorSession?, preferences: AppPreferences, previousLanguage: String?,
        askAboutDraft: (BandArrangementEditorSession) -> BandArrangementEditorSession.RelaunchAnswer,
        launch: () async throws -> Void,
        terminate: () -> Void
    ) async throws -> Bool {
        if let editor, editor.preferences === preferences,
            !editor.resolveBeforeRelaunch(ask: { askAboutDraft(editor) })
        {
            preferences.languageOverride = previousLanguage
            return false
        }
        try await launch()
        terminate()
        return true
    }

    /// Save, Discard or Cancel for the draft, in the words of the editor's own question.
    static func askAboutDraft(_ editor: BandArrangementEditorSession) -> BandArrangementEditorSession.RelaunchAnswer {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save changes to the toolbar arrangement?")
        if editor.isStandardActive {
            alert.informativeText = String(
                localized: "Standard does not change. Save keeps your changes as a new arrangement.")
        } else if editor.hasConflict {
            alert.informativeText = String(
                localized: "This arrangement was changed elsewhere. Save keeps your changes as a new arrangement.")
        } else {
            alert.informativeText = String(
                format: String(
                    localized: "Save replaces “%@” with your changes. Discard keeps it as it was saved."),
                editor.activeName)
        }
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}

@MainActor
private enum LanguageRelaunch {
    static func offer(preferences: AppPreferences, previousLanguage: String?) {
        // Let the picker/menu close before presenting a modal alert.
        Task { @MainActor in
            await Task.yield()
            let updater = AppUpdater.shared
            guard updater.languageChangeNotice == .offerRelaunch else {
                showNextLaunchNotice()
                return
            }
            let alert = NSAlert()
            alert.messageText = updater.languageChangeNotice.message
            alert.informativeText = String(
                localized:
                    "The new language takes effect after relaunch. Open windows will close; you may need to reopen your documents. Choose Later to keep working."
            )
            alert.addButton(withTitle: String(localized: "Relaunch Now"))
            alert.addButton(withTitle: String(localized: "Later"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                let relaunched = try await updater.relaunchForLanguageChange {
                    _ = try await LanguageRelaunchFlow.relaunch(
                        editor: BandArrangementEditorSession.app, preferences: preferences,
                        previousLanguage: previousLanguage,
                        askAboutDraft: LanguageRelaunchFlow.askAboutDraft,
                        launch: {
                            let configuration = NSWorkspace.OpenConfiguration()
                            configuration.createsNewApplicationInstance = true
                            _ = try await NSWorkspace.shared.openApplication(
                                at: Bundle.main.bundleURL, configuration: configuration)
                        },
                        terminate: { NSApp.terminate(nil) })
                }
                // An update can become pending while the confirmation alert runs its modal loop.
                if !relaunched { showNextLaunchNotice() }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private static func showNextLaunchNotice() {
        let alert = NSAlert()
        alert.messageText = UpdateRelaunch.Notice.nextLaunch.message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

}

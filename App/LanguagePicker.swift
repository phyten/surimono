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
                    guard language != preferences.languageOverride else { return }
                    preferences.languageOverride = language
                    LanguageRelaunch.offer()
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

@MainActor
private enum LanguageRelaunch {
    static func offer() {
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
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    _ = try await NSWorkspace.shared.openApplication(
                        at: Bundle.main.bundleURL, configuration: configuration)
                    NSApp.terminate(nil)
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

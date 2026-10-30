import Sparkle
import SwiftUI

/// Looks for a newer release through Sparkle and installs it.
///
/// Only a release build names a feed, so a development build (Surimono Dev) never starts Sparkle: it cannot replace
/// itself with the release or change the release's update settings.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// Mirrors Sparkle's setting, which also changes when the user answers Sparkle's own question on the second launch.
    private(set) var checksAutomatically = false

    var isAvailable: Bool { controller != nil }

    private init() {
        guard Self.feedURL(in: Bundle.main.infoDictionary) != nil else {
            controller = nil
            return
        }
        // SUEnableAutomaticChecks stays out of Info.plist: Sparkle then asks on the second launch whether to check
        // automatically, and until the user agrees it goes online only when asked from the menu.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) {
            [weak self] _, change in
            let value = change.newValue ?? false
            // Sparkle changes the setting on the main thread only.
            MainActor.assumeIsolated { self?.checksAutomatically = value }
        }
    }

    func setChecksAutomatically(_ value: Bool) {
        controller?.updater.automaticallyChecksForUpdates = value
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// The appcast an Info.plist names. A development build leaves it empty, which means no updates.
    nonisolated static func feedURL(in info: [String: Any]?) -> URL? {
        guard let string = info?["SUFeedURL"] as? String, let url = URL(string: string), url.scheme != nil,
            url.host != nil
        else { return nil }
        return url
    }
}

struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if AppUpdater.shared.isAvailable {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
            }
        }
    }
}

import Sparkle
import SwiftUI

/// Looks for a newer release through Sparkle and installs it.
///
/// Only a release build names a feed, so a development build (Surimono Dev) never starts Sparkle: it cannot replace
/// itself with the release or change the release's update settings.
@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let relaunch = UpdateRelaunch()
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// Mirrors Sparkle's setting, which also changes when the user answers Sparkle's own question on the second launch.
    private(set) var checksAutomatically = false

    var isAvailable: Bool { controller != nil }

    private override init() {
        super.init()
        guard Self.feedURL(in: Bundle.main.infoDictionary) != nil else {
            controller = nil
            return
        }
        // SUEnableAutomaticChecks stays out of Info.plist: Sparkle then asks on the second launch whether to check
        // automatically, and until the user agrees it goes online only when asked from the menu.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.startUpdater()
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

    var languageChangeNotice: UpdateRelaunch.Notice { relaunch.notice }

    func relaunchForLanguageChange(normalRelaunch: () async throws -> Void) async rethrows -> Bool {
        try await relaunch.perform(normalRelaunch: normalRelaunch)
    }

    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // Observe only: Sparkle retains control of installation and subsequent update checks.
        return relaunch.updateWillInstallOnQuit()
    }

    /// The appcast an Info.plist names. A development build leaves it empty, which means no updates.
    nonisolated static func feedURL(in info: [String: Any]?) -> URL? {
        guard let string = info?["SUFeedURL"] as? String, let url = URL(string: string), url.scheme != nil,
            url.host != nil
        else { return nil }
        return url
    }
}

/// Keeps relaunch decisions testable without launching an application or starting Sparkle.
@MainActor
final class UpdateRelaunch {
    enum Notice: Equatable {
        case offerRelaunch
        case nextLaunch

        var message: String {
            switch self {
            case .offerRelaunch: String(localized: "Relaunch to Change Language?")
            case .nextLaunch: String(localized: "The language changes the next time you open Surimono.")
            }
        }
    }

    /// Once Sparkle has an update waiting to install on quit, it stays waiting for the rest of this process: the
    /// update driver finishes its cycle while the installer keeps the update, so no later callback means it is gone.
    private(set) var hasPendingInstallation = false
    var notice: Notice { hasPendingInstallation ? .nextLaunch : .offerRelaunch }

    func updateWillInstallOnQuit() -> Bool {
        hasPendingInstallation = true
        return false
    }

    func perform(normalRelaunch: () async throws -> Void) async rethrows -> Bool {
        guard !hasPendingInstallation else { return false }
        try await normalRelaunch()
        return true
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

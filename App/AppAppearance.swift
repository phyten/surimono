import AppKit
import SwiftUI

/// The light or dark look of the app's windows, chosen in Settings > General. The paper is not part of it: pages stay
/// white in every appearance.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case light, dark, system

    /// Light unless the reader chose otherwise, whatever the Mac is set to.
    static let `default`: AppAppearance = .light

    var id: Self { self }

    /// The appearance every window takes; nil leaves them to follow the system.
    var appearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "Match System"
        }
    }
}

/// Keeps every window of the app in the chosen appearance, from launch on and whenever the choice changes.
///
/// The app's appearance reaches every window it owns at once, Sparkle's among them, and the windows opened later; so
/// it is set on the application rather than window by window. Set before the first window shows, no window flashes in
/// the system's appearance first.
@MainActor
final class AppearanceKeeper {
    private let preferences: AppPreferences
    /// A development screenshot's appearance, for this run only; it wins over the setting and is never saved.
    private let override: AppAppearance?
    private let setAppearance: (NSAppearance?) -> Void

    init(
        preferences: AppPreferences, override: AppAppearance? = AppearanceKeeper.launchOverride,
        setAppearance: @escaping (NSAppearance?) -> Void = {
            DisplayAccessibility.shared.applyAppearance($0, to: NSApp)
        }
    ) {
        self.preferences = preferences
        self.override = override
        self.setAppearance = setAppearance
    }

    /// The appearance in effect: the screenshot's, else the reader's choice.
    var current: AppAppearance { override ?? preferences.appearance }

    func start() {
        setAppearance(current.appearance)
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = preferences.appearance
            _ = DisplayAccessibility.shared.options.increasedContrast
        } onChange: { [weak self] in
            // Called before the new value is stored; apply it once it is.
            Task { @MainActor [weak self] in
                guard let self else { return }
                setAppearance(current.appearance)
                observe()
            }
        }
    }

    static var launchOverride: AppAppearance? {
        #if DEBUG
            DebugSnapshot.argument("SurimonoAppearance").flatMap(AppAppearance.init(rawValue:))
        #else
            nil
        #endif
    }
}

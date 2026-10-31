import Observation
import SurimonoCore
import SwiftUI

/// App-wide defaults. Settings a user changes in a document window are remembered per document instead.
@Observable
final class AppPreferences {
    private let defaults: UserDefaults
    var wheelSensitivity: WheelPageTurner.Sensitivity {
        didSet { defaults.set(wheelSensitivity.rawValue, forKey: "wheelSensitivity") }
    }
    var layoutID: String { didSet { defaults.set(layoutID, forKey: "layout") } }
    var themeID: String { didSet { defaults.set(themeID, forKey: "theme") } }
    var presetID: String { didSet { defaults.set(presetID, forKey: "preset") } }
    var margin: Double { didSet { defaults.set(margin, forKey: "margin") } }
    var pageNumbers: Bool { didSet { defaults.set(pageNumbers, forKey: "pageNumbers") } }
    var viewPageNumbers: Bool { didSet { defaults.set(viewPageNumbers, forKey: "viewPageNumbers") } }
    var rotateBack: Bool { didSet { defaults.set(rotateBack, forKey: "rotateBack") } }
    var allowsJavaScript: Bool { didSet { defaults.set(allowsJavaScript, forKey: "allowsJavaScript") } }
    /// The printer the tray's Print sends to; nil means the system's default printer.
    var printerName: String? { didSet { defaults.set(printerName, forKey: "printer") } }
    /// Print themes the user chose in any window, most recent first.
    private(set) var recentThemeIDs: [String] { didSet { defaults.set(recentThemeIDs, forKey: "recentThemes") } }
    /// Print themes the user marked as favorites, in the order they were added.
    private(set) var favoriteThemeIDs: [String] {
        didSet { defaults.set(favoriteThemeIDs, forKey: "favoriteThemes") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wheelSensitivity =
            WheelPageTurner.Sensitivity(rawValue: defaults.string(forKey: "wheelSensitivity") ?? "") ?? .normal
        layoutID = defaults.string(forKey: "layout") ?? "a4Single"
        themeID = defaults.string(forKey: "theme") ?? "standard"
        presetID = defaults.string(forKey: "preset") ?? "none"
        margin = defaults.object(forKey: "margin") as? Double ?? 15
        pageNumbers = defaults.bool(forKey: "pageNumbers")
        viewPageNumbers = defaults.bool(forKey: "viewPageNumbers")
        rotateBack = defaults.bool(forKey: "rotateBack")
        allowsJavaScript = defaults.object(forKey: "allowsJavaScript") as? Bool ?? true
        printerName = defaults.string(forKey: "printer")
        recentThemeIDs = defaults.stringArray(forKey: "recentThemes") ?? []
        favoriteThemeIDs = defaults.stringArray(forKey: "favoriteThemes") ?? []
    }

    func recordThemeChoice(_ id: String) {
        recentThemeIDs = PrintThemeMenu.recording(id, in: recentThemeIDs)
    }

    func toggleFavoriteTheme(_ id: String) {
        favoriteThemeIDs = PrintThemeMenu.toggling(id, in: favoriteThemeIDs)
    }

    var printOptions: PrintOptions {
        PrintOptions(marginsInMillimeters: margin, showsPageNumbers: pageNumbers, rotatesBackSides: rotateBack)
    }
}

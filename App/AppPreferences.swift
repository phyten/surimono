import Observation
import SurimonoCore
import SwiftUI

/// App-wide defaults. Settings a user changes in a document window are remembered per document instead.
@Observable
final class AppPreferences {
    private let defaults: UserDefaults
    var layoutID: String { didSet { defaults.set(layoutID, forKey: "layout") } }
    var themeID: String { didSet { defaults.set(themeID, forKey: "theme") } }
    var presetID: String { didSet { defaults.set(presetID, forKey: "preset") } }
    var margin: Double { didSet { defaults.set(margin, forKey: "margin") } }
    var pageNumbers: Bool { didSet { defaults.set(pageNumbers, forKey: "pageNumbers") } }
    var rotateBack: Bool { didSet { defaults.set(rotateBack, forKey: "rotateBack") } }
    var allowsJavaScript: Bool { didSet { defaults.set(allowsJavaScript, forKey: "allowsJavaScript") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layoutID = defaults.string(forKey: "layout") ?? "a4Single"
        themeID = defaults.string(forKey: "theme") ?? "standard"
        presetID = defaults.string(forKey: "preset") ?? "none"
        margin = defaults.object(forKey: "margin") as? Double ?? 15
        pageNumbers = defaults.bool(forKey: "pageNumbers")
        rotateBack = defaults.bool(forKey: "rotateBack")
        allowsJavaScript = defaults.object(forKey: "allowsJavaScript") as? Bool ?? true
    }

    var printOptions: PrintOptions {
        PrintOptions(marginsInMillimeters: margin, showsPageNumbers: pageNumbers, rotatesBackSides: rotateBack)
    }
}

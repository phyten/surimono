import Observation
import SurimonoCore
import SwiftUI

/// App-wide defaults. Settings a user changes in a document window are remembered per document instead.
@Observable
final class AppPreferences {
    private let defaults: UserDefaults
    private let languageDomainName: String?
    /// Only the application's persistent domain determines the override, never the global AppleLanguages value.
    var languageOverride: String? {
        didSet {
            guard let languageDomainName else { return }
            var domain = defaults.persistentDomain(forName: languageDomainName) ?? [:]
            domain["AppleLanguages"] = languageOverride.map { [$0] }
            defaults.setPersistentDomain(domain, forName: languageDomainName)
        }
    }
    var wheelSensitivity: WheelPageTurner.Sensitivity {
        didSet { defaults.set(wheelSensitivity.rawValue, forKey: "wheelSensitivity") }
    }
    var defaultViewLayout: ViewOptions.Layout? {
        didSet { defaults.set(defaultViewLayout?.rawValue, forKey: "defaultViewLayout") }
    }
    var defaultPageTurn: ViewOptions.Transition? {
        didSet { defaults.set(defaultPageTurn?.rawValue, forKey: "defaultPageTurn") }
    }
    var defaultJoinsPages: Bool { didSet { defaults.set(defaultJoinsPages, forKey: "defaultJoinsPages") } }
    var defaultReadingDirection: ViewOptions.Direction? {
        didSet { defaults.set(defaultReadingDirection?.rawValue, forKey: "defaultReadingDirection") }
    }
    var defaultScrollAxis: ViewOptions.ScrollAxis? {
        didSet { defaults.set(defaultScrollAxis?.rawValue, forKey: "defaultScrollAxis") }
    }
    var defaultShowsCoverAlone: Bool? {
        didSet { defaults.set(defaultShowsCoverAlone, forKey: "defaultShowsCoverAlone") }
    }
    var loneCoverWidth: LoneCoverWidth {
        didSet { defaults.set(loneCoverWidth.rawValue, forKey: "loneCoverWidth") }
    }
    var defaultAlwaysOnTop: Bool {
        didSet { defaults.set(defaultAlwaysOnTop, forKey: "defaultAlwaysOnTop") }
    }
    var defaultMenuPinned: Bool {
        didSet { defaults.set(defaultMenuPinned, forKey: "defaultMenuPinned") }
    }
    var defaultTextScale: Double {
        didSet { defaults.set(defaultTextScale, forKey: "defaultTextScale") }
    }
    var defaultPaperOrientation: PaperOrientation {
        didSet { defaults.set(defaultPaperOrientation.rawValue, forKey: "defaultPaperOrientation") }
    }
    /// Kept for this app run, including when the Settings window is closed and reopened.
    var settingsSection: SettingsSection = .general

    var viewDefaults: ViewDefaultPreferences {
        ViewDefaultPreferences(
            layout: defaultViewLayout, transition: defaultPageTurn, joinsPages: defaultJoinsPages,
            direction: defaultReadingDirection, scrollAxis: defaultScrollAxis, showsCoverAlone: defaultShowsCoverAlone)
    }

    var layoutID: String { didSet { defaults.set(layoutID, forKey: "layout") } }
    var themeID: String { didSet { defaults.set(themeID, forKey: "theme") } }
    var presetID: String { didSet { defaults.set(presetID, forKey: "preset") } }
    var margin: Double {
        didSet {
            defaults.set(margin, forKey: "margin")
            if finishDefaults?.options.margins.uniformValue != margin {
                finishDefaults?.options.margins = .uniform(margin)
            }
        }
    }
    var pageNumbers: Bool {
        didSet {
            defaults.set(pageNumbers, forKey: "pageNumbers")
            if finishDefaults?.options.showsPageNumbers != pageNumbers {
                finishDefaults?.options.showsPageNumbers = pageNumbers
            }
        }
    }
    /// The last series of paper chosen on a tray.
    var paperSeries: PaperSeries? { didSet { defaults.set(paperSeries?.rawValue, forKey: "paperSeries") } }
    /// What the reader made the default from the tray; the margin and page number above stay for Settings.
    private var finishDefaults: FinishDefaults? {
        didSet {
            if let data = try? JSONEncoder().encode(finishDefaults) {
                defaults.set(data, forKey: "printFinishDefaults")
            }
        }
    }
    var viewPageNumbers: Bool { didSet { defaults.set(viewPageNumbers, forKey: "viewPageNumbers") } }
    var rotateBack: Bool { didSet { defaults.set(rotateBack, forKey: "rotateBack") } }
    var allowsJavaScript: Bool { didSet { defaults.set(allowsJavaScript, forKey: "allowsJavaScript") } }
    /// The printer the tray's Print sends to; nil means the system's default printer.
    var printerName: String? { didSet { defaults.set(printerName, forKey: "printer") } }
    /// Initial values for printers or bindings that have not been configured.
    var printPageOrder: PrintPageOrder { didSet { defaults.set(printPageOrder.rawValue, forKey: "printPageOrder") } }
    private(set) var printerProfiles: [String: PrinterProfile] {
        didSet {
            if let data = try? JSONEncoder().encode(printerProfiles) {
                defaults.set(data, forKey: "printerProfiles")
            }
        }
    }

    func printerProfile(for name: String?) -> PrinterProfile {
        name.flatMap { printerProfiles[$0] } ?? PrinterProfile()
    }

    func setPrinterRotation(_ rotates: Bool, for name: String, duplex: DuplexMode) {
        var profile = printerProfile(for: name)
        profile.setRotation(rotates, for: duplex)
        printerProfiles[name] = profile
    }

    func setPrinterPageOrder(_ order: PrintPageOrder, for name: String) {
        var profile = printerProfile(for: name)
        profile.pageOrder = order
        printerProfiles[name] = profile
    }

    /// Print themes the user chose in any window, most recent first.
    private(set) var recentThemeIDs: [String] { didSet { defaults.set(recentThemeIDs, forKey: "recentThemes") } }
    /// Print themes the user marked as favorites, in the order they were added.
    private(set) var favoriteThemeIDs: [String] {
        didSet { defaults.set(favoriteThemeIDs, forKey: "favoriteThemes") }
    }
    private(set) var printSettingSets: [PrintSettingSet] {
        didSet {
            if let data = try? JSONEncoder().encode(printSettingSets) {
                defaults.set(data, forKey: "printSettingSets")
            }
        }
    }

    init(defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        languageDomainName = domainName
        let savedLanguages = domainName.flatMap {
            defaults.persistentDomain(forName: $0)?["AppleLanguages"] as? [String]
        }
        languageOverride = savedLanguages?.first.flatMap { saved in
            UILanguage.candidates(for: saved).dropLast().first { UILanguage.supported.contains($0) }
        }
        wheelSensitivity =
            WheelPageTurner.Sensitivity(rawValue: defaults.string(forKey: "wheelSensitivity") ?? "") ?? .normal
        defaultViewLayout = ViewOptions.Layout(rawValue: defaults.string(forKey: "defaultViewLayout") ?? "")
        defaultPageTurn = ViewOptions.Transition(rawValue: defaults.string(forKey: "defaultPageTurn") ?? "")
        defaultJoinsPages = defaults.object(forKey: "defaultJoinsPages") as? Bool ?? true
        defaultReadingDirection = ViewOptions.Direction(
            rawValue: defaults.string(forKey: "defaultReadingDirection") ?? "")
        defaultScrollAxis = ViewOptions.ScrollAxis(rawValue: defaults.string(forKey: "defaultScrollAxis") ?? "")
        defaultShowsCoverAlone = defaults.object(forKey: "defaultShowsCoverAlone") as? Bool
        loneCoverWidth = LoneCoverWidth(rawValue: defaults.string(forKey: "loneCoverWidth") ?? "") ?? .onePage
        defaultAlwaysOnTop = defaults.bool(forKey: "defaultAlwaysOnTop")
        defaultMenuPinned = defaults.bool(forKey: "defaultMenuPinned")
        let scale = defaults.double(forKey: "defaultTextScale")
        defaultTextScale = TextScale.steps.contains(scale) ? scale : 1
        defaultPaperOrientation =
            PaperOrientation(rawValue: defaults.string(forKey: "defaultPaperOrientation") ?? "") ?? .auto
        layoutID = defaults.string(forKey: "layout") ?? "a4Single"
        themeID = defaults.string(forKey: "theme") ?? "standard"
        presetID = defaults.string(forKey: "preset") ?? "none"
        margin = defaults.object(forKey: "margin") as? Double ?? 15
        pageNumbers = defaults.bool(forKey: "pageNumbers")
        paperSeries = PaperSeries(rawValue: defaults.string(forKey: "paperSeries") ?? "")
        finishDefaults = defaults.data(forKey: "printFinishDefaults").flatMap {
            try? JSONDecoder().decode(FinishDefaults.self, from: $0)
        }
        viewPageNumbers = defaults.bool(forKey: "viewPageNumbers")
        rotateBack = defaults.bool(forKey: "rotateBack")
        allowsJavaScript = defaults.object(forKey: "allowsJavaScript") as? Bool ?? true
        printerName = defaults.string(forKey: "printer")
        printPageOrder = PrintPageOrder(rawValue: defaults.string(forKey: "printPageOrder") ?? "") ?? .lastSheetFirst
        printerProfiles =
            defaults.data(forKey: "printerProfiles").flatMap {
                try? JSONDecoder().decode([String: StoredPrinterProfile].self, from: $0)
            }?.compactMapValues(\.value) ?? [:]
        recentThemeIDs = defaults.stringArray(forKey: "recentThemes") ?? []
        favoriteThemeIDs = defaults.stringArray(forKey: "favoriteThemes") ?? []
        let storedSets =
            defaults.data(forKey: "printSettingSets").flatMap {
                try? JSONDecoder().decode([StoredSettingSet].self, from: $0)
            } ?? []
        var ids: Set<UUID> = []
        var names: Set<String> = []
        printSettingSets = storedSets.compactMap(\.value).filter {
            guard !ids.contains($0.id), !names.contains($0.name) else { return false }
            ids.insert($0.id)
            names.insert($0.name)
            return true
        }
    }

    /// Confirmation belongs to the caller; replacing a name keeps its original place and identity.
    func savePrintSettingSet(_ set: PrintSettingSet) {
        var set = set
        set.name = set.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !set.name.isEmpty else { return }
        if let index = printSettingSets.firstIndex(where: { $0.name == set.name }) {
            set.id = printSettingSets[index].id
            printSettingSets[index] = set
        } else {
            printSettingSets.append(set)
        }
    }

    @discardableResult
    func renamePrintSettingSet(_ id: UUID, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = printSettingSets.firstIndex(where: { $0.id == id }),
            !printSettingSets.contains(where: { $0.id != id && $0.name == name })
        else { return false }
        printSettingSets[index].name = name
        return true
    }

    func removePrintSettingSet(_ id: UUID) {
        printSettingSets.removeAll { $0.id == id }
    }

    var nextPrintSettingSetName: String {
        var number = 1
        while true {
            let name = String(format: String(localized: "Setting Set %lld"), Int64(number))
            if !printSettingSets.contains(where: { $0.name == name }) { return name }
            number += 1
        }
    }

    private struct StoredPrinterProfile: Decodable {
        let value: PrinterProfile?
        init(from decoder: any Decoder) throws {
            value = try? PrinterProfile(from: decoder)
        }
    }

    private struct StoredSettingSet: Decodable {
        let value: PrintSettingSet?
        init(from decoder: any Decoder) throws {
            value = try? PrintSettingSet(from: decoder)
        }
    }

    func recordThemeChoice(_ id: String) {
        recentThemeIDs = PrintThemeMenu.recording(id, in: recentThemeIDs)
    }

    func toggleFavoriteTheme(_ id: String) {
        favoriteThemeIDs = PrintThemeMenu.toggling(id, in: favoriteThemeIDs)
    }

    private struct FinishDefaults: Codable {
        var options: PrintOptions
        var finish: PrintFinish
    }

    var printOptions: PrintOptions {
        finishDefaults?.options ?? PrintOptions(marginsInMillimeters: margin, showsPageNumbers: pageNumbers)
    }

    var printFinish: PrintFinish { finishDefaults?.finish ?? PrintFinish() }

    /// New documents start with these margins, header and footer, page breaks and contents.
    func setFinishDefaults(options: PrintOptions, finish: PrintFinish) {
        var options = options
        options.rotatesBackSides = false
        finishDefaults = FinishDefaults(options: options, finish: finish)
        if let margin = options.margins.uniformValue { self.margin = margin }
        pageNumbers = options.showsPageNumbers
    }
}

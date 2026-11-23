import Observation
import SurimonoCore
import SurimonoRendering
import SwiftUI

/// A deleted setting set and where it was in the list.
struct RemovedPrintSettingSet: Equatable {
    /// Tells two deletions of the same set apart.
    let id = UUID()
    let set: PrintSettingSet
    let index: Int
}

enum ShortcutPreferencesLoadState: Equatable {
    case loaded, migrationRequired
    case unreadable(ShortcutModelError)

    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

enum ShortcutPreferencesError: Error {
    case unreadableSavedData, staleSnapshot, environmentUnavailable
}

/// App-wide defaults. Settings a user changes in a document window are remembered per document instead.
@Observable
final class AppPreferences {
    static let shared = AppPreferences(
        clipboardDirectory: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? UserLibrary.defaultRoot.appendingPathComponent("ClosedClipboard", isDirectory: true) : nil)

    private(set) var keyboardShortcuts: ShortcutConfiguration
    private(set) var keyboardShortcutsLoadState: ShortcutPreferencesLoadState
    private(set) var keyboardShortcutsRevision: UInt64 = 0
    private var keyboardShortcutsStoredData: Data?

    var openClipboardShortcut: KeyCombo? {
        didSet {
            defaults.set(
                openClipboardShortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "openClipboardShortcut")
        }
    }
    var printClipboardShortcut: KeyCombo? {
        didSet {
            defaults.set(
                printClipboardShortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "printClipboardShortcut")
        }
    }

    var exportImageDPI: Int {
        get {
            [72, 144, 300].contains(defaults.integer(forKey: "exportImageDPI"))
                ? defaults.integer(forKey: "exportImageDPI") : 144
        }
        set { defaults.set([72, 144, 300].contains(newValue) ? newValue : 144, forKey: "exportImageDPI") }
    }

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
    /// The decision after a reader removes all but one document from a binder.
    var singleDocumentBinderPolicy: SingleDocumentBinderPolicy {
        didSet { defaults.set(singleDocumentBinderPolicy.rawValue, forKey: "singleDocumentBinderPolicy") }
    }

    var corners: CornerPreset {
        didSet { defaults.set(corners.rawValue, forKey: "corners") }
    }
    @ObservationIgnored var menuBarVisibilityDidChange: ((Bool) -> Void)?
    var showsMenuBarItem: Bool {
        didSet {
            defaults.set(showsMenuBarItem, forKey: "showsMenuBarItem")
            menuBarVisibilityDidChange?(showsMenuBarItem)
        }
    }
    /// The look of the app's windows. Nothing stored means Light, also for readers who saw the app in Dark before.
    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
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
    var defaultShowsOnAllSpaces: Bool {
        didSet { defaults.set(defaultShowsOnAllSpaces, forKey: "defaultShowsOnAllSpaces") }
    }
    var defaultBandVisibility: BandVisibility {
        didSet { defaults.set(defaultBandVisibility.rawValue, forKey: "defaultBandVisibility") }
    }
    var menuArrangement: MenuArrangement {
        didSet { defaults.set(menuArrangement.rawValue, forKey: "menuArrangement") }
    }
    private(set) var bandArrangementStore: BandArrangementStore
    private(set) var bandArrangementNotices: [BandRepairNotice]
    private(set) var retainedBandArrangementData: Data?
    /// The stored data as it was before a load repaired it with a loss, kept aside before the first write.
    @ObservationIgnored private var repairedBandArrangementData: Data?
    /// A development build's fixture from `-SurimonoBandArrangement`: shown, never saved over the reader's sets.
    @ObservationIgnored private var showsBandArrangementFixture = false

    enum BandArrangementPersistenceError: Error {
        case retainedDataRequiresRecovery
        case fixtureIsReadOnly
    }

    /// The arrangement the view mode's bands draw for the current topology.
    var activeBandArrangement: BandArrangement {
        bandArrangementStore.activeLayouts.arrangement(for: menuArrangement)
    }

    // Encode before publishing either value. Observers never see a deleted active set or a half-written envelope.
    func updateBandArrangements(_ change: (inout BandArrangementStore) throws -> Void) throws {
        guard retainedBandArrangementData == nil else {
            throw BandArrangementPersistenceError.retainedDataRequiresRecovery
        }
        guard !showsBandArrangementFixture else { throw BandArrangementPersistenceError.fixtureIsReadOnly }
        var next = bandArrangementStore
        try change(&next)
        let data = try JSONEncoder().encode(next)
        // The first write after a repair that left something out keeps the original aside, as starting over does.
        if let original = repairedBandArrangementData {
            setAside(original, under: Self.repairedBandArrangementsKey)
            repairedBandArrangementData = nil
        }
        defaults.set(data, forKey: "bandArrangementStore")
        bandArrangementStore = next
        // What the load repaired is now written as repaired.
        bandArrangementNotices = []
    }

    /// Keeps the newest ten originals per key, each once: enough to recover from a few failed loads in a row
    /// without letting repeated recoveries grow the preferences without end.
    static let setAsideLimit = 10

    func setAside(_ data: Data, under key: String) {
        var kept = defaults.array(forKey: key) as? [Data] ?? []
        kept.removeAll { $0 == data }
        kept.append(data)
        defaults.set(Array(kept.suffix(Self.setAsideLimit)), forKey: key)
    }

    /// Starts the arrangements over from Standard after stored data could not be read. The unreadable data is kept
    /// under another key, never deleted, so a later version that can read it still finds it.
    func startBandArrangementsOver() {
        guard let retained = retainedBandArrangementData, !showsBandArrangementFixture else { return }
        setAside(retained, under: Self.unreadableBandArrangementsKey)
        // An empty store, not a missing one: with nothing stored, the next launch would derive "Previous
        // Arrangement" again from the old Contents setting.
        let store = BandArrangementStore()
        if let data = try? JSONEncoder().encode(store) { defaults.set(data, forKey: "bandArrangementStore") }
        retainedBandArrangementData = nil
        repairedBandArrangementData = nil
        bandArrangementNotices = []
        bandArrangementStore = store
    }

    static let unreadableBandArrangementsKey = "unreadableBandArrangementStores"
    static let repairedBandArrangementsKey = "repairedBandArrangementStores"

    func selectBandArrangement(_ selection: BandArrangementSelection) throws {
        try updateBandArrangements { try $0.select(selection) }
    }

    func saveBandArrangement(_ set: BandArrangementSet, activate: Bool = true) throws {
        try updateBandArrangements { try $0.insert(set, activate: activate) }
    }

    func overwriteBandArrangement(_ selection: BandArrangementSelection, layouts: BandArrangementVariants) throws {
        try updateBandArrangements { try $0.overwrite(selection, layouts: layouts) }
    }

    func renameBandArrangement(_ selection: BandArrangementSelection, to name: String) throws {
        try updateBandArrangements { try $0.rename(selection, to: name) }
    }

    func deleteBandArrangement(
        _ selection: BandArrangementSelection, replacement: BandArrangementSelection? = nil
    ) throws {
        try updateBandArrangements { try $0.delete(selection, replacement: replacement) }
    }

    var outlinePresentation: OutlinePresentation {
        didSet { defaults.set(outlinePresentation.rawValue, forKey: "outlinePresentation") }
    }
    var showsOutlineOnBand: Bool {
        didSet {
            defaults.set(showsOutlineOnBand, forKey: "showsOutlineOnBand")
            followOutlineChoice()
        }
    }

    /// Until an arrangement is saved, the old checkbox still decides whether Contents is on the band: the store is then
    /// only derived in memory, so following the checkbox writes nothing. Once saved, the explicit placement wins.
    private func followOutlineChoice() {
        guard defaults.data(forKey: "bandArrangementStore") == nil, retainedBandArrangementData == nil,
            !showsBandArrangementFixture
        else { return }
        bandArrangementStore = .legacyOutlineChoice(showsOutlineOnBand, name: String(localized: "Previous Arrangement"))
    }
    var reloadsChangedFiles: Bool {
        didSet { defaults.set(reloadsChangedFiles, forKey: "reloadsChangedFiles") }
    }
    var changeBackgroundHex: String {
        didSet { defaults.set(changeBackgroundHex, forKey: "changeBackgroundHex") }
    }
    var changeTextHex: String? {
        didSet { defaults.set(changeTextHex, forKey: "changeTextHex") }
    }
    private static func storedColor(_ defaults: UserDefaults, key: String) -> String? {
        guard let hex = defaults.string(forKey: key), CodeColor.components(hex) != nil else { return nil }
        return hex
    }
    var changeFollowing: ChangeFollowing {
        didSet { defaults.set(changeFollowing.rawValue, forKey: "changeFollowing") }
    }
    var defaultTypeface: Typeface {
        didSet { defaults.set(defaultTypeface.rawValue, forKey: "defaultTypeface") }
    }

    var defaultTextScale: Double {
        didSet { defaults.set(defaultTextScale, forKey: "defaultTextScale") }
    }
    var defaultPaperOrientation: PaperOrientation {
        didSet { defaults.set(defaultPaperOrientation.rawValue, forKey: "defaultPaperOrientation") }
    }
    /// Kept for this app run, including when the Settings window is closed and reopened.
    var settingsSection: SettingsSection = .general
    // An explicit request can point to the current section while a search hides its contents.
    var settingsNavigationRevision = 0

    var viewDefaults: ViewDefaultPreferences {
        ViewDefaultPreferences(
            layout: defaultViewLayout, transition: defaultPageTurn, joinsPages: defaultJoinsPages,
            direction: defaultReadingDirection, scrollAxis: defaultScrollAxis, showsCoverAlone: defaultShowsCoverAlone)
    }

    var layoutID: String { didSet { defaults.set(layoutID, forKey: "layout") } }
    var themeID: String { didSet { defaults.set(themeID, forKey: "theme") } }
    /// The code palette a document starts with; `CodePalette.matchesStyleID` follows its style.
    var defaultCodePaletteID: String { didSet { defaults.set(defaultCodePaletteID, forKey: "codePalette") } }
    var triesThemeOnHover: Bool {
        didSet { defaults.set(triesThemeOnHover, forKey: "triesThemeOnHover") }
    }
    var themeSampleSource: ThemeSampleSource {
        didSet { defaults.set(themeSampleSource.rawValue, forKey: "themeSampleSource") }
    }
    private(set) var hasSeenPrintStyleTip: Bool {
        didSet { defaults.set(hasSeenPrintStyleTip, forKey: "hasSeenPrintStyleTip") }
    }

    func takePrintStyleTip(usesPrintTheme: Bool) -> Bool {
        guard usesPrintTheme, !hasSeenPrintStyleTip else { return false }
        hasSeenPrintStyleTip = true
        return true
    }

    var presetID: String { didSet { defaults.set(presetID, forKey: "preset") } }
    var margin: Double {
        didSet {
            defaults.set(margin, forKey: "margin")
            if finishDefaults?.options.margins.uniformValue != margin {
                finishDefaults?.options.margins = .uniform(margin)
            }
        }
    }
    /// The header and footer new documents start with.
    var defaultFurniture: PageFurniture {
        didSet {
            if let data = try? JSONEncoder().encode(defaultFurniture) { defaults.set(data, forKey: "defaultFurniture") }
            if finishDefaults?.options.furniture != defaultFurniture {
                finishDefaults?.options.furniture = defaultFurniture
            }
        }
    }
    /// The paper chosen on a tray is the paper the next documents start on: the default layout moves to the one that
    /// prints the same way on that series. The series is not kept beside it. The default layout's paper says it, so
    /// the two cannot disagree.
    func choosePaperSeries(_ series: PaperSeries) {
        let layout = PrintLayout.presets.first { $0.id == layoutID } ?? .a4Single
        layoutID = layout.counterpart(in: series).id
    }
    /// What the reader made the default from the tray; the margin and header above stay for Settings.
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

    func setManualDuplexCorrection(_ correction: ManualDuplexCorrection, for name: String, duplex: DuplexMode) {
        var profile = printerProfile(for: name)
        profile.setManualCorrection(correction, for: duplex)
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
    /// The set deleted last, while its notice with Undo shows.
    private(set) var removedPrintSettingSet: RemovedPrintSettingSet?
    @ObservationIgnored private var removalNoticeTask: Task<Void, Never>?
    private(set) var printSettingSets: [PrintSettingSet] {
        didSet {
            if let data = try? JSONEncoder().encode(printSettingSets) {
                defaults.set(data, forKey: "printSettingSets")
            }
        }
    }
    /// The note pages the reader saved, in the order they were saved.
    private(set) var notePresets: [NoteUserPreset] {
        didSet {
            if let data = try? JSONEncoder().encode(notePresets) { defaults.set(data, forKey: "notePresets") }
        }
    }
    /// Binders the reader closed lately, newest first, for the File menu's Recent Binders.
    private(set) var recentBinders: RecentBinders {
        didSet {
            if let data = try? JSONEncoder().encode(recentBinders) { defaults.set(data, forKey: "recentBinders") }
        }
    }

    private let clipboardStore: ClosedClipboardStore?
    let clipboardNow: () -> Date
    @ObservationIgnored private var clipboardExpiry: Task<Void, Never>?

    var closedClipboardDocuments = ClosedClipboardDocuments() {
        didSet {
            if keepsClosedClipboardDocuments && keepsClipboardAfterQuitting {
                mirrorClipboardHistory()
            }
            // A close may hand focus to another window before its clipboard history has been recorded.
            NotificationCenter.default.post(name: ClosedClipboardDocuments.didChange, object: self)
        }
    }
    var keepsClosedClipboardDocuments: Bool {
        didSet {
            defaults.set(keepsClosedClipboardDocuments, forKey: "keepsClosedClipboardDocuments")
            if !keepsClosedClipboardDocuments {
                keepsClipboardAfterQuitting = false
                closedClipboardDocuments = ClosedClipboardDocuments()
            }
        }
    }

    var keepsClipboardAfterQuitting: Bool {
        didSet {
            defaults.set(keepsClipboardAfterQuitting, forKey: "keepsClipboardAfterQuitting")
            if keepsClosedClipboardDocuments && keepsClipboardAfterQuitting {
                expireClipboardHistory()
            } else {
                clipboardExpiry?.cancel()
                clipboardStore?.clear()
            }
        }
    }

    func clearClosedClipboardDocuments() {
        guard !closedClipboardDocuments.entries.isEmpty else { return }
        clipboardStore?.clear()
        closedClipboardDocuments = ClosedClipboardDocuments()
    }

    private func expireClipboardHistory() {
        closedClipboardDocuments.removeExpired(at: clipboardNow())
    }

    private func mirrorClipboardHistory() {
        clipboardExpiry?.cancel()
        guard let clipboardStore else { return }
        let entries = closedClipboardDocuments.entries
        clipboardStore.mirror(entries)
        if let oldest = entries.map(\.closedAt).min() {
            let delay = max(
                0, oldest.addingTimeInterval(ClosedClipboardDocuments.lifetime).timeIntervalSince(clipboardNow()))
            clipboardExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.expireClipboardHistory()
            }
        }
    }

    /// How text from the clipboard or a service gets its format. A value this build cannot read starts over from the
    /// standard choices.
    var clipboardFormat: ClipboardFormatSettings {
        didSet {
            if let data = try? JSONEncoder().encode(clipboardFormat) { defaults.set(data, forKey: "clipboardFormat") }
        }
    }

    var recentFiles: RecentFiles {
        didSet {
            if let data = try? JSONEncoder().encode(recentFiles) { defaults.set(data, forKey: "recentFiles") }
        }
    }

    init(
        defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier,
        locale: Locale? = nil, defaultPaperSize: CGSize? = nil,
        shortcutEnvironment: ShortcutValidationContext = .unavailable,
        clipboardDirectory: URL? = nil, clipboardNow: @escaping () -> Date = { Date() }
    ) {
        clipboardStore = clipboardDirectory.map { ClosedClipboardStore(directory: $0) }
        self.clipboardNow = clipboardNow
        // Only the app's own preferences follow the Mac: its region and the paper its print system starts with. A
        // store made for a test or a preview starts on A4 wherever it runs (CI machines are set to the United
        // States, and tests written for A4 failed there), unless it is told a locale.
        let followsSystem = locale == nil && defaults === UserDefaults.standard
        let initialSeries: PaperSeries =
            locale == nil && !followsSystem
            ? .a
            : PaperSeries.initial(
                locale: locale ?? .current,
                defaultPaperSize: defaultPaperSize ?? (followsSystem ? NSPrintInfo.shared.paperSize : nil))
        openClipboardShortcut = defaults.data(forKey: "openClipboardShortcut").flatMap {
            try? JSONDecoder().decode(KeyCombo.self, from: $0)
        }
        printClipboardShortcut = defaults.data(forKey: "printClipboardShortcut").flatMap {
            try? JSONDecoder().decode(KeyCombo.self, from: $0)
        }
        let shortcuts = Self.loadKeyboardShortcuts(defaults: defaults, environment: shortcutEnvironment)
        keyboardShortcuts = shortcuts.0
        keyboardShortcutsLoadState = shortcuts.1
        keyboardShortcutsStoredData = defaults.data(forKey: ShortcutStore.preferencesKey)
        singleDocumentBinderPolicy =
            defaults.string(forKey: "singleDocumentBinderPolicy")
            .flatMap(SingleDocumentBinderPolicy.init(rawValue:)) ?? .defaultValue
        self.defaults = defaults
        languageDomainName = domainName
        let savedLanguages = domainName.flatMap {
            defaults.persistentDomain(forName: $0)?["AppleLanguages"] as? [String]
        }
        languageOverride = savedLanguages?.first.flatMap { saved in
            UILanguage.candidates(for: saved).dropLast().first { UILanguage.supported.contains($0) }
        }
        corners =
            Self.screenshotChoice("SurimonoCorners")
            ?? defaults.string(forKey: "corners").flatMap(CornerPreset.init(rawValue:)) ?? .standard
        showsMenuBarItem = defaults.object(forKey: "showsMenuBarItem") as? Bool ?? true
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .default
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
        defaultShowsOnAllSpaces = defaults.bool(forKey: "defaultShowsOnAllSpaces")
        // Earlier versions could only pin the band open when a window opened. Unpinned was then a choice of hiding it.
        defaultBandVisibility =
            BandVisibility(rawValue: defaults.string(forKey: "defaultBandVisibility") ?? "")
            ?? (defaults.object(forKey: "defaultMenuPinned") as? Bool == false ? .onHover : .always)
        menuArrangement =
            Self.screenshotChoice("SurimonoMenuArrangement")
            ?? MenuArrangement(rawValue: defaults.string(forKey: "menuArrangement") ?? "") ?? .split
        outlinePresentation =
            Self.screenshotChoice("SurimonoOutline")
            ?? OutlinePresentation(rawValue: defaults.string(forKey: "outlinePresentation") ?? "") ?? .popover
        showsOutlineOnBand = defaults.object(forKey: "showsOutlineOnBand") as? Bool ?? true
        let bandData = defaults.data(forKey: "bandArrangementStore")
        let bandLoad = BandArrangementStore.load(bandData)
        if bandData == nil, let legacy = defaults.object(forKey: "showsOutlineOnBand") as? Bool {
            bandArrangementStore = .legacyOutlineChoice(legacy, name: String(localized: "Previous Arrangement"))
        } else {
            bandArrangementStore = bandLoad.store
        }
        bandArrangementNotices = bandLoad.notices
        retainedBandArrangementData = bandLoad.retainedData
        if bandLoad.retainedData == nil, bandLoad.notices.contains(where: \.losesData) {
            repairedBandArrangementData = bandData
        }
        #if DEBUG
            if let fixture = DebugSnapshot.argument("SurimonoBandParts").flatMap(DebugSnapshot.bandPartsFixture) {
                bandArrangementStore = fixture
                menuArrangement = .split
                showsBandArrangementFixture = true
            }
            if let fixture = DebugSnapshot.argument("SurimonoBandArrangement")
                .flatMap(DebugSnapshot.bandArrangementFixture(named:))
            {
                bandArrangementStore = fixture
                showsBandArrangementFixture = true
            }
            if DebugSnapshot.argument("SurimonoBandArrangement") == "repaired" {
                // A record that cannot be read and a set with one broken layout, read as the app reads them.
                let load = BandArrangementStore.load(DebugSnapshot.repairedArrangementData)
                bandArrangementStore = load.store
                bandArrangementNotices = load.notices
                showsBandArrangementFixture = true
            }
            if DebugSnapshot.argument("SurimonoBandArrangement") == "unreadable" {
                // As if a newer version had written the store; the fixture flag keeps everything unwritten.
                retainedBandArrangementData = Data(#"{"schemaVersion":2}"#.utf8)
                showsBandArrangementFixture = true
            }
        #endif

        reloadsChangedFiles = defaults.object(forKey: "reloadsChangedFiles") as? Bool ?? true
        changeBackgroundHex = Self.storedColor(defaults, key: "changeBackgroundHex") ?? ChangeMark.defaultBackgroundHex
        changeTextHex = Self.storedColor(defaults, key: "changeTextHex")
        changeFollowing =
            Self.screenshotChoice("SurimonoChanges")
            ?? ChangeFollowing(rawValue: defaults.string(forKey: "changeFollowing") ?? "") ?? .jump
        defaultTypeface = defaults.string(forKey: "defaultTypeface").flatMap(Typeface.init(rawValue:)) ?? .style
        // Any whole percent of the range, as the Settings field takes it; earlier versions kept one of the steps.
        let scale = defaults.double(forKey: "defaultTextScale")
        defaultTextScale = TextScale.range.contains(scale) ? TextScale.clamped(scale) : 1
        defaultPaperOrientation =
            PaperOrientation(rawValue: defaults.string(forKey: "defaultPaperOrientation") ?? "") ?? .auto
        // Earlier versions kept a series chosen on a tray under "paperSeries" without moving the default layout to
        // it: the cards then showed that series over sheets of another paper. Without a stored default layout that
        // choice comes before the region; with one, the layout's own paper stands.
        let chosenSeries = PaperSeries(rawValue: defaults.string(forKey: "paperSeries") ?? "")
        layoutID =
            defaults.string(forKey: "layout")
            ?? PrintLayout.a4Single.counterpart(in: chosenSeries ?? initialSeries).id
        themeID = defaults.string(forKey: "theme") ?? "standard"
        themeSampleSource =
            defaults.string(forKey: "themeSampleSource").flatMap(ThemeSampleSource.init(rawValue:)) ?? .specimen
        triesThemeOnHover = defaults.object(forKey: "triesThemeOnHover") as? Bool ?? true
        hasSeenPrintStyleTip = defaults.bool(forKey: "hasSeenPrintStyleTip")
        defaultCodePaletteID = defaults.string(forKey: "codePalette") ?? CodePalette.matchesStyleID
        presetID = defaults.string(forKey: "preset") ?? "none"
        margin = defaults.object(forKey: "margin") as? Double ?? 15
        let storedFinish = defaults.data(forKey: "printFinishDefaults").flatMap {
            try? JSONDecoder().decode(FinishDefaults.self, from: $0)
        }
        // Earlier versions kept a switch for the page number beside the defaults made from the tray.
        defaultFurniture =
            defaults.data(forKey: "defaultFurniture").flatMap {
                try? JSONDecoder().decode(PageFurniture.self, from: $0)
            }
            ?? storedFinish?.options.furniture
            ?? (defaults.bool(forKey: "pageNumbers") ? .pageNumber : PageFurniture())
        finishDefaults = storedFinish
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
        notePresets =
            defaults.data(forKey: "notePresets").flatMap {
                try? JSONDecoder().decode([StoredNotePreset].self, from: $0)
            }?.compactMap(\.value) ?? []
        recentFiles =
            defaults.data(forKey: "recentFiles").flatMap {
                try? JSONDecoder().decode(RecentFiles.self, from: $0)
            } ?? RecentFiles()
        recentBinders =
            defaults.data(forKey: "recentBinders").flatMap {
                try? JSONDecoder().decode(RecentBinders.self, from: $0)
            } ?? RecentBinders()
        let keepsHistory = defaults.object(forKey: "keepsClosedClipboardDocuments") as? Bool ?? true
        keepsClosedClipboardDocuments = keepsHistory
        keepsClipboardAfterQuitting = defaults.bool(forKey: "keepsClipboardAfterQuitting") && keepsHistory
        clipboardFormat =
            defaults.data(forKey: "clipboardFormat").flatMap {
                try? JSONDecoder().decode(ClipboardFormatSettings.self, from: $0)
            } ?? .standard
        if let clipboardStore {
            if keepsClipboardAfterQuitting {
                closedClipboardDocuments = clipboardStore.load(now: clipboardNow())
                mirrorClipboardHistory()
            } else {
                clipboardStore.clear()
            }
        }
    }

    /// A choice for this run only. It takes part in the first assignment because any later one would be saved.
    private static func screenshotChoice<Choice: RawRepresentable>(_ name: String) -> Choice?
    where Choice.RawValue == String {
        #if DEBUG
            DebugSnapshot.argument(name).flatMap(Choice.init(rawValue:))
        #else
            nil
        #endif
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

    func importPrintSettingSets(_ sets: [PrintSettingSet], language: String) -> [String] {
        let result = PrintSettingSetArchive.merge(
            sets, into: printSettingSets + PrintSettingSet.builtIns(language: language))
        if !result.additions.isEmpty { printSettingSets += result.additions }
        return result.alreadyHere
    }

    func movePrintSettingSets(from offsets: IndexSet, to destination: Int) {
        guard offsets.allSatisfy({ printSettingSets.indices.contains($0) }),
            (0...printSettingSets.count).contains(destination)
        else { return }
        let moving = offsets.sorted().map { printSettingSets[$0] }
        var reordered = printSettingSets.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        reordered.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        printSettingSets = reordered
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

    /// Deleting acts at once; the notice it leaves is the way back.
    @discardableResult
    func removePrintSettingSet(_ id: UUID) -> RemovedPrintSettingSet? {
        guard let index = printSettingSets.firstIndex(where: { $0.id == id }) else { return nil }
        let removal = RemovedPrintSettingSet(set: printSettingSets.remove(at: index), index: index)
        removedPrintSettingSet = removal
        removalNoticeTask?.cancel()
        removalNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: DocumentViewModel.undoNoticeDuration) } catch { return }
            if self?.removedPrintSettingSet == removal { self?.removedPrintSettingSet = nil }
        }
        return removal
    }

    /// Puts a deleted set back where it was. A set saved under its name meanwhile keeps the name, and the deleted
    /// one stays deleted.
    @discardableResult
    func restorePrintSettingSet(_ removal: RemovedPrintSettingSet) -> Bool {
        if removedPrintSettingSet == removal { dismissRemovedPrintSettingSet() }
        guard !printSettingSets.contains(where: { $0.id == removal.set.id || $0.name == removal.set.name })
        else { return false }
        printSettingSets.insert(removal.set, at: min(removal.index, printSettingSets.count))
        return true
    }

    func dismissRemovedPrintSettingSet() {
        removalNoticeTask?.cancel()
        removedPrintSettingSet = nil
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

    @discardableResult
    func saveNotePreset(named name: String, style: NotePaperStyle) -> NoteUserPreset {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = NoteUserPreset(name: name.isEmpty ? nextNotePresetName : name, style: style)
        notePresets.append(preset)
        return preset
    }

    /// Only the reader's own presets are stored, so a built-in one cannot be replaced.
    func overwriteNotePreset(_ id: String, style: NotePaperStyle) {
        guard let index = notePresets.firstIndex(where: { $0.id == id }) else { return }
        notePresets[index].style = style
    }

    func removeNotePreset(_ id: String) {
        notePresets.removeAll { $0.id == id }
    }

    var nextNotePresetName: String {
        var number = notePresets.count + 1
        while true {
            let name = String(format: String(localized: "My Notes %lld"), Int64(number))
            if !notePresets.contains(where: { $0.name == name }) { return name }
            number += 1
        }
    }

    private struct StoredNotePreset: Decodable {
        let value: NoteUserPreset?
        init(from decoder: any Decoder) throws {
            value = try? NoteUserPreset(from: decoder)
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

    func recordRecentBinder(_ binder: RecentBinder) {
        recentBinders.record(binder)
    }

    func replaceRecentBinder(_ binder: RecentBinder, with moved: RecentBinder) {
        recentBinders.replace(binder, with: moved)
    }

    func clearRecentBinders() {
        recentBinders.clear()
    }

    private struct FinishDefaults: Codable {
        var options: PrintOptions
        var finish: PrintFinish
    }

    var printOptions: PrintOptions {
        var options = finishDefaults?.options ?? PrintOptions(marginsInMillimeters: margin)
        options.furniture = defaultFurniture
        return options
    }

    var printFinish: PrintFinish { finishDefaults?.finish ?? PrintFinish() }

    /// New documents start with these margins, header and footer, page breaks and contents.
    func setFinishDefaults(options: PrintOptions, finish: PrintFinish) {
        var options = options
        options.rotatesBackSides = false
        finishDefaults = FinishDefaults(options: options, finish: finish)
        if let margin = options.margins.uniformValue { self.margin = margin }
        defaultFurniture = options.furniture
    }
}

extension AppPreferences {
    private static func loadKeyboardShortcuts(defaults: UserDefaults, environment: ShortcutValidationContext)
        -> (ShortcutConfiguration, ShortcutPreferencesLoadState)
    {
        guard defaults.object(forKey: ShortcutStore.preferencesKey) != nil else {
            return (LegacyShortcutMigration.evaluate(defaults: defaults, environment: environment), .migrationRequired)
        }
        guard let data = defaults.data(forKey: ShortcutStore.preferencesKey) else {
            return (.init(), .unreadable(.malformedStore))
        }
        do {
            return (try ShortcutStore.decode(data), .loaded)
        } catch let error as ShortcutModelError {
            return (.init(), .unreadable(error))
        } catch {
            return (.init(), .unreadable(.malformedStore))
        }
    }

    func reloadKeyboardShortcuts(environment: ShortcutValidationContext) {
        let loaded = Self.loadKeyboardShortcuts(defaults: defaults, environment: environment)
        if loaded.0 != keyboardShortcuts || loaded.1 != keyboardShortcutsLoadState {
            keyboardShortcutsRevision += 1
        }
        keyboardShortcuts = loaded.0
        keyboardShortcutsLoadState = loaded.1
        keyboardShortcutsStoredData = defaults.data(forKey: ShortcutStore.preferencesKey)
    }

    func saveKeyboardShortcuts(_ plan: ShortcutChangePlan, expectedRevision: UInt64) throws {
        guard expectedRevision == keyboardShortcutsRevision, plan.original == keyboardShortcuts else {
            throw ShortcutPreferencesError.staleSnapshot
        }
        guard plan.environment.reservationsAvailable, plan.environment.projectionAvailable else {
            throw ShortcutPreferencesError.environmentUnavailable
        }
        try persistKeyboardShortcuts(plan.configuration)
    }

    func saveKeyboardShortcutMigration(
        environment: ShortcutValidationContext, expectedConfiguration: ShortcutConfiguration? = nil
    ) throws {
        if keyboardShortcutsLoadState == .loaded { return }
        guard !keyboardShortcutsLoadState.isUnreadable else { throw ShortcutPreferencesError.unreadableSavedData }
        guard environment.reservationsAvailable, environment.projectionAvailable else {
            throw ShortcutPreferencesError.environmentUnavailable
        }
        // Re-evaluate before saving so a legacy write during registration cannot publish another candidate.
        guard defaults.object(forKey: ShortcutStore.preferencesKey) == nil else {
            throw ShortcutPreferencesError.staleSnapshot
        }
        let migrated = LegacyShortcutMigration.evaluate(defaults: defaults, environment: environment)
        if let expectedConfiguration, migrated != expectedConfiguration {
            throw ShortcutPreferencesError.staleSnapshot
        }
        try persistKeyboardShortcuts(migrated)
    }

    private func persistKeyboardShortcuts(_ configuration: ShortcutConfiguration) throws {
        guard !keyboardShortcutsLoadState.isUnreadable else { throw ShortcutPreferencesError.unreadableSavedData }
        guard defaults.data(forKey: ShortcutStore.preferencesKey) == keyboardShortcutsStoredData,
            defaults.object(forKey: ShortcutStore.preferencesKey) == nil || keyboardShortcutsStoredData != nil
        else {
            throw ShortcutPreferencesError.staleSnapshot
        }
        let data = try ShortcutStore.encode(configuration)
        defaults.set(data, forKey: ShortcutStore.preferencesKey)
        keyboardShortcutsStoredData = data
        keyboardShortcuts = configuration
        keyboardShortcutsLoadState = .loaded
        keyboardShortcutsRevision += 1
    }
}

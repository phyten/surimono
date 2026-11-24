import Foundation
import SurimonoCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case view = "View and Page Turn"
    case toolbarArrangement = "Toolbar Arrangement"
    case styles = "Styles"
    case printing = "Printing"
    case pageNumbers = "Page Numbers"
    case settingSets = "Setting Sets"
    case clipboard = "Clipboard"
    case html = "HTML"
    case org = "Org"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .keyboardShortcuts: "keyboard"
        case .view: "book"
        case .toolbarArrangement: "menubar.rectangle"
        case .pageNumbers: "number"
        case .printing: "printer"
        case .settingSets: "slider.horizontal.3"
        // "textformat" is drawn as kana in Japanese, beside line icons; the band's palette is the same in every language.
        case .styles: "paintpalette"
        case .org: "doc.text"
        case .html: "globe"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

enum SettingsGroup: String, CaseIterable {
    case general = "General Group"
    case viewing = "Viewing"
    case printing = "Printing Group"
    case opening = "Opening"

    var sections: [SettingsSection] {
        switch self {
        case .general: [.general, .keyboardShortcuts]
        case .viewing: [.view, .toolbarArrangement, .styles]
        case .printing: [.printing, .pageNumbers, .settingSets]
        case .opening: [.clipboard, .org, .html]
        }
    }
}

struct SettingsSearchRow {
    let section: SettingsSection
    let label: String
    let anchor: String
    let words: [String]
    let identifiers: [String]
    let heading: String?

    init(
        _ section: SettingsSection, _ label: String, anchor: String? = nil, words: [String] = [],
        identifiers: [String] = [], heading: String? = nil
    ) {
        self.section = section
        self.label = label
        self.anchor = anchor ?? label
        self.identifiers = identifiers
        self.words = words
        self.heading = heading
    }
}

struct SettingsSearchSelection {
    private var sectionToKeep: SettingsSection?

    mutating func begin(in section: SettingsSection) { sectionToKeep = section }
    mutating func pick(_ section: SettingsSection) { sectionToKeep = section }

    mutating func finish() -> SettingsSection? {
        defer { sectionToKeep = nil }
        return sectionToKeep
    }
}

struct SettingsSearchResults {
    var rows: [SettingsSearchRow] = []
    fileprivate var ranks: [SettingsSection: Rank] = [:]

    fileprivate struct Rank: Comparable {
        enum Source: Int { case identifier, section, setting, command }
        enum Match: Int, Comparable {
            case exact, prefix, substring, keyword
            static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        }
        let source: Source
        let match: Match

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.source.rawValue, lhs.match.rawValue) < (rhs.source.rawValue, rhs.match.rawValue)
        }
    }

    func bestSection(keeping current: SettingsSection) -> SettingsSection? {
        guard let best = ranks.values.min() else { return nil }
        if ranks[current] == best { return current }
        return SettingsGroup.allCases.flatMap(\.sections).first { ranks[$0] == best }
    }
}

enum SettingsCatalogue {
    static let shortcutGroups: [ShortcutGroup] = [.application, .documentAndPrinting, .reading, .styles, .lists]

    static let rows: [SettingsSearchRow] = {
        var rows: [SettingsSearchRow] = [
            .init(.general, "Language"),
            .init(.general, "Appearance"),
            .init(.general, "Show in Menu Bar"),
            .init(.general, "When a Binder Is Down to One Document", heading: "After a Document Opens"),
            .init(.general, "Reload When the File Changes", heading: "After a Document Opens"),
            .init(.general, "After a File Is Saved", heading: "After a Document Opens"),
            .init(.general, "Changed Places", words: ["highlight", "background"], heading: "After a Document Opens"),
            .init(.general, "Changed Text", heading: "After a Document Opens"),
            .init(.general, "Corners", heading: "Window"),
            .init(.general, "Float on Top", heading: "Window"),
            .init(.general, "Show on All Spaces", heading: "Window"),
            .init(.general, "Check for Updates Automatically", heading: "Updates"),
            .init(.general, "When an Update Is Found", words: ["install"], heading: "Updates"),
            .init(.general, "Updates are unavailable in development builds.", heading: "Updates"),
            .init(.view, "Scroll Sensitivity"),
            .init(.view, "View Type", words: ["spread", "single page"]),
            .init(.view, "Page Turning"),
            .init(.view, "Reading Direction"),
            .init(.view, "Scroll Direction"),
            .init(.view, "Show First Page Alone"),
            .init(.view, "Window Width When the First Page Is Alone"),
            .init(.view, "Join Pages in Single-Page Scrolling"),
            .init(.view, "Toolbar Layout"),
            .init(.view, "Toolbar Visibility"),
            .init(.view, "Parts of the Toolbar", words: ["Arrange…"]),
            .init(.view, "Show Contents As", words: ["outline", "drawer"]),
            .init(.pageNumbers, "In View Mode"),
            .init(.pageNumbers, "In Print", words: ["header", "footer"]),
            .init(.printing, "Print Layout"),
            .init(.printing, "Paper Orientation"),
            .init(.printing, "Text Margins", words: ["paper"]),
            .init(.printing, "Rotate Back Sides 180°"),
            .init(.printing, "Output Order"),
            .init(.styles, "Try a Style on the Paper When Pointing at It"),
            .init(.styles, "Default Style"),
            .init(.styles, "Default Code Colors"),
            .init(.styles, "Default Text Size"),
            .init(.styles, "Default Typeface", words: ["LaTeX Typeface", "As the Style"]),
            .init(.styles, "Open Styles Folder"),
            .init(.styles, "Reload", anchor: "Open Styles Folder"),
            .init(.org, "Heading Numbers", identifiers: ["num", ".org"]),
            .init(.org, "Table of Contents at the Top", identifiers: ["toc", ".org"]),
            .init(.org, "Subscripts and Superscripts", identifiers: ["^", ".org"]),
            .init(.html, "Default HTML Preset"),
            .init(.html, "Allow JavaScript in HTML"),
            .init(.html, "Open Presets Folder"),
            .init(.html, "Reload", anchor: "Open Presets Folder"),
            .init(.clipboard, "Keep Closed Clipboard Documents Until Quit"),
            .init(.clipboard, "Also Keep Them After Quitting"),
            .init(.clipboard, "Choosing the Format"),
            .init(.clipboard, "Format to Open"),
            .init(.clipboard, "How Readily to Format"),
            .init(.toolbarArrangement, "Parts", words: ["Icons and Names", "Icons Only"]),
            .init(.toolbarArrangement, "Start Over"),
            .init(.toolbarArrangement, "Use Saved"),
            .init(
                .toolbarArrangement, "Arrangement Set",
                words: ["Overwrite", "Manage Arrangement", "Duplicate…", "New…", "Rename…", "Delete…"]),
            .init(.toolbarArrangement, "Editing", words: ["Undo", "Redo", "Back to Standard"]),
            .init(.toolbarArrangement, "Toolbar Arrangement"),
            .init(.toolbarArrangement, "Parts to Add", words: ["Separator"]),
            .init(
                .toolbarArrangement, "Move To",
                words: ["Move Earlier", "Move Later", "Add Separator After", "Remove from Toolbar"]),
            .init(.settingSets, "Import…"),
            .init(.settingSets, "Export All…", anchor: "Import…"),
            .init(
                .keyboardShortcuts, "Search Shortcuts",
                words: ["Import Shortcuts…", "Export Shortcuts…", "Restore All Defaults…"]),
        ]
        rows += BandLayout.Item.allCases.map {
            .init(.toolbarArrangement, $0.editorNameResource.key, anchor: $0.rawValue)
        }
        rows += ClipboardSettings.recognizable.map {
            .init(
                .clipboard, ClipboardSettings.labelKey($0),
                words: ["Formats to Recognize Automatically"])
        }
        rows.append(.init(.clipboard, "Back to Standard"))
        for group in shortcutGroups {
            rows += ShortcutOperation.catalog.filter { $0.group == group }.map { shortcut($0) }
        }
        rows += ShortcutFixedKey.catalog.map {
            .init(
                .keyboardShortcuts, ShortcutText.fixedResource($0.behavior).key,
                anchor: $0.behavior.rawValue, words: ["Fixed Keys"])
        }
        rows += ShortcutOperation.catalog.filter(\.isGlobal).map { shortcut($0) }
        return rows
    }()

    private static func shortcut(_ operation: ShortcutOperation) -> SettingsSearchRow {
        .init(
            .keyboardShortcuts, ShortcutText.nameResource(operation.id).key, anchor: operation.id.rawValue,
            words: operation.isGlobal ? ["Global"] : [])
    }

    static func search(
        _ query: String, in rows: [SettingsSearchRow],
        localize: (String) -> String = { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) }
    ) -> SettingsSearchResults {
        typealias Rank = SettingsSearchResults.Rank
        let needle = folded(query)
        guard !needle.isEmpty else { return SettingsSearchResults() }
        var labels: [String: Rank.Match] = [:]
        var misses: Set<String> = []
        func match(_ key: String) -> Rank.Match? {
            if let cached = labels[key] { return cached }
            if misses.contains(key) { return nil }
            let spellings = [folded(key), folded(localize(key))]
            let result: Rank.Match
            if spellings.contains(needle) {
                result = .exact
            } else if spellings.contains(where: { $0.hasPrefix(needle) }) {
                result = .prefix
            } else if spellings.contains(where: { $0.contains(needle) }) {
                result = .substring
            } else {
                misses.insert(key)
                return nil
            }
            labels[key] = result
            return result
        }

        var results = SettingsSearchResults()
        for row in rows {
            let rank: Rank
            if row.identifiers.contains(needle) {
                rank = Rank(source: .identifier, match: .exact)
            } else if match(row.section.rawValue) != nil {
                rank = Rank(source: .section, match: .exact)
            } else {
                let isCommand = row.section == .keyboardShortcuts || row.section == .toolbarArrangement
                let quality: Rank.Match
                if let heading = row.heading.flatMap({ match($0) }) {
                    quality = min(heading, match(row.label) ?? heading)
                } else if let label = match(row.label) {
                    quality = label
                } else if row.words.contains(where: { match($0) != nil }) {
                    quality = .keyword
                } else {
                    continue
                }
                rank = Rank(source: isCommand ? .command : .setting, match: quality)
            }
            results.rows.append(row)
            results.ranks[row.section] = min(results.ranks[row.section] ?? rank, rank)
        }
        return results
    }

    private static func folded(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        guard folded.unicodeScalars.contains(where: { (0x3041...0x309F).contains($0.value) }) else { return folded }
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }
}

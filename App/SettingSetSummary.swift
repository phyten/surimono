import Foundation
import SurimonoCore

/// Presentation only: the saved set remains independent of language and library contents.
struct SettingSetSummary {
    let themes: [PrintTheme]
    let presets: [HTMLCleanupPreset]
    let language: String

    init(themes: [PrintTheme], presets: [HTMLCleanupPreset], language: String) {
        self.themes = themes
        self.presets = presets
        self.language = language
    }

    init(library: UserLibrary, language: String = Bundle.main.preferredLocalizations.first ?? "en") {
        self.init(themes: library.themes, presets: library.presets, language: language)
    }

    private func text(_ key: String) -> String {
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func title(_ part: PrintSettingSet.Part) -> String {
        switch part {
        case .layout: text("Print Layout")
        case .margins: text("Margins")
        case .furniture: text("Header & Footer")
        case .finish: text("Page breaks and contents")
        case .notes: text("Notes")
        case .style: text("Style and Text Size")
        case .htmlPreset: text("HTML Preset")
        }
    }

    func lines(_ set: PrintSettingSet) -> [String] {
        PrintSettingSet.Part.allCases.compactMap { line($0, in: set) }
    }

    func oneLine(_ set: PrintSettingSet) -> String { lines(set).joined(separator: " · ") }

    func subtitle(_ set: PrintSettingSet) -> String {
        Self.shortened(oneLine(set))
    }

    static func shortened(_ text: String, limit: Int = 60) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    func line(_ part: PrintSettingSet.Part, in set: PrintSettingSet) -> String? {
        guard set.parts.contains(part) else { return nil }
        var values: [String] = []
        switch part {
        case .layout:
            if let layout = PrintLayout.presets.first(where: { $0.id == set.layoutID }) {
                values.append(layout.displayName(language: language))
            }
            if let orientation = set.paperOrientation {
                switch orientation {
                case .auto:
                    if values.isEmpty { values.append(text("Automatic (Match Document)")) }
                case .portrait: values.append(text("Portrait"))
                case .landscape: values.append(text("Landscape"))
                }
            }
        case .margins:
            if let margins = set.margins {
                let numbers =
                    margins.uniformValue.map { [$0] } ?? [margins.top, margins.left, margins.bottom, margins.right]
                let value = numbers.map {
                    $0.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: language)))
                }.joined(separator: " / ")
                values.append(String(format: text("Margins: %@ mm"), value))
            }
            // Only what changes the paper is worth a word; linking is how the fields are edited.
            if set.mirrorsMargins == true { values.append(text("Mirrored Margins")) }
        case .furniture:
            if let furniture = set.furniture {
                let key: String
                switch furniture.preset {
                case .none: key = "No Header or Footer"
                case .number: key = "Page Number"
                case .name: key = "File Name + Number"
                case .nameAndDate: key = "File Name, Date + Number"
                case .custom: key = "Custom Header and Footer"
                }
                values.append(text(key))
            }
        case .finish:
            if let finish = set.finish {
                switch finish.toc.mode {
                case .hidden: values.append(text("Do Not Print Contents"))
                case .front: values.append(text("Add Contents to Front"))
                case .source: values.append(text("Follow the Text's Contents"))
                }
                switch finish.links {
                case .asIs: break
                case .endnotes: values.append(text("Links on Paper") + ": " + text("List at the End"))
                case .inline: values.append(text("Links on Paper") + ": " + text("After the Text"))
                }
                if finish.breaks.usesRightPages {
                    values.append(text("Chapters from Right Page"))
                } else if [finish.breaks.h1, finish.breaks.h2, finish.breaks.h3].contains(.page) {
                    values.append(text("New Page for Each Chapter"))
                }
            }
        case .notes:
            if let notes = set.notes {
                if !notes.isEnabled {
                    values.append(text("Notes Off"))
                } else {
                    let key: String
                    switch notes.placement {
                    case .spreadLeft: key = "Left of the Spread"
                    case .spreadRight: key = "Right of the Spread"
                    case .duplexBack: key = "After Each Page"
                    case .chapterEnd: key = "After Chapters"
                    }
                    values.append(text("Notes") + ": " + text(key))
                }
            }
        case .style:
            // A removed style must not leave a misleading fragment in the overview.
            if let id = set.themeID {
                guard let theme = themes.first(where: { $0.id == id }) else { return nil }
                values.append(String(format: text("Style: %@"), theme.displayName(language: language)))
            }
            if let scale = set.textScale, TextScale.steps.contains(scale) {
                values.append(String(format: text("Text: %lld%%"), Int64((scale * 100).rounded())))
            }
        case .htmlPreset:
            if let preset = presets.first(where: { $0.id == set.presetID }) {
                values.append(String(format: text("HTML: %@"), preset.displayName(language: language)))
            }
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
}

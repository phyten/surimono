import SurimonoCore
import SwiftUI

enum DocumentsChapter {
    // Plain text is the renderer's format for recognized source files.
    static let formats: [DocumentFormat] = [
        .markdown, .quarto, .rMarkdown, .rst, .asciidoc, .mediawiki, .org, .html, .plainText,
    ]

    static func title(_ format: DocumentFormat) -> String {
        format == .plainText ? "Source Code" : format.displayName
    }

    static func extensions(for format: DocumentFormat) -> [String] {
        switch format {
        case .markdown: [".md", ".markdown"]
        case .quarto: [".qmd"]
        case .rMarkdown: [".rmd"]
        case .rst: [".rst"]
        case .asciidoc: [".adoc", ".asciidoc"]
        case .mediawiki: [".wiki", ".mediawiki"]
        default: []
        }
    }

    /// Only lead contents reaches the renderer through FormatReadingChoices today.
    /// ReadingSyntax.readToday describes manuscript instructions, not app preferences.
    static func rows(for format: DocumentFormat) -> [ReadingCatalogueRow] {
        switch format {
        case .markdown, .quarto, .rMarkdown, .rst, .asciidoc, .mediawiki:
            ReadingCatalogue.rows(for: format).filter { $0.id == .tableOfContents }
        default: []
        }
    }
}

struct DocumentsChapterView<Page: View>: View {
    let formats: [DocumentFormat]
    @Binding var selection: DocumentFormat
    @ViewBuilder let page: Page

    static func usesList(width: CGFloat) -> Bool { width >= 720 }

    var body: some View {
        GeometryReader { viewport in
            if Self.usesList(width: viewport.size.width) {
                HStack(spacing: 0) {
                    List(
                        selection: Binding(
                            get: { Optional(selection) }, set: { if let value = $0 { selection = value } })
                    ) {
                        ForEach(formats, id: \.self) { format in
                            Text(LocalizedStringKey(DocumentsChapter.title(format))).tag(format)
                        }
                    }
                    .accessibilityLabel(Text("Format"))
                    .frame(width: 156)
                    Divider()
                    page.id(selection)
                }
            } else {
                VStack(spacing: 0) {
                    Picker("Format", selection: $selection) {
                        ForEach(formats, id: \.self) { format in
                            Text(LocalizedStringKey(DocumentsChapter.title(format))).tag(format)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8)
                    Divider()
                    page.id(selection)
                }
            }
        }
    }
}

struct FormatDefaultsPane: View {
    let format: DocumentFormat
    let preferences: AppPreferences

    private var rows: [ReadingCatalogueRow] { DocumentsChapter.rows(for: format) }

    var defaults: ReadingDefaults<FormatReadingChoices> {
        let current = preferences.formatReadingDefaults
        var reset = current
        for row in rows { reset.revert(row.id, for: format) }
        return ReadingDefaults(builtIn: reset, alternatives: [], current: current)
    }

    func set(_ value: ReadingSettingValue, for id: ReadingSettingID) {
        preferences.formatReadingDefaults.set(value, for: id, format: format)
    }

    func reset() {
        for row in rows { preferences.formatReadingDefaults.revert(row.id, for: format) }
    }

    private func description(_ row: ReadingRowResolution) -> String {
        switch row {
        case .toggle(let flag): return String(localized: flag.value ? "On" : "Off")
        case .outline(let present, let depth):
            let title = String(localized: ReadingOutlinePicker.title(for: present.value ? depth.value : nil))
            if !present.value, depth.layer == .document {
                // The remembered depth also applies when a file requests a contents list.
                return title + " · " + String(localized: ReadingOutlinePicker.title(for: depth.value))
            }
            return title
        }
    }

    private func differences(_ current: FormatReadingChoices, _ target: FormatReadingChoices) -> [ReadingSettingChange]
    {
        rows.compactMap { row in
            guard let from = current.resolve(row.id, for: format), let to = target.resolve(row.id, for: format),
                from != to
            else { return nil }
            return (String(localized: row.id.label), description(from), description(to))
        }
    }

    var body: some View {
        ReadingDefaultsControls(
            defaults: defaults, resetQuestion: "Reset to defaults?", differences: differences, apply: { _ in reset() },
            header: {
                Text("Defaults for New Documents").settingSearchRow("Defaults for New Documents", fillsRow: false)
            },
            rows: {
                ForEach(rows, id: \.id) { entry in
                    if let row = preferences.formatReadingDefaults.resolve(entry.id, for: format) {
                        FormatReadingControl(
                            id: entry.id, row: row, resetHelp: String(localized: "Restore Default"),
                            documentName: "", fileURL: nil, allowsFileChanges: false,
                            set: { set($0, for: entry.id) },
                            revert: { preferences.formatReadingDefaults.revert(entry.id, for: format) }
                        )
                        .settingSearchRow(entry.id.label.key)
                    }
                }
            })
    }
}

enum CodeNumberRow: CaseIterable {
    case source, blocks

    var label: LocalizedStringResource {
        switch self {
        case .source: "Line Numbers"
        case .blocks: "Code Block Line Numbers"
        }
    }

    var keyPath: WritableKeyPath<CodeLineNumberDefaults, CodeBlockOptions.LineNumbers> {
        self == .source ? \.source : \.blocks
    }
}

extension CodeBlockOptions.LineNumbers {
    var title: LocalizedStringResource {
        switch self {
        case .none: "No Numbers"
        case .all: "Every Line"
        case .everyFive: "Every 5 Lines"
        }
    }
}

struct CodeNumberDefaultsPane: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        ReadingDefaultsControls(
            defaults: ReadingDefaults(
                builtIn: CodeLineNumberDefaults(), alternatives: [], current: preferences.codeLineNumbers),
            resetQuestion: "Reset to defaults?",
            differences: { current, target in
                CodeNumberRow.allCases.compactMap { row in
                    let from = current[keyPath: row.keyPath]
                    let to = target[keyPath: row.keyPath]
                    guard from != to else { return nil }
                    return (String(localized: row.label), String(localized: from.title), String(localized: to.title))
                }
            }, apply: { preferences.codeLineNumbers = $0 },
            header: {
                Text("Defaults for New Documents")
            },
            rows: {
                ForEach(CodeNumberRow.allCases, id: \.self) { row in
                    Picker(row.label, selection: $preferences.codeLineNumbers[dynamicMember: row.keyPath]) {
                        ForEach(CodeBlockOptions.LineNumbers.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.settingSearchRow(row.label.key)
                }
            })
    }
}

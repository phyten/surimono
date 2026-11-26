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

    static func resetQuestion(for format: DocumentFormat) -> LocalizedStringResource {
        if format == .org { return "Reset Org settings to defaults?" }
        let name = LocalizedStringResource(String.LocalizationValue(stringLiteral: title(format)))
        return "Reset the \(name) settings to Surimono defaults?"
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

    /// ReadingSyntax.readToday describes manuscript instructions, not app preferences.
    static func rows(for format: DocumentFormat) -> [ReadingCatalogueRow] {
        switch format {
        case .markdown: ReadingCatalogue.rows(for: format)
        case .quarto, .rMarkdown, .rst, .asciidoc, .mediawiki:
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
                    DocumentFormatList(formats: formats, selection: $selection)
                        .frame(width: 178)
                    Divider()
                    page.id(selection)
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Format")
                        DocumentFormatPicker(formats: formats, selection: $selection)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8)
                    Divider()
                    page.id(selection)
                }
            }
        }
    }
}

/// A menu choice is an explicit visit even when search already displays the selected item.
private struct DocumentFormatPicker: NSViewRepresentable {
    let formats: [DocumentFormat]
    @Binding var selection: DocumentFormat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let locale = context.environment.locale
        let titles = formats.map {
            String(
                localized: LocalizedStringResource(
                    String.LocalizationValue(stringLiteral: DocumentsChapter.title($0)), locale: locale))
        }
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.setAccessibilityLabel(String(localized: LocalizedStringResource("Format", locale: locale)))
        if let index = formats.firstIndex(of: selection) { button.selectItem(at: index) }
        context.coordinator.chooseIndex = { index in
            if formats.indices.contains(index) { selection = formats[index] }
        }
    }

    final class Coordinator: NSObject {
        var chooseIndex: ((Int) -> Void)?
        @objc func choose(_ button: NSPopUpButton) { chooseIndex?(button.indexOfSelectedItem) }
    }
}

/// A source list gives the selection its native key-window and inactive appearances.
private struct DocumentFormatList: NSViewRepresentable {
    let formats: [DocumentFormat]
    @Binding var selection: DocumentFormat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FormatTable()
        table.style = .sourceList
        table.headerView = nil
        table.intercellSpacing = .zero
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: .init("format")))
        table.reselect = context.coordinator.choose
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let locale = context.environment.locale
        var rows = formats.map(Optional.some)
        if let index = formats.firstIndex(of: .plainText), index > 0 { rows.insert(nil, at: index) }
        coordinator.select = nil
        if coordinator.rows != rows || coordinator.locale != locale {
            coordinator.rows = rows
            coordinator.locale = locale
            table.setAccessibilityLabel(String(localized: LocalizedStringResource("Format", locale: locale)))
            table.reloadData()
        }
        if let index = rows.firstIndex(of: selection), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        coordinator.select = { selection = $0 }
    }

    private final class FormatTable: NSTableView {
        var reselect: ((Int) -> Void)?

        override func mouseDown(with event: NSEvent) {
            let clicked = row(at: convert(event.locationInWindow, from: nil))
            if clicked >= 0, clicked == selectedRow { reselect?(clicked) }
            super.mouseDown(with: event)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [DocumentFormat?] = []
        var locale = Locale.current
        var select: ((DocumentFormat) -> Void)?

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row] == nil ? 11 : 31 }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row] != nil }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            rowView.setAccessibilityHidden(rows[row] == nil)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let format = rows[row] else { return nil }
            let title = String.LocalizationValue(stringLiteral: DocumentsChapter.title(format))
            let label = NSTextField(labelWithString: String(localized: LocalizedStringResource(title, locale: locale)))
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -16),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            if let table = notification.object as? NSTableView { choose(table.selectedRow) }
        }

        func choose(_ row: Int) {
            guard rows.indices.contains(row), let format = rows[row] else { return }
            select?(format)
        }
    }
}

struct DocumentDefaultsHeader: View {
    let format: DocumentFormat
    let status: LocalizedStringResource

    var body: some View {
        HStack {
            Text(LocalizedStringKey(DocumentsChapter.title(format)))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .settingSearchRow("Defaults for New Documents", fillsRow: false)
            Spacer()
            Text(status).foregroundStyle(.secondary)
                .settingSearchRow(status.key, fillsRow: false)
        }
        .font(.body).textCase(nil)
        .accessibilityElement(children: .contain)
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
            defaults: defaults, format: format, differences: differences, apply: { _ in reset() },
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
            format: .plainText,
            differences: { current, target in
                CodeNumberRow.allCases.compactMap { row in
                    let from = current[keyPath: row.keyPath]
                    let to = target[keyPath: row.keyPath]
                    guard from != to else { return nil }
                    return (String(localized: row.label), String(localized: from.title), String(localized: to.title))
                }
            }, apply: { preferences.codeLineNumbers = $0 },
            rows: {
                ForEach(CodeNumberRow.allCases, id: \.self) { row in
                    Picker(row.label, selection: $preferences.codeLineNumbers[dynamicMember: row.keyPath]) {
                        ForEach(CodeBlockOptions.LineNumbers.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.settingSearchRow(row.label.key)
                }
            })
    }
}

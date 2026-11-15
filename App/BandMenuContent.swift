import SurimonoCore
import SwiftUI

/// The complete index of operations for a document. These identities are never persisted as band parts.
struct BandMenuContent {
    enum ID: String, Hashable {
        case outline, thumbnails, previousPage, nextPage, documentInfo
        case presentation, layout, transition, zoom
        case readingDirection, scrollDirection, cover, selectText
        case style, paperOrientation, paperSeries, margins, ignoreSlides
        case floatOnTop, alwaysShowToolbar, viewOptions
        case printSettings, beforePrinting, print, saveAsFile
        case keysAndGestures
    }

    enum GroupID: CaseIterable, Hashable {
        case navigation, display, reading, paper, window, output, help

        var items: [ID] {
            switch self {
            case .navigation: [.outline, .thumbnails, .previousPage, .nextPage, .documentInfo]
            case .display: [.presentation, .layout, .transition, .zoom]
            case .reading: [.readingDirection, .scrollDirection, .cover, .selectText]
            case .paper: [.style, .paperOrientation, .paperSeries, .margins, .ignoreSlides]
            case .window: [.floatOnTop, .alwaysShowToolbar, .viewOptions]
            case .output: [.printSettings, .beforePrinting, .print, .saveAsFile]
            case .help: [.keysAndGestures]
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: ID
        let title: String
        var value: String?
        var isChecked: Bool?
        var isEnabled = true
    }

    struct Group: Identifiable, Equatable {
        let id: GroupID
        let entries: [Entry]
    }

    /// Both the native menu and tests consume these rows, including the exact separator positions.
    enum Row: Equatable {
        case header(String)
        case divider
        case entry(Entry)
    }

    let model: DocumentViewModel

    var header: String {
        ([model.displayName, model.formatBadge] + [model.pageIndicator].compactMap { $0 }).joined(separator: " · ")
    }

    var groups: [Group] {
        GroupID.allCases.compactMap { id in
            let entries = id.items.filter(isApplicable).map(entry)
            return entries.isEmpty ? nil : Group(id: id, entries: entries)
        }
    }

    var rows: [Row] {
        [.header(header)] + groups.flatMap { [.divider] + $0.entries.map(Row.entry) }
    }

    func moreHelp(controller: ShortcutController = .shared) -> String {
        ShortcutHints.help(
            String(localized: "More · View Options"), model.showsWeb ? [] : [.viewOptions], controller: controller)
    }

    func help(for entry: Entry) -> String {
        if entry.id == .paperOrientation, !entry.isEnabled {
            return String(localized: "This layout uses a fixed paper orientation.")
        }
        let operations: [ShortcutOperationID] =
            switch entry.id {
            case .outline: [.viewOutline]
            case .thumbnails: [.listToggle]
            case .previousPage: [.readingPrevious]
            case .nextPage: [.readingNext]
            case .documentInfo: [.viewDocumentInfo]
            case .zoom: [.viewZoomFit]
            case .selectText: [.viewSelectText]
            case .alwaysShowToolbar: [.viewToolbarAlways]
            case .viewOptions: model.showsWeb ? [] : [.viewOptions]
            case .ignoreSlides: [.viewIgnoreSlides]
            case .printSettings: [.printSettings]
            case .beforePrinting: [.printReviewIssues]
            case .print: [.documentPrint]
            case .saveAsFile: [.documentSaveAsFile]
            case .keysAndGestures: [.appKeyGuide]
            default: []
            }
        return ShortcutHints.help(entry.title, operations)
    }

    private func isApplicable(_ id: ID) -> Bool {
        let parts = BandLayout.Item.applicable(for: model)
        let secondary = SecondaryViewControl.applicable(for: model)
        switch id {
        case .outline: return parts.contains(.outline)
        case .thumbnails: return parts.contains(.thumbnails)
        case .previousPage, .nextPage: return parts.contains(.pageTurn)
        case .documentInfo: return !model.showsWeb && model.pageCount > 0
        case .presentation: return parts.contains(.presentation)
        case .layout: return parts.contains(.layout)
        case .transition: return parts.contains(.transition)
        case .zoom: return parts.contains(.zoom)
        case .style: return parts.contains(.style)
        case .readingDirection: return secondary.contains(.direction)
        case .scrollDirection: return secondary.contains(.scrollAxis)
        case .paperOrientation: return secondary.contains(.paperOrientation)
        case .paperSeries: return secondary.contains(.paperSeries)
        case .cover: return secondary.contains(.cover)
        case .selectText: return secondary.contains(.selectText)
        case .margins: return model.marginsApply
        case .ignoreSlides: return model.detectedSlideDeck != nil && model.usesHTMLPresentation
        case .beforePrinting: return model.printIssueCount > 0
        case .saveAsFile: return model.canSaveAsFile
        case .floatOnTop, .alwaysShowToolbar, .viewOptions, .printSettings, .print, .keysAndGestures: return true
        }
    }

    func entry(_ id: ID) -> Entry {
        var title: String
        var value: String?
        var checked: Bool?
        var enabled = true
        switch id {
        case .outline: title = String(localized: "Contents…")
        case .thumbnails:
            title = String(localized: "Show List")
            checked = model.isDrawerOpen
        case .previousPage: title = String(localized: "Previous Page")
        case .nextPage: title = String(localized: "Next Page")
        case .documentInfo: title = String(localized: "Document Info…")
        case .presentation:
            title = String(localized: "View As")
            value = model.htmlPresentation.name
        case .layout:
            title = String(localized: "View Type")
            value = model.viewOptions.layout.name
        case .transition:
            title = String(localized: "Page Turn")
            value = model.viewOptions.transition.name
        case .zoom:
            title = String(format: String(localized: "Fit to Window (%@)"), model.zoomPercentage)
        case .readingDirection:
            title = String(localized: "Reading Direction")
            value =
                model.viewOptions.direction == .leftToRight
                ? String(localized: "Left to Right") : String(localized: "Right to Left")
        case .scrollDirection:
            title = String(localized: "Scroll Direction")
            value =
                model.viewOptions.scrollAxis == .vertical
                ? String(localized: "Vertical") : String(localized: "Horizontal")
            enabled = model.viewOptions.usesScrollAxis
        case .cover:
            title = String(localized: "Show First Page Alone")
            checked = model.viewOptions.showsCoverAlone
        case .selectText:
            title = String(localized: "Select Text")
            checked = model.isSelectingText
        case .style:
            title = model.usesHTMLPreset ? String(localized: "HTML Preset") : String(localized: "Style")
            value = model.styleName
        case .paperOrientation:
            title = String(localized: "Paper Orientation")
            value = PaperOrientationControl(model: model).valueName
            enabled = !model.renderLayout.hasFixedOrientation
        case .paperSeries:
            title = String(localized: "Paper Series")
            value = model.layout.series.name
        case .margins:
            title = String(localized: "Margins")
            value =
                model.printOptions.margins.uniformValue.map { MarginUnit.current.label($0) }
                ?? String(localized: "Mixed")
        case .ignoreSlides:
            title = String(localized: "Don't Treat as Slides")
            checked = model.ignoresSlides
        case .floatOnTop:
            title = String(localized: "Float on Top")
            checked = model.isAlwaysOnTop
        case .alwaysShowToolbar:
            title = String(localized: "Always Show Toolbar")
            checked = model.isBandAlwaysVisible
        case .viewOptions: title = String(localized: "View Options…")
        case .printSettings: title = String(localized: "Print Settings…")
        case .beforePrinting: title = String(localized: "Before Printing (\(model.printIssueCount))…")
        case .print: title = String(localized: "Print")
        case .saveAsFile: title = String(localized: "Save as File…")
        case .keysAndGestures: title = String(localized: "Keys and Gestures")
        }
        return Entry(
            id: id, title: value.map { choice(title, $0) } ?? title, value: value, isChecked: checked,
            isEnabled: enabled)
    }

    /// Commands and toggles share this dispatch with the rendered items; pickers keep their existing bindings.
    func perform(_ id: ID) {
        guard isApplicable(id), entry(id).isEnabled else { return }
        switch id {
        case .outline: model.toggleOutline()
        case .thumbnails: model.isDrawerOpen.toggle()
        case .previousPage: model.paper.turnPage(forward: false)
        case .nextPage: model.paper.turnPage(forward: true)
        case .documentInfo: model.isFiguresPresented = true
        case .zoom: model.zoomToFit()
        case .cover: model.viewOption(\.showsCoverAlone).wrappedValue.toggle()
        case .selectText: model.isSelectingText.toggle()
        case .ignoreSlides: model.setIgnoresSlides(!model.ignoresSlides)
        case .floatOnTop: model.isAlwaysOnTop.toggle()
        case .alwaysShowToolbar: model.isBandAlwaysVisible.toggle()
        case .viewOptions: model.isViewOptionsPresented = true
        case .printSettings: model.presentPrintSettings()
        case .beforePrinting: model.reviewPrintIssues()
        case .print:
            // The index belongs to the viewing screen. A stale item must never submit from the print screen.
            guard model.mode == .view else { return }
            model.performPrintCommand()
        case .saveAsFile: model.saveAsFile()
        case .keysAndGestures: KeyGuideWindow.shared.show()
        case .presentation, .layout, .transition, .readingDirection, .scrollDirection,
            .style, .paperOrientation, .paperSeries, .margins:
            break
        }
    }
}

struct BandMoreLabel: View {
    var body: some View {
        Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
    }
}

/// The fixed index depends only on the document, never on band geometry or placement.
struct BandMoreMenu: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        let content = BandMenuContent(model: model)
        Menu {
            ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .header(let title): Text(verbatim: title).disabled(true)
                case .divider: Divider()
                case .entry(let entry):
                    BandMenuItem(model: model, entry: entry)
                        .disabled(!entry.isEnabled)
                        .help(content.help(for: entry))
                }
            }
        } label: {
            BandMoreLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(content.moreHelp())
    }
}

/// A choice and its current value on a single line.
func choice(_ title: String, _ value: String) -> String {
    String(
        format: String(localized: "%@: %@", comment: "A menu item that names a choice and its current value"), title,
        value)
}

private struct BandMenuItem: View {
    @Bindable var model: DocumentViewModel
    let entry: BandMenuContent.Entry

    var body: some View {
        if let checked = entry.isChecked {
            Toggle(
                entry.title,
                isOn: Binding(get: { checked }, set: { _ in BandMenuContent(model: model).perform(entry.id) }))
        } else {
            item
        }
    }

    @ViewBuilder private var item: some View {
        switch entry.id {
        case .presentation, .style, .layout, .transition:
            BandDisplayMenuChoice(model: model, entry: entry)
        case .readingDirection, .scrollDirection, .paperOrientation, .paperSeries:
            BandReadingMenuChoice(model: model, entry: entry)
        case .margins: MarginMenu(model: model, unit: .current)
        default:
            Button(entry.title) { BandMenuContent(model: model).perform(entry.id) }
        }
    }
}

/// Keep choice builders small enough for the oldest supported compiler to check independently.
private struct BandDisplayMenuChoice: View {
    @Bindable var model: DocumentViewModel
    let entry: BandMenuContent.Entry

    var body: some View {
        switch entry.id {
        case .presentation:
            Menu {
                Picker(
                    "Web or Paper",
                    selection: Binding(get: { model.htmlPresentation }, set: { model.setHTMLPresentation($0) })
                ) {
                    ForEach(HTMLPresentation.allCases, id: \.self) { presentation in
                        Label(presentation.title, systemImage: presentation.symbol).tag(presentation)
                    }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(verbatim: entry.title)
            }
        case .style:
            Menu {
                if model.usesPrintTheme {
                    Button("Choose from Samples…") { model.openThemePalette() }
                    Divider()
                }
                StyleMenuItems(model: model)
            } label: {
                Text(verbatim: entry.title)
            }
        case .layout:
            Menu {
                Picker("View", selection: Binding(get: { model.viewOptions.layout }, set: { model.setLayout($0) })) {
                    ForEach(ViewOptions.Layout.displayOrder, id: \.self) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(verbatim: entry.title)
            }
        case .transition:
            Menu {
                TransitionPicker(model: model)
            } label: {
                Text(verbatim: entry.title)
            }
        default: EmptyView()
        }
    }
}

private struct BandReadingMenuChoice: View {
    @Bindable var model: DocumentViewModel
    let entry: BandMenuContent.Entry

    var body: some View {
        switch entry.id {
        case .readingDirection:
            Menu {
                Picker("Reading Direction", selection: model.viewOption(\.direction)) {
                    Text("Left to Right · Bound Left").tag(ViewOptions.Direction.leftToRight)
                    Text("Right to Left · Bound Right").tag(ViewOptions.Direction.rightToLeft)
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(verbatim: entry.title)
            }
        case .paperOrientation:
            Menu {
                PaperOrientationControl(model: model).choices
            } label: {
                Text(verbatim: entry.title)
            }
        case .paperSeries:
            Menu {
                PaperSeriesPicker(model: model)
                    .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(verbatim: entry.title)
            }
        case .scrollDirection:
            Menu {
                Picker("Scroll Direction", selection: model.viewOption(\.scrollAxis)) {
                    Text("Vertical").tag(ViewOptions.ScrollAxis.vertical)
                    Text("Horizontal").tag(ViewOptions.ScrollAxis.horizontal)
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(verbatim: entry.title)
            }
        default: EmptyView()
        }
    }
}

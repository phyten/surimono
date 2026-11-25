import SurimonoCore
import SwiftUI

/// The complete index of operations for a document. These identities are never persisted as band parts.
struct BandMenuContent {
    enum ID: String, Hashable {
        case outline, checkWriting, thumbnails, previousPage, nextPage, documentInfo
        case presentation, layout, transition, zoom
        case readingSettings, readingDirection, scrollDirection, cover, selectText
        case textFormat, composition, style, paperOrientation, paperSeries, margins, ignoreSlides
        case floatOnTop, showOnAllSpaces, alwaysShowToolbar, viewOptions
        case printSettings, beforePrinting, print, saveAsFile
        case keysAndGestures
    }

    enum GroupID: CaseIterable, Hashable {
        case navigation, display, reading, paper, window, output, help

        var items: [ID] {
            switch self {
            case .navigation: [.outline, .checkWriting, .thumbnails, .previousPage, .nextPage, .documentInfo]
            case .display: [.presentation, .layout, .transition, .zoom]
            case .reading: [.readingSettings, .readingDirection, .scrollDirection, .cover, .selectText]
            case .paper: [.textFormat, .style, .composition, .paperOrientation, .paperSeries, .margins, .ignoreSlides]
            case .window: [.floatOnTop, .showOnAllSpaces, .alwaysShowToolbar, .viewOptions]
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
        if entry.id == .outline, model.isPreparingWholeDocument { return PageIndicatorText.preparingHelp }
        if entry.id == .textFormat {
            return ClipboardFormatText.help(kind: model.textKind ?? .plainText, origin: model.textFormatOrigin)
        }
        if entry.id == .paperOrientation, !entry.isEnabled {
            return entry.title + " · " + String(localized: "This layout uses a fixed paper orientation.")
        }
        if entry.id == .scrollDirection, !entry.isEnabled {
            return entry.title + " · " + String(localized: "Not used by the current page turn.")
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
        let title =
            entry.id == .saveAsFile
            ? entry.title + " · " + String(localized: "Saves the original document to a new file.") : entry.title
        return ShortcutHints.help(title, operations)
    }

    private func isApplicable(_ id: ID) -> Bool {
        let parts = BandLayout.Item.applicable(for: model)
        switch id {
        case .checkWriting: return model.offersProse
        case .readingSettings: return parts.contains(.readingSettings)
        case .outline: return parts.contains(.outline)
        case .thumbnails: return parts.contains(.thumbnails)
        case .previousPage, .nextPage: return parts.contains(.pageTurn)
        case .documentInfo: return !model.showsWeb && model.pageCount > 0
        case .presentation: return parts.contains(.presentation)
        case .layout: return parts.contains(.layout)
        case .transition: return parts.contains(.transition)
        case .zoom: return parts.contains(.zoom)
        case .composition: return model.offersLaTeXComposition
        case .textFormat: return model.textKind != nil
        case .style: return parts.contains(.style)
        case .readingDirection: return parts.contains(.readingDirection)
        case .scrollDirection: return parts.contains(.scrollDirection)
        case .paperOrientation: return parts.contains(.paperOrientation)
        case .paperSeries: return parts.contains(.paperSeries)
        case .cover: return parts.contains(.cover)
        case .selectText: return parts.contains(.selectText)
        case .margins: return parts.contains(.margins)
        case .ignoreSlides: return parts.contains(.ignoreSlides)
        case .beforePrinting: return model.readingPreview == nil && model.printIssueCount > 0
        case .saveAsFile: return parts.contains(.saveAsFile)
        case .floatOnTop, .showOnAllSpaces, .alwaysShowToolbar, .viewOptions, .printSettings, .print, .keysAndGestures:
            return true
        }
    }

    func entry(_ id: ID) -> Entry {
        var title: String
        var value: String?
        var checked: Bool?
        var enabled = true
        switch id {
        case .checkWriting: title = String(localized: "Check Writing")
        case .readingSettings:
            title = String(localized: "Reading Settings")
            checked = model.isReadingPanelOpen
        case .outline:
            title = String(localized: "Contents…")
            enabled = model.hasContents
        case .thumbnails:
            title = String(localized: "Show List")
            checked = model.isDrawerOpen
        case .previousPage:
            title = String(localized: "Previous Page")
            enabled = model.canTurnPaperPage(forward: false)
        case .nextPage:
            title = String(localized: "Next Page")
            enabled = model.canTurnPaperPage(forward: true)
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
        case .composition: title = PrintModeText.string("LaTeX Layout", language: model.language)
        case .textFormat:
            title = String(localized: "Format")
            value = ClipboardFormatText.value(kind: model.textKind ?? .plainText, origin: model.textFormatOrigin)
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
            value = model.marginLabel(in: .current)
        case .ignoreSlides:
            // Offered only for a page with detected slides, where this is whether they show as slides.
            title = String(localized: "Show as Slides")
            checked = !model.ignoresSlides
        case .floatOnTop:
            title = String(localized: "Float on Top")
            checked = model.isAlwaysOnTop
        case .showOnAllSpaces:
            title = String(localized: "Show on All Spaces")
            checked = model.showsOnAllSpaces
        case .alwaysShowToolbar:
            title = String(localized: "Always Show Toolbar")
            checked = model.isBandAlwaysVisible
        case .viewOptions: title = String(localized: "View Options…")
        case .printSettings: title = String(localized: "Print Settings…")
        case .beforePrinting: title = String(localized: "Before Printing (\(model.printIssueCount))…")
        case .print:
            title =
                model.previewPrintRequest.destination == nil
                ? String(localized: "Print") : String(localized: "Print When Ready")
            enabled = model.canPerformPrintCommand
        case .saveAsFile: title = String(localized: "Save as File…")
        case .keysAndGestures: title = String(localized: "Keys and Gestures")
        }
        return Entry(
            id: id, title: value.map { choice(title, $0) } ?? title, value: value, isChecked: checked,
            isEnabled: enabled)
    }

    func checkedBinding(for id: ID) -> Binding<Bool> {
        model.controlBinding(
            get: { BandMenuContent(model: $0).entry(id).isChecked ?? false },
            set: { BandMenuContent(model: $0).setChecked($1, for: id) })
    }

    /// Bindings must apply the requested value, including repeated writes during control synchronization.
    func setChecked(_ checked: Bool, for id: ID) {
        guard isApplicable(id), entry(id).isEnabled, entry(id).isChecked != checked else { return }
        switch id {
        case .outline, .checkWriting, .previousPage, .nextPage, .documentInfo, .presentation, .layout, .transition,
            .zoom,
            .readingDirection, .scrollDirection, .textFormat, .composition, .style, .paperOrientation, .paperSeries,
            .margins,
            .viewOptions, .printSettings, .beforePrinting, .print, .saveAsFile, .keysAndGestures:
            return
        case .readingSettings: model.isReadingPanelOpen = checked
        case .thumbnails: model.setSideListOpen(checked)
        case .cover: model.viewOption(\.showsCoverAlone).wrappedValue = checked
        case .selectText: model.isSelectingText = checked
        case .ignoreSlides: model.setIgnoresSlides(!checked)
        case .floatOnTop: model.isAlwaysOnTop = checked
        case .showOnAllSpaces: model.showsOnAllSpaces = checked
        case .alwaysShowToolbar: model.isBandAlwaysVisible = checked
        }
    }

    /// Commands and toggles share this dispatch with the rendered items; pickers keep their existing bindings.
    func perform(_ id: ID) {
        guard isApplicable(id), entry(id).isEnabled else { return }
        switch id {
        case .checkWriting: model.openProse()
        case .readingSettings: model.isReadingPanelOpen.toggle()
        case .outline: model.toggleOutline()
        case .thumbnails: model.setSideListOpen(!model.isDrawerOpen)
        case .previousPage: model.paper.turnPage(forward: false)
        case .nextPage: model.paper.turnPage(forward: true)
        case .documentInfo: model.isFiguresPresented = true
        case .zoom: model.zoomToFit()
        case .cover: model.viewOption(\.showsCoverAlone).wrappedValue.toggle()
        case .selectText: model.isSelectingText.toggle()
        case .ignoreSlides: model.setIgnoresSlides(!model.ignoresSlides)
        case .floatOnTop: model.isAlwaysOnTop.toggle()
        case .showOnAllSpaces: model.showsOnAllSpaces.toggle()
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
            .textFormat, .composition, .style, .paperOrientation, .paperSeries, .margins:
            break
        }
    }
}

/// The "…" button as the band draws it. `BandMeasurements` measures this same button with no items: the borderless
/// menu button pads its label, so measuring the label alone counted "…" narrower than the band draws it.
struct BandMoreButton<Items: View>: View {
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Label(BandAccessibility.more, systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // A borderless control takes the window's tint, and indigo on the band means "open" or "chosen".
        .tint(PrintPalette.ink)
        .accessibilityLabel(Text(BandAccessibility.more))
        .fixedSize()
    }
}

/// The fixed index depends only on the document, never on band geometry or placement.
struct BandMoreMenu: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        let content = BandMenuContent(model: model)
        BandMoreButton {
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
        }
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
        if entry.isChecked != nil {
            Toggle(
                entry.title,
                isOn: BandMenuContent(model: model).checkedBinding(for: entry.id))
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
        case .composition:
            Menu(entry.title) { LaTeXCompositionPicker(model: model).pickerStyle(.inline).labelsHidden() }
        case .margins: MarginMenu(model: model, unit: .current)
        case .textFormat:
            Menu {
                TextFormatPicker(model: model)
            } label: {
                Text(verbatim: entry.title)
            }
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
                    selection: model.controlBinding(get: \.htmlPresentation, set: { $0.setHTMLPresentation($1) })
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
            let accessibility = model.bandStyleAccessibility
            Menu {
                if model.usesPrintTheme {
                    Button("Choose from Samples…") { model.openThemePalette() }
                    Divider()
                }
                StyleMenuItems(model: model)
            } label: {
                Text(verbatim: entry.title)
            }
            .accessibilityLabel(Text(accessibility.name))
            .accessibilityValue(Text(verbatim: accessibility.value))
        case .layout:
            Menu {
                Picker("View", selection: model.viewOption(\.layout)) {
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
        Menu {
            BandPartChoices(model: model, id: entry.id)
        } label: {
            Text(verbatim: entry.title)
        }
    }
}

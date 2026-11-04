import SurimonoCore
import SwiftUI

/// A measured part of the band: an item in one of its forms, or a part that always stays.
enum BandSlot: Hashable {
    case item(BandLayout.Item, BandLayout.Form)
    case name, more
}

extension BandLayout.Item {
    var hasCompactForm: Bool {
        switch self {
        case .presentation, .style, .outline, .transition, .print: true
        default: false
        }
    }

    /// The spacing in front of the item on its band, which the plan counts as part of its width. Print's spacing
    /// belongs to the band's fixed part.
    func bandGap(in arrangement: MenuArrangement) -> CGFloat {
        switch self {
        case .formatBadge: OverlayBand.titleSpacing
        case .pageIndicator: arrangement == .split ? OverlayBand.toolSpacing : OverlayBand.titleSpacing
        case .print: 0
        default: OverlayBand.toolSpacing
        }
    }

    static func applicable(for model: DocumentViewModel) -> [Self] {
        // The paper's tools do nothing for a live web page.
        let paper = !model.showsWeb
        return allCases.filter { item in
            switch item {
            case .formatBadge, .print: true
            case .layout, .transition: paper
            case .presentation: model.usesHTMLPresentation
            // On the web, only a slide deck has pages to count.
            case .pageIndicator: model.pageIndicator != nil
            case .style: paper && (model.usesPrintTheme || model.usesHTMLPreset)
            case .outline: model.hasOutline && model.preferences.showsOutlineOnBand
            case .pageTurn: paper && model.menuArrangement == .split && model.pageCount > 1
            case .zoom: paper ? model.zoom > 1.001 : abs(model.webZoom - 1) > 0.001
            case .thumbnails: model.imageBundle != nil || model.binder != nil
            }
        }
    }
}

extension DocumentViewModel {
    /// A binding to one view option that records the change as the user's own.
    func viewOption<Value>(_ keyPath: WritableKeyPath<ViewOptions, Value>) -> Binding<Value> {
        Binding(
            get: { self.viewOptions[keyPath: keyPath] },
            set: { value in self.updateViewOptions { $0[keyPath: keyPath] = value } })
    }
}

/// One item of the band in the given form.
struct BandItemView: View {
    @Bindable var model: DocumentViewModel
    let item: BandLayout.Item
    let form: BandLayout.Form

    var body: some View {
        switch item {
        case .formatBadge: FormatBadge(text: model.formatBadge)
        case .pageIndicator: PageIndicatorButton(model: model)
        case .pageTurn: PageTurnButtons(model: model)
        case .outline: OutlineButton(model: model, showsName: form == .full)
        case .presentation: PresentationPicker(model: model, showsNames: form == .full)
        case .style: StyleMenu(model: model, showsName: form == .full)
        case .layout: LayoutPicker(model: model)
        case .transition: TransitionMenu(model: model, showsName: form == .full)
        case .zoom:
            Button {
                model.zoomToFit()
            } label: {
                Text(verbatim: model.zoomPercentage).monospacedDigit()
            }
            .help("Fit to Window (⌘0)")
        case .thumbnails:
            Toggle(isOn: $model.isDrawerOpen) { Label("Thumbnails", systemImage: "sidebar.left") }
                .toggleStyle(.button).labelStyle(.iconOnly).help("Thumbnails (⌃⌘S)")
        case .print: PrintButton(model: model, iconOnly: form == .compact)
        }
    }
}

/// Web or Paper for HTML: the live page, or the paper it prints as. A segmented picker on macOS shows either the
/// icons or the titles of its labels, so this draws the segments itself to show both while there is room.
struct PresentationPicker: View {
    @Bindable var model: DocumentViewModel
    let showsNames: Bool

    var body: some View {
        HStack(spacing: 1) {
            ForEach(HTMLPresentation.allCases, id: \.self) { presentation in
                segment(presentation)
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Web or Paper"))
    }

    private func segment(_ presentation: HTMLPresentation) -> some View {
        let selected = model.htmlPresentation == presentation
        return Button {
            model.setHTMLPresentation(presentation)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: presentation.symbol)
                if showsNames { Text(presentation.title) }
            }
            .padding(.horizontal, showsNames ? 8 : 7)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                RoundedRectangle(cornerRadius: 5).fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(presentation.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Switch Web or Paper (⌃⌘P)")
    }
}

extension HTMLPresentation {
    var title: LocalizedStringKey {
        switch self {
        case .web: "Web"
        case .paper: "Paper"
        }
    }

    var symbol: String {
        switch self {
        case .web: "globe"
        case .paper: "doc.text"
        }
    }

    var name: String {
        switch self {
        case .web: String(localized: "Web")
        case .paper: String(localized: "Paper")
        }
    }
}

/// Keeps the width of the widest indicator, so that turning pages never shifts the band.
struct PageIndicatorText: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if let indicator = model.pageIndicator {
            Text(verbatim: model.pageIndicatorTemplate ?? indicator).hidden()
                .overlay(alignment: .leading) { Text(verbatim: indicator) }
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(PrintPalette.ink)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// The page indicator opens the document's figures; a slide deck on the web has only the slide to tell.
struct PageIndicatorButton: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if model.showsWeb {
            PageIndicatorText(model: model)
        } else {
            Button {
                model.isFiguresPresented.toggle()
            } label: {
                PageIndicatorText(model: model)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 6).fill(model.isFiguresPresented ? PrintPalette.hover : .clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Document Info")
        }
    }
}

struct OutlineButton: View {
    @Bindable var model: DocumentViewModel
    let showsName: Bool

    var body: some View {
        Button {
            model.toggleOutline()
        } label: {
            let label = Label("Contents", systemImage: "list.bullet")
            Group {
                if showsName { label.labelStyle(.titleAndIcon) } else { label.labelStyle(.iconOnly) }
            }
            .foregroundStyle(model.isOutlineShown ? PrintPalette.ai : PrintPalette.ink)
        }
        .fixedSize()
        .help("Contents")
    }
}

/// ‹ and ›: the left one goes back, except in a book bound on the right.
struct PageTurnButtons: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        let leftIsForward = model.viewOptions.direction == .rightToLeft
        HStack(spacing: 2) {
            turn("chevron.left", forward: leftIsForward)
            turn("chevron.right", forward: !leftIsForward)
        }
        .fixedSize()
    }

    private func turn(_ symbol: String, forward: Bool) -> some View {
        let title: LocalizedStringKey = forward ? "Next Page" : "Previous Page"
        return Button {
            model.paper.turnPage(forward: forward)
        } label: {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .help(title)
    }
}

struct TransitionMenu: View {
    @Bindable var model: DocumentViewModel
    let showsName: Bool

    var body: some View {
        Menu {
            TransitionPicker(model: model)
        } label: {
            let transition = model.viewOptions.transition
            let label = Label(transition.title, systemImage: transition.symbol)
            if showsName { label.labelStyle(.titleAndIcon) } else { label.labelStyle(.iconOnly) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Page Turn")
    }
}

private struct TransitionPicker: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Picker("Page Turn", selection: model.viewOption(\.transition)) {
            ForEach(ViewOptions.Transition.allCases, id: \.self) { transition in
                Label(transition.title, systemImage: transition.symbol).tag(transition)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

// The menu stays on the band so its view-options popover keeps its anchor when the band rearranges.
struct BandMoreMenu: View {
    @Bindable var model: DocumentViewModel
    /// Empty while measuring: only the menu label needs a width.
    let overflow: [BandLayout.Item]
    /// Names the document when the band no longer shows its name, format or page in full.
    let header: String?

    var body: some View {
        Menu {
            if let header {
                Text(verbatim: header)
                Divider()
            }
            let tools = overflow.filter { $0.group != nil }
            ForEach(Array(tools.enumerated()), id: \.element) { index, item in
                if index > 0, tools[index - 1].group != item.group { Divider() }
                BandMenuItem(model: model, item: item)
            }
            if !tools.isEmpty { Divider() }
            if overflow.contains(.pageIndicator), model.pageCount > 0, !model.showsWeb {
                Button("Document Info…") { model.isFiguresPresented = true }
            }
            // Taken off the band on purpose, the contents stay within reach here.
            if model.hasOutline, !model.preferences.showsOutlineOnBand {
                Button("Contents…") { model.toggleOutline() }
            }
            ForEach(SecondaryViewControl.applicable(for: model), id: \.self) { item in
                SecondaryViewMenuItem(model: model, item: item)
            }
            Divider()
            if model.marginsApply {
                MarginMenu(model: model)
                Divider()
            }
            if model.detectedSlideDeck != nil, model.usesHTMLPresentation {
                Toggle(
                    "Don't Treat as Slides",
                    isOn: Binding(get: { model.ignoresSlides }, set: { model.setIgnoresSlides($0) }))
                Divider()
            }
            if model.printIssueCount > 0 {
                Button("Before Printing (\(model.printIssueCount))…") { model.reviewPrintIssues() }
            }
            Button("View Options…") { model.isViewOptionsPresented = true }
                .help("View Options (V)")
            Divider()
            if model.canSaveAsFile {
                Button("Save as File…") { model.saveAsFile() }
                Divider()
            }
            Button("Keys and Gestures") { KeyGuideWindow.shared.show() }
        } label: {
            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More · View Options (V)")
    }
}

/// A choice and its current value on one line, such as "Direction: Left to Right", so that the "…" menu stays as compact
/// as a menu of single-line items.
func choice(_ title: String, _ value: String) -> String {
    String(
        format: String(localized: "%@: %@", comment: "A menu item that names a choice and its current value"), title,
        value)
}

/// An item that left the band, as the "…" menu shows it: choices as submenus, switches as checked items.
private struct BandMenuItem: View {
    @Bindable var model: DocumentViewModel
    let item: BandLayout.Item

    var body: some View {
        switch item {
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
                Text(verbatim: choice(String(localized: "View As"), model.htmlPresentation.name))
            }
        case .style:
            Menu {
                if model.usesPrintTheme {
                    Button("Choose from Samples…") { model.openThemePalette() }
                    Divider()
                }
                StyleMenuItems(model: model)
            } label: {
                let title =
                    model.usesHTMLPreset ? String(localized: "HTML Preset") : String(localized: "Style")
                Text(verbatim: choice(title, model.styleName))
            }
        case .layout:
            Menu {
                Picker("View", selection: Binding(get: { model.viewOptions.layout }, set: { model.setLayout($0) })) {
                    ForEach(ViewOptions.Layout.allCases, id: \.self) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(verbatim: choice(String(localized: "View Type"), model.viewOptions.layout.name))
            }
        case .transition:
            Menu {
                TransitionPicker(model: model)
            } label: {
                Text(verbatim: choice(String(localized: "Page Turn"), model.viewOptions.transition.name))
            }
        case .outline:
            Button("Contents…") { model.toggleOutline() }
        case .zoom:
            Button(String(format: String(localized: "Fit to Window (%@)"), model.zoomPercentage)) {
                model.zoomToFit()
            }
        case .thumbnails:
            Toggle("Show Thumbnails", isOn: $model.isDrawerOpen)
        case .formatBadge, .pageIndicator, .pageTurn, .print:
            EmptyView()
        }
    }
}

// Keeping these separate from BandLayout prevents measurements or narrow windows from moving them onto the band.
enum SecondaryViewControl: CaseIterable {
    case direction, scrollAxis, paperOrientation, paperSeries, cover, selectText, floatOnTop, alwaysShowMenu

    static func applicable(for model: DocumentViewModel) -> [Self] {
        allCases.filter { item in
            switch item {
            case .direction, .scrollAxis, .paperOrientation: !model.showsWeb
            case .paperSeries: model.offersPaperSeries
            case .cover: !model.showsWeb && model.viewOptions.usesCoverOption
            case .selectText: !model.showsWeb && model.canSelectText
            case .floatOnTop, .alwaysShowMenu: true
            }
        }
    }
}

private struct SecondaryViewMenuItem: View {
    @Bindable var model: DocumentViewModel
    let item: SecondaryViewControl

    var body: some View {
        switch item {
        case .direction:
            Menu {
                Picker("Reading Direction", selection: model.viewOption(\.direction)) {
                    Text("Left to Right · Bound Left").tag(ViewOptions.Direction.leftToRight)
                    Text("Right to Left · Bound Right").tag(ViewOptions.Direction.rightToLeft)
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                let value =
                    model.viewOptions.direction == .leftToRight
                    ? String(localized: "Left to Right") : String(localized: "Right to Left")
                Text(verbatim: choice(String(localized: "Reading Direction"), value))
            }
        case .paperOrientation: PaperOrientationControl(model: model)
        case .paperSeries:
            Menu {
                PaperSeriesPicker(selection: $model.paperSeries)
                    .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(verbatim: choice(String(localized: "Paper Size"), model.paperSeries.name))
            }
        case .scrollAxis:
            Menu {
                Picker("Scroll Direction", selection: model.viewOption(\.scrollAxis)) {
                    Text("Vertical").tag(ViewOptions.ScrollAxis.vertical)
                    Text("Horizontal").tag(ViewOptions.ScrollAxis.horizontal)
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                let value =
                    model.viewOptions.scrollAxis == .vertical
                    ? String(localized: "Vertical") : String(localized: "Horizontal")
                Text(verbatim: choice(String(localized: "Scroll Direction"), value))
            }
            .disabled(!model.viewOptions.usesScrollAxis)
        case .cover:
            Toggle("Show First Page Alone", isOn: model.viewOption(\.showsCoverAlone))
        case .selectText:
            Toggle("Select Text", isOn: $model.isSelectingText)
                .help("Select Text (T)")
        case .floatOnTop:
            Toggle("Float on Top", isOn: $model.isAlwaysOnTop)
        case .alwaysShowMenu:
            Toggle("Always Show Toolbar", isOn: $model.isBandAlwaysVisible)
                .help("Always Show Toolbar (⌥⌘T)")
        }
    }
}

/// Lays out every applicable item in each of its forms out of sight and records the widths, so the band can decide
/// what fits without trying arrangements on screen.
struct BandMeasurements: View {
    @Bindable var model: DocumentViewModel
    let items: [BandLayout.Item]
    let menu: OverlayMenuState

    var body: some View {
        ZStack(alignment: .topLeading) {
            measure(.name) { Text(verbatim: model.displayName).font(OverlayBand.nameFont).lineLimit(1) }
            measure(.more) { BandMoreMenu(model: model, overflow: [], header: nil) }
            ForEach(items, id: \.self) { item in
                measure(.item(item, .full)) { BandItemView(model: model, item: item, form: .full) }
                if item.hasCompactForm {
                    measure(.item(item, .compact)) { BandItemView(model: model, item: item, form: .compact) }
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func measure<Content: View>(_ slot: BandSlot, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { width in
                if menu.bandWidths[slot] != width { menu.bandWidths[slot] = width }
            }
    }
}

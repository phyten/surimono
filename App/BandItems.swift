import SurimonoCore
import SwiftUI

/// A measured part of the band: an item in one of its forms, or a part that always stays.
enum BandSlot: Hashable {
    case item(BandLayout.Item, BandLayout.Form)
    case name, more, indicators
}

extension BandLayout.Item {
    var hasCompactForm: Bool {
        switch self {
        case .presentation, .style, .transition, .selectText, .print: true
        default: false
        }
    }

    /// The spacing in front of the item on the band, which the plan counts as part of its width. Print's spacing
    /// belongs to the band's fixed part.
    var bandGap: CGFloat {
        switch self {
        case .formatBadge, .pageIndicator: OverlayBand.titleSpacing
        case .print: 0
        default: OverlayBand.toolSpacing
        }
    }

    /// The items this document can show on the band at this stage.
    static func applicable(for model: DocumentViewModel, stage: OverlayMenuState.Stage) -> [Self] {
        guard stage == .full else { return [.print] }
        // The paper's tools do nothing for a live web page.
        let paper = !model.showsWeb
        return allCases.filter { item in
            switch item {
            case .formatBadge, .floatOnTop, .keepMenuVisible, .print: true
            case .layout, .direction, .scrollAxis, .paperOrientation, .transition: paper
            case .presentation: model.usesHTMLPresentation
            // On the web, only a slide deck has pages to count.
            case .pageIndicator: model.pageIndicator != nil
            case .style: paper && (model.format.usesPrintTheme || model.format.usesHTMLPreset)
            case .cover: paper && model.viewOptions.usesCoverOption
            case .selectText: paper && model.canSelectText
            case .zoom: paper ? model.zoom > 1.001 : abs(model.webZoom - 1) > 0.001
            case .thumbnails: model.imageBundle != nil
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
        case .pageIndicator: PageIndicatorText(model: model)
        case .presentation: PresentationPicker(model: model, showsNames: form == .full)
        case .style: StyleMenu(model: model, showsName: form == .full)
        case .layout: LayoutPicker(model: model)
        case .direction: DirectionPicker(model: model)
        case .scrollAxis: ScrollAxisPicker(model: model)
        case .paperOrientation: PaperOrientationControl(model: model)
        case .transition: TransitionMenu(model: model, showsName: form == .full)
        case .cover:
            Toggle(isOn: model.viewOption(\.showsCoverAlone)) {
                Label("Show Cover Alone", systemImage: "book.closed")
            }
            .toggleStyle(.button).labelStyle(.iconOnly).help("Show Cover Alone")
        case .selectText: SelectTextButton(model: model, showsName: form == .full)
        case .zoom:
            Button {
                model.zoomToFit()
            } label: {
                Text(verbatim: model.zoomPercentage).monospacedDigit()
            }
            .help("Fit to Window")
        case .thumbnails:
            Toggle(isOn: $model.isDrawerOpen) { Label("Thumbnails", systemImage: "sidebar.left") }
                .toggleStyle(.button).labelStyle(.iconOnly).help("Thumbnails")
        case .floatOnTop:
            Toggle(isOn: $model.isAlwaysOnTop) {
                Label("Float on Top", systemImage: model.isAlwaysOnTop ? "pin.fill" : "pin")
            }
            .toggleStyle(.button).labelStyle(.iconOnly).help("Float on Top")
        case .keepMenuVisible:
            Toggle(isOn: $model.isMenuPinned) { Label("Keep Menu Visible", systemImage: "menubar.rectangle") }
                .toggleStyle(.button).labelStyle(.iconOnly).help("Keep Menu Visible")
        case .print: PrintButton(model: model, iconOnly: form == .compact)
        }
    }
}

/// The switch between selecting text and moving the window. A button-style toggle on the borderless band shows only
/// the icon of its label, so this draws the pressed look itself: the accent colour on a pale accent background.
struct SelectTextButton: View {
    @Bindable var model: DocumentViewModel
    let showsName: Bool

    var body: some View {
        Button {
            model.toggleSelectingText()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "character.cursor.ibeam")
                if showsName { Text("Select Text") }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(model.isSelectingText ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background {
                RoundedRectangle(cornerRadius: 5).fill(
                    model.isSelectingText ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Select Text"))
        .accessibilityAddTraits(model.isSelectingText ? .isSelected : [])
        .help("Select Text (T)")
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
        .help(presentation.title)
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
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// What the compact band shows next to the file name: the states that change how the paper behaves.
struct CompactIndicators: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        HStack(spacing: 6) {
            if model.isAlwaysOnTop {
                Image(systemName: "pin.fill").help("Floating on Top")
            }
            if model.isSelectingText {
                Image(systemName: "character.cursor.ibeam").help("Selecting Text")
            }
        }
        .foregroundStyle(.secondary)
    }
}

struct DirectionPicker: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Picker("Direction", selection: model.viewOption(\.direction)) {
            Label("Left to Right · Bound Left", systemImage: "arrow.right").tag(ViewOptions.Direction.leftToRight)
            Label("Right to Left · Bound Right", systemImage: "arrow.left").tag(ViewOptions.Direction.rightToLeft)
        }
        .pickerStyle(.segmented).labelsHidden().labelStyle(.iconOnly).fixedSize()
        .help("Direction")
    }
}

/// Dimmed rather than hidden when the page turn ignores it, so that changing the page turn never reshuffles the band.
struct ScrollAxisPicker: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Picker("Scrolling", selection: model.viewOption(\.scrollAxis)) {
            Label("Vertical", systemImage: "arrow.up.and.down").tag(ViewOptions.ScrollAxis.vertical)
            Label("Horizontal", systemImage: "arrow.left.and.right").tag(ViewOptions.ScrollAxis.horizontal)
        }
        .pickerStyle(.segmented).labelsHidden().labelStyle(.iconOnly).fixedSize()
        .disabled(!model.viewOptions.usesScrollAxis)
        .help("Scrolling")
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

/// The "…" menu: what left the band, in band order, and the view options at the end. It is always on the band, so
/// the popover it anchors never loses its anchor when the band rearranges.
struct BandMoreMenu: View {
    @Bindable var model: DocumentViewModel
    /// The overflowing items; nil when the menu is only measured.
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
            Button("View Options…") { model.isViewOptionsPresented = true }
        } label: {
            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
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
                if model.format.usesPrintTheme {
                    Button("Choose from Samples…") { model.openThemePalette() }
                    Divider()
                }
                StyleMenuItems(model: model)
            } label: {
                let title =
                    model.format.usesHTMLPreset ? String(localized: "HTML Preset") : String(localized: "Print Theme")
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
        case .direction:
            Menu {
                Picker("Direction", selection: model.viewOption(\.direction)) {
                    Text("Left to Right · Bound Left").tag(ViewOptions.Direction.leftToRight)
                    Text("Right to Left · Bound Right").tag(ViewOptions.Direction.rightToLeft)
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                let value =
                    model.viewOptions.direction == .leftToRight
                    ? String(localized: "Left to Right") : String(localized: "Right to Left")
                Text(verbatim: choice(String(localized: "Direction"), value))
            }
        case .paperOrientation: PaperOrientationControl(model: model)
        case .scrollAxis:
            Menu {
                Picker("Scrolling", selection: model.viewOption(\.scrollAxis)) {
                    Text("Vertical").tag(ViewOptions.ScrollAxis.vertical)
                    Text("Horizontal").tag(ViewOptions.ScrollAxis.horizontal)
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                let value =
                    model.viewOptions.scrollAxis == .vertical
                    ? String(localized: "Vertical") : String(localized: "Horizontal")
                Text(verbatim: choice(String(localized: "Scrolling"), value))
            }
            .disabled(!model.viewOptions.usesScrollAxis)
        case .transition:
            Menu {
                TransitionPicker(model: model)
            } label: {
                Text(verbatim: choice(String(localized: "Page Turn"), model.viewOptions.transition.name))
            }
        case .cover:
            Toggle("Show Cover Alone", isOn: model.viewOption(\.showsCoverAlone))
        case .selectText:
            Toggle("Select Text", isOn: $model.isSelectingText)
        case .zoom:
            Button(String(format: String(localized: "Fit to Window (%@)"), model.zoomPercentage)) {
                model.zoomToFit()
            }
        case .thumbnails:
            Toggle("Show Thumbnails", isOn: $model.isDrawerOpen)
        case .floatOnTop:
            Toggle("Float on Top", isOn: $model.isAlwaysOnTop)
        case .keepMenuVisible:
            Toggle("Keep Menu Visible", isOn: $model.isMenuPinned)
        case .formatBadge, .pageIndicator, .print:
            EmptyView()
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
            measure(.indicators) { CompactIndicators(model: model) }
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

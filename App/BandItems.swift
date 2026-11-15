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

    static func applicable(for model: DocumentViewModel) -> [Self] {
        // The paper's tools do nothing for a live web page.
        let paper = !model.showsWeb
        return allCases.filter { item in
            switch item {
            case .formatBadge, .floatOnTop, .print: true
            case .layout, .transition: paper
            case .presentation: model.usesHTMLPresentation
            // On the web, only a slide deck has pages to count.
            case .pageIndicator: model.pageIndicator != nil
            case .style: paper && (model.usesPrintTheme || model.usesHTMLPreset)
            // Whether the band shows them is the arrangement's business; these say only what the document allows.
            case .outline: model.hasOutline
            case .pageTurn: paper && model.pageCount > 1
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
            .help(ShortcutHints.help(String(localized: "Fit to Window"), [.viewZoomFit]))
        case .thumbnails:
            Toggle(isOn: $model.isDrawerOpen) {
                if let binder = model.binder {
                    Text("Documents \(binder.items.count)")
                } else if let bundle = model.imageBundle {
                    Text("Images \(bundle.items.count)")
                }
            }
            .toggleStyle(.button).help(ShortcutHints.help(String(localized: "List"), [.listToggle]))
        case .floatOnTop: FloatOnTopButton(model: model)
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
        .help(ShortcutHints.help(String(localized: "Switch Web or Paper"), [.viewHtmlPresentation]))
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
            .help(ShortcutHints.help(String(localized: "Document Info"), [.viewDocumentInfo]))
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
            // Open is shown in the accent color, as the style button does: indigo belongs to the print screen.
            .foregroundStyle(model.isOutlineShown ? AnyShapeStyle(.tint) : AnyShapeStyle(PrintPalette.ink))
        }
        .fixedSize()
        .help(ShortcutHints.help(String(localized: "Contents"), [.viewOutline]))
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
        .help(
            ShortcutHints.help(
                forward ? String(localized: "Next Page") : String(localized: "Previous Page"),
                [forward ? .readingNext : .readingPrevious]))
    }
}

/// The arrow of the band's drop-down parts. It is drawn here, instead of by the menu, so that a menu and a button that
/// opens a palette show the same arrow.
struct BandMenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(PrintPalette.ink2)
            .accessibilityHidden(true)
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
            HStack(spacing: 3) {
                // The value alone, as the other parts of the band show theirs; the tooltip names the choice.
                if showsName {
                    Label(transition.title, systemImage: transition.symbol).labelStyle(.titleAndIcon)
                } else {
                    Label(transition.title, systemImage: transition.symbol).labelStyle(.iconOnly)
                }
                BandMenuChevron()
            }
            .foregroundStyle(PrintPalette.ink)
        }
        // The borderless-button menu style keeps one image and one title of its label and would drop the arrow.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Page Turn")
    }
}

struct TransitionPicker: View {
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

enum SecondaryViewControl: CaseIterable {
    case direction, scrollAxis, paperOrientation, paperSeries, cover, selectText, alwaysShowMenu

    static func applicable(for model: DocumentViewModel) -> [Self] {
        allCases.filter { item in
            switch item {
            case .direction, .scrollAxis, .paperOrientation: !model.showsWeb
            case .paperSeries: model.offersPaperSeries
            case .cover: !model.showsWeb && model.viewOptions.usesCoverOption
            case .selectText: !model.showsWeb && model.canSelectText
            case .alwaysShowMenu: true
            }
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
            measure(.more) { BandMoreLabel() }
            ForEach(items, id: \.self) { item in
                measure(.item(item, .full)) { BandItemView(model: model, item: item, form: .full) }
                if item.hasCompactForm {
                    measure(.item(item, .compact)) { BandItemView(model: model, item: item, form: .compact) }
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(ViewerWindow.bandControlSize)
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

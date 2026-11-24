import SurimonoCore
import SwiftUI

/// A measured part of the band: an item in one of its forms, or a part that always stays.
enum BandSlot: Hashable {
    case item(BandLayout.Item, BandLayout.Form)
    case name, more, scrubber
}

extension BandLayout.Item {
    func hasCompactForm(for model: DocumentViewModel) -> Bool {
        if self == .formatBadge { return model.latexBadge != nil }
        if self == .thumbnails { return model.imageBundle != nil }
        return hasCompactForm
    }

    var hasCompactForm: Bool {
        switch self {
        case .presentation, .style, .outline, .readingSettings, .transition, .print,
            .readingDirection, .scrollDirection, .paperOrientation, .paperSeries, .cover, .selectText,
            .alwaysShowToolbar, .margins, .printSettings, .ignoreSlides, .beforePrinting, .viewOptions,
            .saveAsFile, .keysAndGestures:
            true
        default: false
        }
    }

    static func applicable(for model: DocumentViewModel) -> [Self] {
        // The paper's tools do nothing for a live web page.
        let paper = !model.showsWeb
        return allCases.filter { item in
            switch item {
            case .formatBadge, .floatOnTop, .showOnAllSpaces, .print, .alwaysShowToolbar, .printSettings, .viewOptions,
                .keysAndGestures:
                true
            case .readingDirection, .scrollDirection, .paperOrientation: paper
            case .paperSeries: model.offersPaperSeries
            case .cover: paper && model.viewOptions.usesCoverOption
            case .selectText: paper && model.canSelectText
            case .margins: model.marginsApply
            case .ignoreSlides: model.detectedSlideDeck != nil && model.usesHTMLPresentation
            case .beforePrinting: model.printIssueCount > 0
            case .saveAsFile: model.canSaveAsFile
            case .layout, .transition: paper
            case .presentation: model.usesHTMLPresentation
            // On the web, only a slide deck has pages to count.
            case .pageIndicator: model.pageIndicator != nil
            case .style: paper && (model.usesPrintTheme || model.usesHTMLPreset)
            // Whether the band shows them is the arrangement's business; these say only what the document allows.
            case .chapter: paper && model.hasOutline && model.chapterEntries.contains { $0.pageIndex != nil }
            case .readingSettings: model.offersOrgReading
            case .outline: model.hasContents && model.imageBundle == nil
            case .pageTurn: paper && model.pageCount > 1
            case .zoom: paper ? model.zoom > 1.001 : abs(model.webZoom - 1) > 0.001
            case .thumbnails: model.imageBundle != nil || model.binder != nil
            }
        }
    }
}

/// One item of the band in the given form.
struct BandItemView: View {
    @Bindable var model: DocumentViewModel
    let item: BandLayout.Item
    let form: BandLayout.Form
    var trailing = false

    var body: some View {
        switch item {
        case .formatBadge:
            // A text whose format was a guess can open again as another; a file's format is the file's.
            if model.textKind != nil {
                TextFormatBadgeMenu(model: model)
            } else if let recognition = model.latexBadge {
                Button {
                    model.isLaTeXRecognitionPresented.toggle()
                } label: {
                    FormatBadge(text: model.formatBadge(in: form))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: recognition.explanation))
            } else {
                FormatBadge(text: model.formatBadge)
            }
        case .readingSettings:
            BandDrawerButton(
                title: "Reading Settings", symbol: "sidebar.right", showsName: form == .full,
                selected: model.isReadingPanelOpen, showsDot: model.orgDocumentReading.changedCount > 0
            ) {
                model.isReadingPanelOpen.toggle()
            }.help("Reading Settings")
                .accessibilityValue(Text("Changed in This Document: \(model.orgDocumentReading.changedCount)"))
        case .chapter: CurrentChapterButton(model: model, trailing: trailing)
        case .pageIndicator: PageIndicatorButton(model: model)
        case .pageTurn: PageTurnButtons(model: model)
        case .outline:
            BandDrawerButton(
                title: "Contents", symbol: "list.bullet", showsName: form == .full, selected: model.isOutlineShown
            ) { model.toggleOutline() }
            .help(ShortcutHints.help(String(localized: "Contents"), [.viewOutline]))
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
            if let binder = model.binder {
                Toggle(isOn: model.controlBinding(get: \.isDrawerOpen, set: { $0.setSideListOpen($1) })) {
                    Text("Documents \(binder.items.count)")
                }
                .toggleStyle(.button).help(ShortcutHints.help(String(localized: "List"), [.listToggle]))
            } else if model.imageBundle != nil {
                BandDrawerButton(
                    title: "Pages Tab", symbol: "square.grid.2x2", showsName: form == .full,
                    selected: model.showsSideList
                ) { model.setSideListOpen(!model.isDrawerOpen) }
                .help(ShortcutHints.help(String(localized: "Pages Tab"), [.listToggle]))
            }
        case .floatOnTop: FloatOnTopButton(model: model)
        case .showOnAllSpaces:
            Toggle(isOn: model.controlBinding(\.showsOnAllSpaces)) {
                Label("Show on All Spaces", systemImage: "rectangle.on.rectangle")
                    .labelStyle(.iconOnly)
                    .selectionRule(model.showsOnAllSpaces)
                    .foregroundStyle(model.showsOnAllSpaces ? PrintPalette.ai : PrintPalette.ink)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .toggleStyle(.button).buttonStyle(.plain).help("Show on All Spaces")
        case .print: PrintButton(model: model, iconOnly: form == .compact)
        case .readingDirection, .scrollDirection, .paperOrientation, .paperSeries, .cover, .selectText,
            .alwaysShowToolbar, .margins, .printSettings, .ignoreSlides, .beforePrinting, .viewOptions,
            .saveAsFile, .keysAndGestures:
            BandAdditionalPart(model: model, item: item, form: form)
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
        .background(CornerRole.control.shape.fill(PrintPalette.press))
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
            .selectionRule(selected, color: .white)
            .background {
                CornerRole.smallControl.shape.fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
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
            HStack(spacing: 4) {
                if !model.bookmarks.isEmpty, !model.showsWeb {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10)).foregroundStyle(PrintPalette.ink2)
                        .opacity(model.isVisiblePageBookmarked ? 1 : 0)
                        .accessibilityHidden(true)
                }
                Text(verbatim: model.pageIndicatorTemplate ?? indicator).hidden()
                    .overlay(alignment: .leading) { Text(verbatim: indicator) }
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(PrintPalette.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(
                    verbatim: model.isVisiblePageBookmarked
                        ? indicator + ", " + String(localized: "Bookmarked") : indicator))
        }
    }
}

/// The sheet belongs to the reading surface so measuring a second button cannot present it twice.
struct PageIndicatorButton: View {
    @Bindable var model: DocumentViewModel
    @State private var hovered = false

    var body: some View {
        if !model.canGoToPage {
            PageIndicatorText(model: model)
        } else {
            Button {
                model.presentGoToPage()
            } label: {
                PageIndicatorText(model: model)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background {
                        CornerRole.control.shape.fill(
                            hovered || model.isGoToPagePresented ? PrintPalette.hover : .clear)
                    }
                    .selectionRule(model.isGoToPagePresented)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .pointerStyle(.link)
            .help(ShortcutHints.help(String(localized: "Go to Page…"), [.documentGoToPage]))
        }
    }
}

private struct BandDrawerButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let showsName: Bool
    let selected: Bool
    var showsDot = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            let label = Label(title, systemImage: symbol)
            HStack(spacing: 3) {
                if showsName { label.labelStyle(.titleAndIcon) } else { label.labelStyle(.iconOnly) }
                if showsDot { Circle().frame(width: 4, height: 4).accessibilityHidden(true) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? Color.white : PrintPalette.ink)
            .selectionRule(selected, color: .white)
            .background {
                CornerRole.smallControl.shape.fill(
                    selected ? PrintPalette.aiControl : (hovered ? PrintPalette.hover : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                // A borderless button takes the window's tint, and indigo on the band means "open" or "chosen".
                .foregroundStyle(PrintPalette.ink)
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
            .font(.system(size: 10, weight: .semibold))
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
        .accessibilityLabel(Text("Page Turn"))
        .accessibilityValue(Text(model.viewOptions.transition.title))
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

/// Lays out every applicable item in each of its forms out of sight and records the widths, so the band can decide
/// what fits without trying arrangements on screen.
struct BandMeasurements: View {
    @Bindable var model: DocumentViewModel
    let items: [BandLayout.Item]
    let menu: OverlayMenuState

    var body: some View {
        ZStack(alignment: .topLeading) {
            measure(.name) { Text(verbatim: model.displayName).font(OverlayBand.nameFont).lineLimit(1) }
            if model.offersScrubber {
                measure(.scrubber) {
                    PageScrubberRail(current: 0, hover: nil, ticks: []).frame(width: BandLayout.scrubberMinimum)
                }
            }
            measure(.more) { BandMoreButton { EmptyView() } }
            ForEach(items, id: \.self) { item in
                measure(.item(item, .full)) { BandItemView(model: model, item: item, form: .full) }
                if item == .formatBadge, model.offersLaTeXComposition, model.latexComposition != .document {
                    measure(.item(item, .withoutSuffix)) {
                        BandItemView(model: model, item: item, form: .withoutSuffix)
                    }
                }
                if item.hasCompactForm(for: model) {
                    measure(.item(item, .compact)) { BandItemView(model: model, item: item, form: .compact) }
                }
            }
        }
        .cornerButton(model.preferences.corners, .borderless)
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

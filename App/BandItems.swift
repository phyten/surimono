import SurimonoCore
import SwiftUI

/// A measured part of the band: an item in one of its forms, or a part that always stays.
enum BandSlot: Hashable {
    case item(BandLayout.Item, BandLayout.Form)
    case name, more, scrubber
    /// The current chapter's whole title, and the chapter part around a title of no width.
    case chapterTitle, chapterChrome
}

extension BandLayout.Item {
    func hasCompactForm(for model: DocumentViewModel) -> Bool {
        if self == .formatBadge { return model.latexBadge != nil }
        if self == .thumbnails { return model.imageBundle != nil }
        return hasCompactForm
    }

    func hasIntermediateForm(for model: DocumentViewModel) -> Bool {
        switch self {
        case .formatBadge: model.offersLaTeXComposition && model.latexComposition != .document
        case .pageIndicator: model.previewPageCountForBand != nil
        default: false
        }
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
            case .cover: paper && (model.viewOptions.usesCoverOption || model.viewOptions.showsCoverAlone)
            case .selectText: paper && model.canSelectText
            case .margins: model.marginsApply
            case .ignoreSlides: model.detectedSlideDeck != nil && model.usesHTMLPresentation
            case .beforePrinting: model.printIssueCount > 0 || model.previewPageCountForBand != nil
            case .saveAsFile: model.canSaveAsFile
            case .layout, .transition: paper
            case .presentation: model.usesHTMLPresentation
            // On the web, only a slide deck has pages to count.
            case .pageIndicator: model.pageIndicator != nil
            case .style: paper && (model.usesPrintTheme || model.usesHTMLPreset)
            // Whether the band shows them is the arrangement's business; these say only what the document allows.
            case .chapter: paper && model.hasOutline && model.chapterEntries.contains { $0.pageIndex != nil }
            case .readingSettings: model.offersReadingPanel
            case .outline: (model.hasContents || model.reservesPreviewControls) && model.imageBundle == nil
            case .pageTurn: paper && (model.paperPageCount > 1 || model.reservesPreviewControls)
            case .zoom: paper ? model.zoom > 1.001 : abs(model.webZoom - 1) > 0.001
            case .thumbnails: model.imageBundle != nil || model.binder != nil
            }
        }
    }
}

/// One item of the band in the given form.
struct BandItemView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: DocumentViewModel
    let item: BandLayout.Item
    let form: BandLayout.Form
    var trailing = false
    var choiceHint = ""

    var body: some View { control.environment(\.bandPlateCorners, model.preferences.corners) }

    @ViewBuilder private var control: some View {
        switch item {
        case .formatBadge:
            // A text whose format was a guess can open again as another; a file's format is the file's.
            if model.textKind != nil {
                TextFormatBadgeMenu(model: model)
            } else if let recognition = model.latexBadge {
                Button {
                    model.isLaTeXRecognitionPresented.toggle()
                } label: {
                    Text(verbatim: model.formatBadge(in: form))
                }
                .buttonStyle(BandStatePlate(on: model.isLaTeXRecognitionPresented))
                .accessibilityLabel(Text(item.bandAccessibilityName))
                .accessibilityValue(Text(verbatim: recognition.label))
                .accessibilityHint(Text(verbatim: recognition.explanation))
            } else {
                FormatBadge(text: model.formatBadge)
            }
        case .readingSettings:
            BandDrawerButton(
                item: item, showsName: form == .full,
                selected: model.isReadingPanelOpen, hasChanges: model.readingChangedCount > 0
            ) {
                model.isReadingPanelOpen.toggle()
            }
        case .chapter: CurrentChapterButton(model: model, trailing: trailing)
        case .pageIndicator: PageIndicatorButton(model: model, showsStatusName: form == .full)
        case .pageTurn: PageTurnButtons(model: model)
        case .outline:
            BandDrawerButton(
                item: item, showsName: form == .full,
                selected: model.isOutlineShown
            ) { model.toggleOutline() }
            .disabled(!model.hasContents)
        case .presentation: PresentationPicker(model: model, showsNames: form == .full, hint: choiceHint)
        case .style:
            StyleMenu(model: model, showsName: form == .full).accessibilityLabel(
                Text(model.bandStyleAccessibility.name))
        case .layout: LayoutPicker(model: model, hint: choiceHint)
        case .transition: TransitionMenu(model: model, showsName: form == .full)
        case .zoom:
            Button {
                model.zoomToFit()
            } label: {
                Text(verbatim: model.zoomPercentage).monospacedDigit()
            }
            .accessibilityLabel(Text(item.bandAccessibilityName))
            .accessibilityValue(Text(verbatim: BandAccessibility.zoomValue(model.displayedZoom, locale: locale)))
        case .thumbnails:
            if let binder = model.binder {
                Button {
                    model.setSideListOpen(!model.isDrawerOpen)
                } label: {
                    Text(BandAccessibility.documents(binder.items.count))
                }
                .buttonStyle(BandStatePlate(on: model.showsSideList))
            } else if model.imageBundle != nil {
                BandDrawerButton(
                    item: item, showsName: form == .full,
                    selected: model.showsSideList
                ) { [weak model] in
                    guard let model, !model.isWindowClosed else { return }
                    model.setSideListOpen(!model.isDrawerOpen)
                }
            }
        case .floatOnTop, .showOnAllSpaces:
            let binding =
                item == .floatOnTop ? model.controlBinding(\.isAlwaysOnTop) : model.controlBinding(\.showsOnAllSpaces)
            Toggle(isOn: binding) { BandStateGlyph(item: item, on: binding.wrappedValue) }
                .toggleStyle(BandSwitchStyle(compact: true, name: item.bandAccessibilityName))
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
    let hint: String

    var body: some View {
        HStack(spacing: 1) {
            ForEach(HTMLPresentation.allCases, id: \.self) { presentation in
                segment(presentation)
            }
        }
        .padding(1)
        .background(CornerRole.control.shape.fill(PrintPalette.bandSegmentTrack))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(BandLayout.Item.presentation.bandAccessibilityName))
    }

    private func segment(_ presentation: HTMLPresentation) -> some View {
        let selected = model.htmlPresentation == presentation
        let label = HStack(spacing: 4) {
            Image(systemName: presentation.symbol)
            if showsNames { Text(presentation.title) }
        }
        return Button {
            model.setHTMLPresentation(presentation)
        } label: {
            label
        }
        .buttonStyle(BandStatePlate(on: selected, compact: !showsNames))
        .modifier(BandSegmentInteraction(segment: presentation == .paper ? .paper : .web))
        .accessibilityLabel(Text(presentation.title))
        .accessibilityHint(Text(verbatim: hint))
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    var showsStatusName: Bool
    static let preparingHelp = String(
        localized: "Preparing the whole document — printing and Contents become available when it is ready.")

    var body: some View {
        if let indicator = model.pageIndicator {
            HStack(spacing: 4) {
                if !model.bookmarks.isEmpty, !model.showsWeb {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10)).foregroundStyle(PrintPalette.ink2)
                        .opacity(model.isVisiblePageBookmarked ? 1 : 0)
                        .accessibilityHidden(true)
                }
                ZStack(alignment: .leading) {
                    if let prefixCount = model.previewPageCountForBand {
                        // Hold the larger of the two labels across publication, including in the icon-only form.
                        HStack(spacing: 4) {
                            statusMark
                            Text(
                                verbatim: PageIndicator.widestText(
                                    pageCount: prefixCount, layout: model.viewOptions.layout) + "+")
                        }.hidden()
                        // Input bytes generously bound the digits needed for pages of this text or CSV.
                        Text(
                            verbatim: PageIndicator.widestText(
                                pageCount: model.data.count, layout: model.viewOptions.layout)
                        ).hidden()
                    }
                    Text(verbatim: model.pageIndicatorTemplate ?? indicator).hidden()
                    HStack(spacing: 4) {
                        if model.isPreparingWholeDocument {
                            statusMark.overlay(alignment: .leading) {
                                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                            }
                        }
                        Text(verbatim: indicator)
                    }
                }
                .font(.system(size: 11)).monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: model.pageIndicatorAccessibilityValue))
        }
    }

    private var statusMark: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 12, height: 12)
            if showsStatusName { Text("Preparing") }
        }
    }
}

extension DocumentViewModel {
    fileprivate var pageIndicatorAccessibilityValue: String {
        BandAccessibility.pageIndicator(
            pageIndicator, bookmarked: isVisiblePageBookmarked, preparing: isPreparingWholeDocument)
    }
}

/// The sheet belongs to the reading surface so measuring a second button cannot present it twice.
struct PageIndicatorButton: View {
    @Bindable var model: DocumentViewModel
    var showsStatusName: Bool

    var body: some View {
        if !model.canGoToPage {
            PageIndicatorText(model: model, showsStatusName: showsStatusName)
                .padding(.horizontal, model.reservesPreviewControls ? 7 : 0)
        } else {
            Button {
                model.presentGoToPage()
            } label: {
                PageIndicatorText(model: model, showsStatusName: showsStatusName)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
    }
}

private struct BandDrawerButton: View {
    let item: BandLayout.Item
    let showsName: Bool
    let selected: Bool
    var hasChanges = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                BandStateGlyph(item: item, on: selected)
                if showsName { Text(item.bandAccessibilityName) }
            }
        }
        .buttonStyle(BandStatePlate(on: selected, compact: !showsName, hasChanges: hasChanges))
        .fixedSize()
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

    static func title(forward: Bool) -> LocalizedStringKey { forward ? "Next Page" : "Previous Page" }

    private func turn(_ symbol: String, forward: Bool) -> some View {
        let title = Self.title(forward: forward)
        return Button {
            model.paper.turnPage(forward: forward)
        } label: {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(width: 22, height: 22)
                .contentShape(Rectangle())
                // A borderless button takes the window's tint, and indigo on the band means "open" or "chosen".
                .foregroundStyle(PrintPalette.ink)
        }
        .disabled(!model.canTurnPaperPage(forward: forward))
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(verbatim: BandHintContent.turn(forward: forward, model: model).accessibilityHint))
        .bandTurnFocus(forward: forward)

    }
}

/// The arrow of the band's drop-down parts. It is drawn here, instead of by the menu, so that a menu and a button that
/// opens a palette show the same arrow.
struct BandMenuChevron: View {
    var inheritsInk = false
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(inheritsInk ? AnyShapeStyle(.foreground) : AnyShapeStyle(PrintPalette.ink2))
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
        .accessibilityLabel(Text(BandLayout.Item.transition.bandAccessibilityName))
        .accessibilityValue(Text(model.viewOptions.transition.title))
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
    static let isHiddenFromAccessibility = true

    @Bindable var model: DocumentViewModel
    let items: [BandLayout.Item]
    let menu: OverlayMenuState

    var body: some View {
        ZStack(alignment: .topLeading) {
            measure(.name) { Text(verbatim: model.displayName).font(OverlayBand.nameFont).lineLimit(1) }
            if model.showsScrubberSlot {
                measure(.scrubber) {
                    PageScrubberContainer {
                        PageScrubberRail(current: 0, hover: nil, ticks: []).frame(width: BandLayout.scrubberMinimum)
                    }
                }
            }
            measure(.more) { BandMoreButton { EmptyView() } }
            if items.contains(.chapter) {
                // The widest whole title, however long, rather than the current page's: the plan decides the frame
                // it gets, the same on every page.
                measure(.chapterTitle) {
                    CurrentChapterButton.titleText(CurrentChapterButton.widestTitle(of: model)).lineLimit(1)
                }
                measure(.chapterChrome) { CurrentChapterButton(model: model, trailing: false, titleWidth: 0) }
            }
            ForEach(items, id: \.self) { item in
                measure(.item(item, .full)) { BandItemView(model: model, item: item, form: .full) }
                if item.hasIntermediateForm(for: model) {
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
        .environment(\.bandHints, nil)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(Self.isHiddenFromAccessibility)
    }

    private func measure<Content: View>(_ slot: BandSlot, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { [menu] width in
                if menu.bandWidths[slot] != width { menu.bandWidths[slot] = width }
            }
    }
}

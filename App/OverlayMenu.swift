import AppKit
import Observation
import SurimonoCore
import SwiftUI

@Observable
final class OverlayMenuState {
    enum Stage { case hidden, full }

    static let hideDelay = Duration.seconds(1)
    static let revealZone = ViewerWindow.bandHeight

    private(set) var stage: Stage = .hidden
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var pointerY: CGFloat?
    @ObservationIgnored private var menuTracking = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The window's content height; the bottom band's room is measured from it.
    @ObservationIgnored var contentHeight: CGFloat = 0
    @ObservationIgnored var hasBottomBand = false
    /// The room the bands take at the top and bottom of the content, beside the paper.
    @ObservationIgnored var topRoom: CGFloat = 0
    @ObservationIgnored var bottomRoom: CGFloat = 0
    /// The top band's height, which is also how far into the paper's top edge the pointer reveals it.
    @ObservationIgnored var topZone: CGFloat = OverlayMenuState.revealZone
    /// The narrowest width the bands can lay out, for the window once it is known.
    @ObservationIgnored var minimumWidth: CGFloat = 0
    /// The window's traffic lights as last read, which the top band lines up with; `hasReadTrafficLights` tells a
    /// window without them (full screen) from one not read yet.
    var trafficLights: TrafficLights?
    var hasReadTrafficLights = false
    // Measurements outlive the band so it reopens with the tools that fit.
    var bandWidths: [BandSlot: CGFloat] = [:]
    var bandWidth: CGFloat = 0
    var isHolding = false {
        didSet { updateHideTimer() }
    }

    init() {
        // Pop-up tracking takes the pointer away from the band until the menu closes.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuTracking += 1
                    self?.updateHideTimer()
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuTracking = max(self.menuTracking - 1, 0)
                    self.updateHideTimer()
                }
            },
        ]
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        hideTask?.cancel()
    }

    private var isHeld: Bool { isHolding || menuTracking > 0 }
    /// The edge of the paper under a hidden band, and the band's room with that edge while it shows. A band that makes
    /// room for itself moves the paper's edge away from a still pointer, which therefore stays inside; and the band
    /// hides only once the pointer is beyond both, where giving the room back cannot bring the edge under it again.
    var isPointerOverBand: Bool {
        guard let pointerY else { return false }
        if pointerY >= 0, pointerY <= topRoom + topZone { return true }
        return hasBottomBand && pointerY >= contentHeight - bottomRoom - Self.revealZone && pointerY <= contentHeight
    }

    func pointerMoved(to point: CGPoint) {
        pointerY = point.y
        if isPointerOverBand {
            showFull()
        } else {
            updateHideTimer()
        }
    }

    func pointerExited() {
        pointerY = nil
        updateHideTimer()
    }

    func pageTurned() {
        guard !isHeld, !isPointerOverBand else { return }
        hideNow()
    }

    func toggle() {
        if stage == .full { hideNow() } else { showFull() }
    }

    func showFull() {
        cancelHide()
        stage = .full
    }

    func hideNow() {
        cancelHide()
        stage = .hidden
    }

    func hideForEscape(alwaysVisible: Bool) -> Bool {
        guard stage != .hidden, !alwaysVisible else { return false }
        hideNow()
        return true
    }

    private func updateHideTimer() {
        guard !isHeld, !isPointerOverBand else {
            cancelHide()
            return
        }
        // Movement elsewhere in the window must not postpone the deadline for leaving the band.
        guard stage != .hidden, hideTask == nil else { return }
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.hideDelay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // Kept by then (back on the band, or held), the band needs a new deadline the next time it is left.
            guard !isHeld, !isPointerOverBand else {
                hideTask = nil
                return
            }
            hideNow()
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }
}

/// What each band shows at the current width, from the saved arrangement of the band's parts.
struct BandPlans {
    let resolved: BandResolvedPlan

    var top: BandRowPlan { resolved.top }
    /// Nil when the arrangement has no bottom band.
    var bottom: BandRowPlan? { resolved.bottom }
    /// The narrowest window whose bands still hold what never leaves them: the traffic lights, "…" and Print.
    var minimumWidth: CGFloat { max(top.minimumWidth, bottom?.minimumWidth ?? 0) }

    /// The band a part is on now, or nil when it is not in use, cannot be used here or did not fit.
    func band(of item: BandLayout.Item) -> VerticalEdge? { resolved.band(of: item) }

    init(model: DocumentViewModel, menu: OverlayMenuState) {
        let measured = menu.bandWidths
        let applicable = BandLayout.Item.applicable(for: model)
        var widths: [BandLayout.Item: BandLayout.Widths] = [:]
        for item in applicable {
            widths[item] = BandLayout.Widths(
                full: measured[.item(item, .full)] ?? 0,
                compact: item.hasCompactForm(for: model) ? measured[.item(item, .compact)] ?? 0 : nil,
                withoutSuffix: item == .formatBadge && model.offersLaTeXComposition
                    && model.latexComposition != .document
                    ? measured[.item(item, .withoutSuffix)] : nil)
        }
        let lights = OverlayBand.lights(model: model, menu: menu)
        // Separator cost includes the line and its following gap; the plan adds the preceding gap only when drawn.
        let metrics = BandMetrics(
            topFixed: OverlayBand.fixedWidth(lights: lights) + (measured[.more] ?? 0),
            bottomFixed: BottomBand.fixedWidth, separator: 1 + OverlayBand.toolSpacing,
            titleGap: OverlayBand.titleSpacing, toolGap: OverlayBand.toolSpacing, outerGap: OverlayBand.spacing)
        // Until the band has been laid out once, its width is unknown: show everything rather than guess.
        resolved = BandLayout.resolve(
            arrangement: model.preferences.activeBandArrangement, mode: model.menuArrangement,
            availableItems: Set(applicable),
            measurements: BandMeasurementsValue(items: widths, name: measured[.name] ?? .greatestFiniteMagnitude),
            metrics: metrics, availableWidth: menu.bandWidth > 0 ? menu.bandWidth : .greatestFiniteMagnitude)
    }
}

/// The place of one band: its own room beside the paper while it always shows, or the paper's edge it lies over while
/// it shows on pointing. What the band leaves empty moves the window. A hidden band draws nothing, so the paper under
/// it stays in view and takes the clicks.
struct BandZone<Content: View>: View {
    let edge: VerticalEdge
    let isShown: Bool
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            if isShown {
                WindowDragArea()
                content
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background {
            if isShown { PrintPalette.raised }
        }
        .overlay(alignment: edge == .top ? .bottom : .top) {
            if isShown { Rectangle().fill(PrintPalette.line).frame(height: DisplayAccessibility.hairline) }
        }
    }
}

/// An empty place that moves the window, as a title bar does.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

/// Where the band's parts and "…" stand in the window, for the popovers that hang off them. Only the parts on the bands
/// record their place: `BandMeasurements` draws another copy of each out of sight.
@Observable
final class BandAnchors {
    enum Anchor: Hashable {
        case item(BandLayout.Item)
        case more
    }

    /// The view mode's whole content, which the bands and the popovers' host share.
    nonisolated static let coordinateSpace = "viewMode"

    var frames: [Anchor: CGRect] = [:]
    /// The plan the window's bands drew last. A part's recorded place counts only while this has it on a band.
    @ObservationIgnored var plan: BandResolvedPlan?
}

extension BandResolvedPlan {
    /// The band a part is on, or nil when it is not in use, cannot be used here or did not fit.
    func band(of item: BandLayout.Item) -> VerticalEdge? {
        if top.forms[item] != nil { return .top }
        return bottom?.forms[item] != nil ? .bottom : nil
    }
}

extension View {
    /// Records where a part of the band stands, for the popover that hangs off it.
    func bandAnchor(_ anchor: BandAnchors.Anchor, in anchors: BandAnchors) -> some View {
        onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(BandAnchors.coordinateSpace))
        } action: { frame in
            if anchors.frames[anchor] != frame { anchors.frames[anchor] = frame }
        }
    }
}

/// The popovers of the band's parts: the table of contents, the document's figures and the view options. One host for
/// the window holds them all, outside the bands: a part that folds into "…", moves to the other band or comes back
/// after a resize changes only where its popover points, never which view presents it, so an open popover neither
/// closes nor shows twice. A part that is not on a band lends its popover to "…".
struct BandPresentationHost: View {
    @Bindable var model: DocumentViewModel
    let plans: BandPlans

    /// Where a popover points: a part actually on a band, or "…" when no displayed part frame is available.
    /// A nil rect means "…" has not been laid out yet.
    struct Placement: Equatable {
        var rect: CGRect?
        var arrowEdge: Edge
    }

    static func placement(
        of item: BandLayout.Item?, plans: BandPlans, frames: [BandAnchors.Anchor: CGRect]
    ) -> Placement {
        if let item, let band = plans.band(of: item), let frame = frames[.item(item)] {
            // Under a part of the top band, above a part of the bottom band.
            return Placement(rect: frame, arrowEdge: band == .bottom ? .top : .bottom)
        }
        return Placement(rect: frames[.more], arrowEdge: .bottom)
    }

    var body: some View {
        // One popover to a view: two on the same view would compete for its presentation.
        ZStack {
            let outline = placement(.outline)
            let badge = placement(.formatBadge)
            Color.clear.popover(
                isPresented: $model.isLaTeXRecognitionPresented, attachmentAnchor: anchor(badge),
                arrowEdge: badge.arrowEdge
            ) {
                if let recognition = model.latexBadge {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: recognition.explanation)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text("Line and page breaks may differ from LaTeX output.")
                        ForEach(recognition.slideNotes, id: \.self) { note in
                            Text(verbatim: note)
                        }
                        if model.offersLaTeXComposition {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: PrintModeText.string("LaTeX Layout", language: model.language))
                                    .font(.caption)
                                LaTeXCompositionPicker(model: model)
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                Text(
                                    verbatim: PrintModeText.string(
                                        model.latexComposition.detailKey, language: model.language))
                            }
                            .padding(.top, 6)
                        }
                    }
                    .font(.callout)
                    .frame(width: 440, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                }
            }
            let figures = placement(.pageIndicator)
            let more = placement(.viewOptions)
            Color.clear.popover(
                isPresented: $model.isOutlinePresented, attachmentAnchor: anchor(outline),
                arrowEdge: outline.arrowEdge
            ) {
                OutlinePopover(model: model)
            }
            Color.clear.popover(
                isPresented: $model.isFiguresPresented, attachmentAnchor: anchor(figures),
                arrowEdge: figures.arrowEdge
            ) {
                DocumentFiguresPopover(model: model)
            }
            Color.clear.popover(
                isPresented: $model.isViewOptionsPresented, attachmentAnchor: anchor(more),
                arrowEdge: more.arrowEdge
            ) {
                ViewOptionsPopover(model: model)
            }
        }
        .allowsHitTesting(false)
    }

    private func placement(_ item: BandLayout.Item?) -> Placement {
        Self.placement(of: item, plans: plans, frames: model.bandAnchors.frames)
    }

    private func anchor(_ placement: Placement) -> PopoverAttachmentAnchor {
        placement.rect.map { .rect(.rect($0)) } ?? .point(.topTrailing)
    }
}

/// One part on a band, which records its place for the popovers and the image drop.
struct BandPart: View {
    @Bindable var model: DocumentViewModel
    let item: BandLayout.Item
    let form: BandLayout.Form
    var trailing = false

    var body: some View {
        BandItemView(model: model, item: item, form: form, trailing: trailing)
            .bandAnchor(.item(item), in: model.bandAnchors)
            // Only the part on the band: `BandMeasurements` draws another one out of sight.
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { frame in
                if item == .thumbnails { model.drop.listButtonFrame = frame }
            }
    }
}

/// The thin line between parts of a band. It draws only the line: the room around it is the plan's
/// (`BandRowGeometry.separatorWidth`), so the band and anything that shows a band's arrangement can share it.
struct BandSeparator: View {
    var body: some View {
        Rectangle().fill(PrintPalette.line2).frame(width: 1, height: 16)
    }
}

/// The parts of one zone in their saved order, with the separators where the plan put them
/// (`BandRowGeometry.separatorsBefore`). A layout in the Standard order keeps the stacks' own spacing, so it looks as the
/// bands always have; any other order spaces each part and separator as the plan counted them, and the caller's stack
/// then has no spacing of its own.
@ViewBuilder
func bandParts(_ items: [BandLayout.Item], row: BandRowPlan, model: DocumentViewModel) -> some View {
    let geometry = row.geometry
    ForEach(items, id: \.self) { item in
        let separated = geometry.separatorsBefore.contains(item)
        let form = row.forms[item] ?? .full
        if geometry.usesStandardSpacing {
            if separated { BandSeparator() }
            BandPart(model: model, item: item, form: form, trailing: row.trailing.contains(item))
        } else {
            let gap = geometry.gapsBefore[item] ?? 0
            HStack(spacing: 0) {
                if separated { BandSeparator().padding(.leading, gap) }
                // A separator's width is its line and the room after it.
                BandPart(model: model, item: item, form: form, trailing: row.trailing.contains(item))
                    .padding(.leading, separated ? max(geometry.separatorWidth - 1, 0) : gap)
            }
        }
    }
}

/// The top band of the view mode window. The file name stays first and "…" at the trailing end; the parts of the two
/// top zones stand around a flexible space in their saved order, as many as fit, and the rest fold into "…"
/// (`BandLayout.resolve`). Popovers hang off `BandPresentationHost`, so none closes when the band rearranges.
struct OverlayBand: View {
    @Bindable var model: DocumentViewModel
    let menu: OverlayMenuState
    let plans: BandPlans

    static let spacing: CGFloat = 10
    static let toolSpacing: CGFloat = 8
    static let titleSpacing: CGFloat = 6
    static let nameFont = Font.system(size: 13, weight: .semibold)
    /// Where the traffic lights end in a window without a toolbar, for a window that has none of its own to measure.
    private static let fallbackLightsTrailing: CGFloat = 69
    private static let spacerMinimum: CGFloat = 8
    private static let trailingPadding: CGFloat = 8

    /// The traffic lights the band lines up with: the last reading, or the window's own until the first one comes.
    static func lights(model: DocumentViewModel, menu: OverlayMenuState) -> TrafficLights? {
        menu.hasReadTrafficLights ? menu.trafficLights : model.window.flatMap { TrafficLights(window: $0) }
    }

    /// The room before the title: the traffic lights and the gap after them, less the stack's spacing.
    static func lightsRoom(_ lights: TrafficLights?) -> CGFloat {
        (lights?.titleLeading ?? fallbackLightsTrailing + TrafficLights.titleGap) - spacing
    }

    /// What always stays apart from the "…" button: the room for the traffic lights, spacing and padding.
    static func fixedWidth(lights: TrafficLights?) -> CGFloat {
        lightsRoom(lights) + spacerMinimum + trailingPadding + spacing * 4
    }

    var body: some View {
        let row = plans.top
        let lights = Self.lights(model: model, menu: menu)
        // Print last on the right stays after "…", where it has always been.
        let docksPrint = row.geometry.moreDock == .beforePrint
        HStack(spacing: Self.spacing) {
            // Room for the traffic lights.
            Color.clear.frame(width: Self.lightsRoom(lights), height: 1)
            title(row)
            Spacer(minLength: Self.spacerMinimum)
            tools(docksPrint ? row.trailing.filter { $0 != .print } : row.trailing, row: row)
            if docksPrint, row.geometry.usesStandardSpacing, !row.geometry.separatorsBefore.contains(.print) {
                BandPart(model: model, item: .print, form: row.forms[.print] ?? .full)
            } else if docksPrint {
                HStack(spacing: row.geometry.usesStandardSpacing ? Self.toolSpacing : 0) {
                    // Print lives outside the tools stack, but its reader-placed separator still belongs to the zone.
                    bandParts([.print], row: row, model: model)
                }
            }
        }
        .padding(.trailing, Self.trailingPadding)
        // Every part sits on the traffic lights' centre line. The band is as tall as twice that line, so this moves
        // nothing unless the band had to be taller than the title bar AppKit centres the buttons in.
        .offset(y: TrafficLights.lineOffset(lights, barHeight: model.topBandHeight))
    }

    private func title(_ row: BandRowPlan) -> some View {
        HStack(spacing: row.geometry.usesStandardSpacing ? Self.titleSpacing : 0) {
            if row.showsName {
                Text(verbatim: model.displayName)
                    .font(Self.nameFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: row.nameWidth + 0.5, alignment: .leading)
                    .help(model.fileURL?.path ?? model.displayName)
            }
            bandParts(row.leading, row: row, model: model)
        }
        .cornerButton(model.preferences.corners, .borderless)
        .controlSize(ViewerWindow.bandControlSize)
    }

    private func tools(_ items: [BandLayout.Item], row: BandRowPlan) -> some View {
        let spacing = row.geometry.usesStandardSpacing ? Self.toolSpacing : 0
        return HStack(spacing: spacing) {
            HStack(spacing: spacing) { bandParts(items, row: row, model: model) }.fixedSize()
            BandMoreMenu(model: model)
                .bandAnchor(.more, in: model.bandAnchors)
                // The plan's gap before "…"; in the Standard order the stack's spacing draws it instead.
                .padding(.leading, row.geometry.moreGap)
        }
        .cornerButton(model.preferences.corners, .borderless)
        .controlSize(ViewerWindow.bandControlSize)
        // The plan already made the tools fit; without this the stack would squeeze a label to make room for the
        // spacer instead of leaving the slack to it.
        .fixedSize()
    }

}

/// The band under the paper when the menu is split: the bottom-left zone's parts on the left, the bottom-right zone's
/// on the right, in their saved order.
struct BottomBand: View {
    @Bindable var model: DocumentViewModel
    let row: BandRowPlan

    private static let padding: CGFloat = 10
    private static let spacerMinimum: CGFloat = 8
    static var fixedWidth: CGFloat { padding * 2 + spacerMinimum }

    var body: some View {
        let spacing = row.geometry.usesStandardSpacing ? OverlayBand.toolSpacing : 0
        HStack(spacing: spacing) {
            HStack(spacing: spacing) { bandParts(row.leading, row: row, model: model) }.fixedSize()
            Spacer(minLength: Self.spacerMinimum)
            bandParts(row.trailing, row: row, model: model)
        }
        .cornerButton(model.preferences.corners, .borderless)
        // The same size as the top band's, whose widths the same measurements give.
        .controlSize(ViewerWindow.bandControlSize)
        .padding(.horizontal, Self.padding)
    }
}

struct FormatBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(PrintPalette.ink2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(CornerRole.badge.shape.fill(PrintPalette.press))
    }
}

struct PrintButton: View {
    @Bindable var model: DocumentViewModel
    /// The narrowest band keeps Print as an icon rather than dropping it: printing takes two steps at most.
    var iconOnly = false
    /// The button's word, without the ellipsis of the File menu's item: on the band the dots read as a word cut short,
    /// and the printer icon beside it already says that a screen follows.
    static let titleKey = "Print"

    var body: some View {
        Button {
            model.performPrintCommand()
        } label: {
            if iconOnly {
                Label(LocalizedStringKey(Self.titleKey), systemImage: "printer").labelStyle(.iconOnly)
            } else {
                Label(LocalizedStringKey(Self.titleKey), systemImage: "printer").labelStyle(.titleAndIcon)
            }
        }
        .cornerButton(model.preferences.corners, .print)
        // Vermilion is the color of printing, whatever accent color the Mac is set to.
        .tint(PrintPalette.shu)
        .controlSize(ViewerWindow.bandControlSize)
        // The file name gives way to the one button that must always show in full.
        .fixedSize()
        .help(ShortcutHints.help(String(localized: "Open the print screen"), [.documentPrint]))
    }
}

/// Print themes for text formats and cleanup presets for HTML; PDFs and images print as they are. Narrow windows show
/// the icon alone.
struct StyleMenu: View {
    @Bindable var model: DocumentViewModel
    let showsName: Bool

    var body: some View {
        if model.usesPrintTheme, model.binder == nil {
            // Print themes open the palette of samples beside the paper, where it leaves the paper in view.
            Button {
                model.openThemePalette()
            } label: {
                HStack(spacing: 3) {
                    label
                    BandMenuChevron()
                }
                .foregroundStyle(
                    model.isThemePalettePresented ? AnyShapeStyle(PrintPalette.ai) : AnyShapeStyle(PrintPalette.ink)
                )
                .selectionRule(model.isThemePalettePresented)
            }
            .fixedSize()
            .help("Style")
        } else {
            Menu {
                StyleMenuItems(model: model)
            } label: {
                HStack(spacing: 3) {
                    label
                    BandMenuChevron()
                }
                .foregroundStyle(PrintPalette.ink)
            }
            // The borderless-button menu style keeps one image and one title of its label and would drop the arrow.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.usesHTMLPreset ? LocalizedStringKey("HTML Preset") : LocalizedStringKey("Style"))
        }
    }

    @ViewBuilder private var label: some View {
        // "textformat" is drawn as kana in Japanese and as other letters elsewhere, so it does not match the line icons
        // beside it. The palette symbol is the same in every language.
        let label = Label(model.styleName, systemImage: symbol)
        Group {
            if showsName { label.labelStyle(.titleAndIcon) } else { label.labelStyle(.iconOnly) }
        }
        .accessibilityValue(model.usesHTMLPreset && model.isSmartRemovalEnabled ? Text("Smart Removal") : Text(""))
    }

    /// For HTML, Smart Removal on the preset shows as the wand's stars rather than as words beside its name.
    private var symbol: String {
        guard model.usesHTMLPreset else { return "paintpalette" }
        return model.isSmartRemovalEnabled ? "wand.and.stars" : "wand.and.rays"
    }
}

extension DocumentViewModel {
    /// The chosen print theme, or for HTML the cleanup preset (Smart Removal shows in the band's icon).
    var styleName: String {
        if usesHTMLPreset && !usesPrintTheme {
            return library.presets.first { $0.id == presetID }?.displayName(language: language) ?? presetID
        }
        let theme = library.themes.first { $0.id == themeID }?.displayName(language: language) ?? themeID
        return usesPrintTheme && textScale != 1 ? theme + " · " + textScalePercentage : theme
    }

    var textScalePercentage: String { "\(TextScale.percent(textScale))%" }

    var zoomPercentage: String { "\(Int(((showsWeb ? webZoom : zoom) * 100).rounded()))%" }
}

struct StyleMenuItems: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if model.usesPrintTheme {
            ThemeMenuContent(model: model)
            TextSizeMenuItems(model: model)
        }
        if model.usesHTMLPreset {
            Picker("HTML Preset", selection: $model.presetID) {
                ForEach(model.library.presets) { preset in
                    Text(verbatim: preset.displayName(language: model.language)).tag(preset.id)
                }
            }
            .pickerStyle(.inline)
            if model.binder == nil { SmartRemovalMenuItems(model: model) }
        }
    }
}

/// The print themes, shared by the band's and the tray's style menus. With about a hundred themes only a few quick
/// sections stay at the top; every built-in theme is in its category's submenu, so a theme may be checked twice.
struct ThemeMenuContent: View {
    let model: DocumentViewModel

    var body: some View {
        let selection = Binding(get: { model.themeID }, set: { model.selectTheme($0) })
        ForEach(model.themeMenu.sections, id: \.id) { section in
            switch section.kind {
            case .recent:
                picker("Recent", section.themes, selection: selection)
            case .favorites:
                picker("Favorites", section.themes, selection: selection)
            case .featured:
                picker("Suggested", section.themes, selection: selection)
            case .category(let category):
                Menu {
                    picker(nil, section.themes, selection: selection)
                } label: {
                    Text(verbatim: category.displayName(language: model.language))
                }
            case .user:
                Menu("My Styles") {
                    picker(nil, section.themes, selection: selection)
                }
            }
        }
        Menu("Code Colors") {
            CodePaletteMenuContent(model: model)
        }
        Divider()
        // Always enabled: a disabled state derived from the key window's model would not update until the menu opens.
        Button(model.isFavoriteTheme ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavoriteTheme() }
    }

    @ViewBuilder
    private func picker(_ title: LocalizedStringKey?, _ themes: [PrintTheme], selection: Binding<String>) -> some View {
        Picker(selection: selection) {
            ForEach(themes) { theme in
                Text(verbatim: theme.displayName(language: model.language)).tag(theme.id)
            }
        } label: {
            if let title { Text(title) }
        }
        .pickerStyle(.inline)
    }
}

/// The code palettes for the style menus, where the palette's column is not at hand.
struct CodePaletteMenuContent: View {
    let model: DocumentViewModel

    var body: some View {
        Picker(selection: Binding(get: { model.codePaletteID }, set: { model.selectCodePalette($0) })) {
            Text("Match Style").tag(CodePalette.matchesStyleID)
            Divider()
            ForEach(model.library.codePalettes) { palette in
                Text(verbatim: palette.displayName(language: model.language)).tag(palette.id)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.inline)
    }
}

/// Shared by the viewer and print tray so both edit the same pagination setting.
struct TextSizeMenuItems: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Divider()
        Picker("Text Size", selection: Binding(get: { model.textScale }, set: { model.setTextScale($0) })) {
            ForEach(TextScale.choices(including: model.textScale), id: \.self) { scale in
                Text(verbatim: "\(Int((scale * 100).rounded()))%").tag(scale)
            }
        }
        .pickerStyle(.inline)
        Button("Larger") { model.increaseTextSize() }
        Button("Smaller") { model.decreaseTextSize() }
        Button("Original Size") { model.resetTextSize() }
        DocumentTypefacePicker(model: model)
    }
}

/// The Smart Removal (beta) switch and its review, shared by the band's and the tray's preset menus.
struct SmartRemovalMenuItems: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Divider()
        Toggle(
            "Smart Removal (Beta)",
            isOn: Binding(get: { model.isSmartRemovalEnabled }, set: { model.setSmartRemoval(enabled: $0) }))
        Button("Review Removed Parts…") { model.reviewSmartRemoval() }
            .disabled(!model.isSmartRemovalEnabled)
    }
}

struct LayoutPicker: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        CornerSegments(
            title: "View Type", selection: Binding(get: { model.viewOptions.layout }, set: { model.setLayout($0) }),
            values: ViewOptions.Layout.displayOrder, preset: model.preferences.corners
        ) { layout in
            Label(layout.title, systemImage: layout.symbol)
        }
        .labelStyle(.iconOnly)
        .fixedSize()
        .help(ShortcutHints.help(String(localized: "Single Page or Spread"), [.viewSingle, .viewSpread]))
    }
}

extension ViewOptions.Layout {
    var title: LocalizedStringKey {
        switch self {
        case .spread: "Spread"
        case .single: "Single Page"
        }
    }

    var symbol: String {
        switch self {
        case .spread: "rectangle.split.2x1"
        case .single: "rectangle.portrait"
        }
    }

    var name: String {
        switch self {
        case .spread: String(localized: "Spread")
        case .single: String(localized: "Single Page")
        }
    }
}

extension DocumentFormat {
    /// The short label of the format badge.
    var badge: String {
        switch self {
        case .markdown: "MD"
        case .org: "ORG"
        case .plainText: "TXT"
        case .html: "HTML"
        case .pdf: "PDF"
        case .image: "IMG"
        case .csv: "CSV"
        case .zipArchive: "ZIP"
        case .latex: "TEX"
        case .quarto: "QMD"
        case .rMarkdown: "RMD"
        case .docx: "DOCX"
        case .djot: "DJOT"
        case .textile: "TEXTILE"
        case .rst: "RST"
        case .mediawiki: "WIKI"
        case .asciidoc: "ADOC"
        case .notebook: "IPYNB"
        case .graphviz: "Graphviz"
        case .plantuml: "PlantUML"
        }
    }
}

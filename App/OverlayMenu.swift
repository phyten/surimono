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
    /// Where the band's items stand in their band, for the popovers the band hangs off them.
    @ObservationIgnored var itemFrames: [BandLayout.Item: CGRect] = [:]
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
    private var isPointerOverBand: Bool {
        guard let pointerY else { return false }
        if pointerY >= 0, pointerY <= Self.revealZone { return true }
        return hasBottomBand && pointerY >= contentHeight - Self.revealZone && pointerY <= contentHeight
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
            guard let self, !Task.isCancelled, !isHeld, !isPointerOverBand else { return }
            hideNow()
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }
}

/// What each band shows at the current width. The "…" menu is on the top band and takes in what left either band.
struct BandPlans {
    let top: BandLayout.Plan
    /// Nil when the arrangement has no bottom band.
    let bottom: BandLayout.Plan?

    var overflow: [BandLayout.Item] {
        let left = Set(top.overflow + (bottom?.overflow ?? []))
        return BandLayout.Item.allCases.filter(left.contains)
    }

    init(model: DocumentViewModel, menu: OverlayMenuState) {
        let measured = menu.bandWidths
        let arrangement = model.menuArrangement
        let available = menu.bandWidth > 0 ? menu.bandWidth : .greatestFiniteMagnitude
        func widths(at position: BandLayout.Position) -> [BandLayout.Item: BandLayout.Widths] {
            var widths: [BandLayout.Item: BandLayout.Widths] = [:]
            for item in BandLayout.Item.applicable(for: model)
            where BandLayout.position(of: item, in: arrangement) == position {
                let gap = item.bandGap(in: arrangement)
                widths[item] = BandLayout.Widths(
                    full: (measured[.item(item, .full)] ?? 0) + gap,
                    compact: item.hasCompactForm ? (measured[.item(item, .compact)] ?? 0) + gap : nil)
            }
            return widths
        }
        let separator = 1 + OverlayBand.toolSpacing
        // Until the band has been laid out once, its width is unknown: show everything rather than guess.
        top = BandLayout.plan(
            widths: widths(at: .top), fixed: OverlayBand.fixedWidth + (measured[.more] ?? 0), separator: separator,
            name: measured[.name] ?? .greatestFiniteMagnitude, available: available)
        bottom =
            arrangement == .split
            ? BandLayout.plan(
                widths: widths(at: .bottom), fixed: BottomBand.fixedWidth, separator: separator, name: 0,
                available: available, steps: BandLayout.bottomSteps)
            : nil
    }
}

/// The room of one band beside the paper. It stays whether or not the band shows, so that the window never changes
/// with the pointer, and what the band leaves empty moves the window.
struct BandZone<Content: View>: View {
    static var coordinateSpace: String { "band" }

    let edge: VerticalEdge
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            WindowDragArea()
            content
        }
        .frame(height: ViewerWindow.bandHeight)
        .frame(maxWidth: .infinity)
        .background(PrintPalette.raised)
        .overlay(alignment: edge == .top ? .bottom : .top) { Divider() }
        .coordinateSpace(name: Self.coordinateSpace)
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

extension View {
    /// Records where a band's item stands, for the popover that hangs off it.
    func bandItemFrame(_ item: BandLayout.Item, in menu: OverlayMenuState) -> some View {
        onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(BandZone<EmptyView>.coordinateSpace))
        } action: { frame in
            menu.itemFrames[item] = frame
        }
    }
}

/// The popovers of the table of contents and the document's figures. They hang off the band's room rather than off
/// their buttons: `BandMeasurements` draws every item a second time, a folded item has no button, and the room stays
/// when the band hides or rearranges.
struct BandPopovers: View {
    @Bindable var model: DocumentViewModel
    let menu: OverlayMenuState
    let plan: BandLayout.Plan?
    let arrowEdge: Edge

    var body: some View {
        // One popover to a view: two on the same view would compete for its presentation.
        ZStack {
            Color.clear.popover(
                isPresented: $model.isOutlinePresented, attachmentAnchor: anchor(.outline), arrowEdge: arrowEdge
            ) {
                OutlinePopover(model: model)
            }
            Color.clear.popover(
                isPresented: $model.isFiguresPresented, attachmentAnchor: anchor(.pageIndicator), arrowEdge: arrowEdge
            ) {
                DocumentFiguresPopover(model: model)
            }
        }
        .allowsHitTesting(false)
    }

    private func anchor(_ item: BandLayout.Item) -> PopoverAttachmentAnchor {
        let frame = plan?.forms[item] != nil ? menu.itemFrames[item] : nil
        return .rect(.rect(frame ?? CGRect(x: 16, y: 0, width: 80, height: ViewerWindow.bandHeight)))
    }
}

/// The top band of the view mode window. It shows as many tools as fit and folds the rest into "…" in one fixed
/// order (`BandLayout`). Every part keeps its identity whatever fits, so a popover opened from the band stays open
/// when a layout change resizes the window.
struct OverlayBand: View {
    @Bindable var model: DocumentViewModel
    let menu: OverlayMenuState

    static let spacing: CGFloat = 10
    static let toolSpacing: CGFloat = 8
    static let titleSpacing: CGFloat = 6
    static let nameFont = Font.system(size: 13, weight: .semibold)
    private static let lightsWidth: CGFloat = 64
    private static let spacerMinimum: CGFloat = 8
    private static let trailingPadding: CGFloat = 8
    /// What always stays apart from the "…" button: the room for the traffic lights, spacing and padding.
    static var fixedWidth: CGFloat { lightsWidth + spacerMinimum + trailingPadding + spacing * 4 }

    var body: some View {
        let plans = BandPlans(model: model, menu: menu)
        let plan = plans.top
        HStack(spacing: Self.spacing) {
            // Room for the traffic lights.
            Color.clear.frame(width: Self.lightsWidth, height: 1)
            title(plan)
            Spacer(minLength: Self.spacerMinimum)
            tools(plans)
            PrintButton(model: model, iconOnly: plan.forms[.print] == .compact)
        }
        .padding(.trailing, Self.trailingPadding)
    }

    private func title(_ plan: BandLayout.Plan) -> some View {
        HStack(spacing: Self.titleSpacing) {
            if plan.showsName {
                Text(verbatim: model.displayName)
                    .font(Self.nameFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: plan.nameWidth + 0.5, alignment: .leading)
                    .help(model.fileURL?.path ?? model.displayName)
            }
            if plan.forms[.formatBadge] != nil { FormatBadge(text: model.formatBadge) }
            if plan.forms[.pageIndicator] != nil {
                PageIndicatorButton(model: model).bandItemFrame(.pageIndicator, in: menu)
            }
        }
    }

    private func tools(_ plans: BandPlans) -> some View {
        HStack(spacing: Self.toolSpacing) {
            BandTools(model: model, menu: menu, plan: plans.top)
            BandMoreMenu(model: model, overflow: plans.overflow, header: header(plans))
                .popover(isPresented: $model.isViewOptionsPresented, arrowEdge: .bottom) {
                    ViewOptionsPopover(model: model)
                }
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        // The plan already made the tools fit; without this the stack would squeeze a label to make room for the
        // spacer instead of leaving the slack to it.
        .fixedSize()
    }

    /// The document's name, format and page, when the bands no longer show them in full.
    private func header(_ plans: BandPlans) -> String? {
        let plan = plans.top
        let truncated = plan.nameWidth + 0.5 < (menu.bandWidths[.name] ?? 0)
        guard
            !plan.showsName || truncated || plans.overflow.contains(.formatBadge)
                || plans.overflow.contains(.pageIndicator)
        else { return nil }
        return ([model.displayName, model.formatBadge] + [model.pageIndicator].compactMap { $0 })
            .joined(separator: " · ")
    }
}

/// The band under the paper when the menu is split: the reading tools on the left, the page on the right.
struct BottomBand: View {
    @Bindable var model: DocumentViewModel
    let menu: OverlayMenuState
    let plan: BandLayout.Plan

    private static let padding: CGFloat = 10
    private static let spacerMinimum: CGFloat = 8
    static var fixedWidth: CGFloat { padding * 2 + spacerMinimum }

    var body: some View {
        HStack(spacing: OverlayBand.toolSpacing) {
            BandTools(model: model, menu: menu, plan: plan)
            Spacer(minLength: Self.spacerMinimum)
            if plan.forms[.pageIndicator] != nil {
                PageIndicatorButton(model: model).bandItemFrame(.pageIndicator, in: menu)
            }
            if plan.forms[.pageTurn] != nil { PageTurnButtons(model: model) }
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .padding(.horizontal, Self.padding)
    }
}

/// The grouped tools of one band, with a thin separator between the groups.
struct BandTools: View {
    @Bindable var model: DocumentViewModel
    let menu: OverlayMenuState
    let plan: BandLayout.Plan

    var body: some View {
        let shown = BandLayout.Item.allCases.filter { $0.group != nil && plan.forms[$0] != nil }
        HStack(spacing: OverlayBand.toolSpacing) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, item in
                if index > 0, shown[index - 1].group != item.group {
                    Divider().frame(height: 16)
                }
                BandItemView(model: model, item: item, form: plan.forms[item] ?? .full)
                    .bandItemFrame(item, in: menu)
            }
        }
        .fixedSize()
    }
}

struct FormatBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
    }
}

struct PrintButton: View {
    @Bindable var model: DocumentViewModel
    /// The narrowest band keeps Print as an icon rather than dropping it: printing takes two steps at most.
    var iconOnly = false

    var body: some View {
        Button {
            model.performPrintCommand()
        } label: {
            if iconOnly {
                Label("Print…", systemImage: "printer").labelStyle(.iconOnly)
            } else {
                Label("Print…", systemImage: "printer").labelStyle(.titleAndIcon)
            }
        }
        .buttonStyle(.borderedProminent)
        // Vermilion is the color of printing, whatever accent color the Mac is set to.
        .tint(PrintPalette.shu)
        .controlSize(.regular)
        // The file name gives way to the one button that must always show in full.
        .fixedSize()
        .help("Open the print screen (⌘P)")
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
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(model.isThemePalettePresented ? AnyShapeStyle(.tint) : AnyShapeStyle(PrintPalette.ink))
            }
            .fixedSize()
            .help("Style")
        } else {
            Menu {
                StyleMenuItems(model: model)
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(model.usesHTMLPreset ? LocalizedStringKey("HTML Preset") : LocalizedStringKey("Style"))
        }
    }

    @ViewBuilder private var label: some View {
        let label = Label(model.styleName, systemImage: model.usesHTMLPreset ? "wand.and.rays" : "textformat")
        if showsName { label.labelStyle(.titleAndIcon) } else { label.labelStyle(.iconOnly) }
    }
}

extension DocumentViewModel {
    /// The chosen print theme, or for HTML the cleanup preset and whether Smart Removal follows it.
    var styleName: String {
        if usesHTMLPreset && !usesPrintTheme {
            let preset = library.presets.first { $0.id == presetID }?.displayName(language: language) ?? presetID
            return isSmartRemovalEnabled ? preset + " + β" : preset
        }
        let theme = library.themes.first { $0.id == themeID }?.displayName(language: language) ?? themeID
        return usesPrintTheme && textScale != 1 ? theme + " · " + textScalePercentage : theme
    }

    var textScalePercentage: String { "\(Int((textScale * 100).rounded()))%" }

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
            ForEach(TextScale.steps, id: \.self) { scale in
                Text(verbatim: "\(Int((scale * 100).rounded()))%").tag(scale)
            }
        }
        .pickerStyle(.inline)
        Button("Larger") { model.increaseTextSize() }
        Button("Smaller") { model.decreaseTextSize() }
        Button("Original Size") { model.resetTextSize() }
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
        Picker(
            "View",
            selection: Binding(get: { model.viewOptions.layout }, set: { model.setLayout($0) })
        ) {
            ForEach(ViewOptions.Layout.allCases, id: \.self) { layout in
                Label(layout.title, systemImage: layout.symbol).tag(layout)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .labelStyle(.iconOnly)
        .fixedSize()
        .help("Spread or Single Page (⌥⌘1 / ⌥⌘2)")
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
        }
    }
}

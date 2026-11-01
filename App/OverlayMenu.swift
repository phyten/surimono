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
        pointerY.map { $0 >= 0 && $0 <= Self.revealZone } ?? false
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

    func hideForEscape(pinned: Bool) -> Bool {
        guard stage != .hidden, !pinned else { return false }
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

/// The band at the top of the view mode window. It shows as many tools as fit and folds the rest into "…" in one fixed
/// order (`BandLayout`). Every part keeps its identity whatever fits, so a popover opened from the band stays open
/// when a layout change resizes the window.
struct OverlayBand: View {
    @Bindable var model: DocumentViewModel
    let menu: OverlayMenuState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static let spacing: CGFloat = 10
    static let toolSpacing: CGFloat = 8
    static let titleSpacing: CGFloat = 6
    static let nameFont = Font.system(size: 13, weight: .semibold)
    private static let lightsWidth: CGFloat = 64
    private static let spacerMinimum: CGFloat = 8
    private static let trailingPadding: CGFloat = 8
    var body: some View {
        let items = BandLayout.Item.applicable(for: model)
        let plan = plan(for: items)
        HStack(spacing: Self.spacing) {
            // Room for the traffic lights.
            Color.clear.frame(width: Self.lightsWidth, height: 1)
            title(plan)
            Spacer(minLength: Self.spacerMinimum)
            tools(plan)
            PrintButton(model: model, iconOnly: plan.forms[.print] == .compact)
        }
        .padding(.trailing, Self.trailingPadding)
        .frame(height: ViewerWindow.bandHeight)
        .frame(maxWidth: .infinity)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.bar)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
        .background(alignment: .topLeading) { BandMeasurements(model: model, items: items, menu: menu) }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            if menu.bandWidth != width { menu.bandWidth = width }
        }
    }

    private func plan(for items: [BandLayout.Item]) -> BandLayout.Plan {
        let measured = menu.bandWidths
        var widths: [BandLayout.Item: BandLayout.Widths] = [:]
        for item in items {
            widths[item] = BandLayout.Widths(
                full: (measured[.item(item, .full)] ?? 0) + item.bandGap,
                compact: item.hasCompactForm ? (measured[.item(item, .compact)] ?? 0) + item.bandGap : nil)
        }
        let fixed =
            Self.lightsWidth + Self.spacerMinimum + Self.trailingPadding
            + Self.spacing * 4 + (measured[.more] ?? 0)
        // Until the band has been laid out once, its width is unknown: show everything rather than guess.
        return BandLayout.plan(
            widths: widths, fixed: fixed, separator: 1 + Self.toolSpacing,
            name: measured[.name] ?? .greatestFiniteMagnitude,
            available: menu.bandWidth > 0 ? menu.bandWidth : .greatestFiniteMagnitude)
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
            if plan.forms[.pageIndicator] != nil { PageIndicatorText(model: model) }
        }
    }

    private func tools(_ plan: BandLayout.Plan) -> some View {
        let shown = BandLayout.Item.allCases.filter { $0.group != nil && plan.forms[$0] != nil }
        return HStack(spacing: Self.toolSpacing) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, item in
                if index > 0, shown[index - 1].group != item.group {
                    Divider().frame(height: 16)
                }
                BandItemView(model: model, item: item, form: plan.forms[item] ?? .full)
            }
            BandMoreMenu(model: model, overflow: plan.overflow, header: header(plan))
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

    /// The document's name, format and page, when the band no longer shows them in full.
    private func header(_ plan: BandLayout.Plan) -> String? {
        let truncated = plan.nameWidth + 0.5 < (menu.bandWidths[.name] ?? 0)
        guard
            !plan.showsName || truncated || plan.overflow.contains(.formatBadge)
                || plan.overflow.contains(.pageIndicator)
        else { return nil }
        return ([model.displayName, model.formatBadge] + [model.pageIndicator].compactMap { $0 })
            .joined(separator: " · ")
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
                Label("Print", systemImage: "printer").labelStyle(.iconOnly)
            } else {
                Label("Print", systemImage: "printer").labelStyle(.titleAndIcon)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        // The file name gives way to the one button that must always show in full.
        .fixedSize()
        .help("Show the sheets and print (⌘P)")
    }
}

/// Print themes for text formats and cleanup presets for HTML; PDFs and images print as they are. Narrow windows show
/// the icon alone.
struct StyleMenu: View {
    @Bindable var model: DocumentViewModel
    let showsName: Bool

    var body: some View {
        if model.format.usesPrintTheme {
            // Print themes open the palette of samples beside the paper, where it leaves the paper in view.
            Button {
                model.openThemePalette()
            } label: {
                HStack(spacing: 3) {
                    label
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(model.isThemePalettePresented ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .fixedSize()
            .help("Print Theme")
        } else {
            Menu {
                StyleMenuItems(model: model)
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(model.format.usesHTMLPreset ? LocalizedStringKey("HTML Preset") : LocalizedStringKey("Print Theme"))
        }
    }

    @ViewBuilder private var label: some View {
        let label = Label(model.styleName, systemImage: model.format.usesHTMLPreset ? "wand.and.rays" : "textformat")
        if showsName { label.labelStyle(.titleAndIcon) } else { label.labelStyle(.iconOnly) }
    }
}

extension DocumentViewModel {
    /// The chosen print theme, or for HTML the cleanup preset and whether Smart Removal follows it.
    var styleName: String {
        if format.usesHTMLPreset {
            let preset = library.presets.first { $0.id == presetID }?.displayName(language: language) ?? presetID
            return isSmartRemovalEnabled ? preset + " + β" : preset
        }
        let theme = library.themes.first { $0.id == themeID }?.displayName(language: language) ?? themeID
        return format.usesPrintTheme && textScale != 1 ? theme + " · " + textScalePercentage : theme
    }

    var textScalePercentage: String { "\(Int((textScale * 100).rounded()))%" }

    var zoomPercentage: String { "\(Int(((showsWeb ? webZoom : zoom) * 100).rounded()))%" }
}

struct StyleMenuItems: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if model.format.usesPrintTheme {
            ThemeMenuContent(model: model)
            TextSizeMenuItems(model: model)
        } else if model.format.usesHTMLPreset {
            Picker("HTML Preset", selection: $model.presetID) {
                ForEach(model.library.presets) { preset in
                    Text(verbatim: preset.displayName(language: model.language)).tag(preset.id)
                }
            }
            .pickerStyle(.inline)
            SmartRemovalMenuItems(model: model)
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

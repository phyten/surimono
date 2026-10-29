import AppKit
import Observation
import SurimonoCore
import SwiftUI

/// The staged overlay menu of the view mode ("06 段階表示"): hovering shows the file name and Print, moving to the
/// top shows every tool, and leaving or idling hides it again. Pinning keeps the full menu.
@Observable
final class OverlayMenuState {
    enum Stage: Int, Comparable {
        case hidden, compact, full
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let showDelay = Duration.milliseconds(80)
    static let fullDelay = Duration.milliseconds(120)
    static let hideDelay = Duration.milliseconds(800)
    static let idleDelay = Duration.milliseconds(2500)
    /// The band plus a margin below it in which resting the pointer reveals every tool.
    static let fullZone: CGFloat = ViewerWindow.bandHeight + 40

    private(set) var stage: Stage = .hidden
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var fullTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var pointerY: CGFloat?
    @ObservationIgnored private var menuTracking = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The measured widths of the band's parts, and the band's own width. They outlive the band, which comes and goes
    /// with the pointer, so that it opens with the tools that fit instead of a first guess.
    var bandWidths: [BandSlot: CGFloat] = [:]
    var bandWidth: CGFloat = 0
    /// Set while a popover from the band is open, so the menu stays put.
    var isHolding = false {
        didSet { if !isHolding { scheduleIdleHide() } }
    }

    init() {
        // A pop-up menu opened from the band takes the pointer away; keep the band until the menu closes.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.menuTracking += 1 }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuTracking = max(self.menuTracking - 1, 0)
                    if self.pointerY == nil { self.scheduleHide() }
                }
            },
        ]
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for task in [showTask, fullTask, hideTask, idleTask] { task?.cancel() }
    }

    private var isHeld: Bool { isHolding || menuTracking > 0 }

    func pointerMoved(to point: CGPoint) {
        pointerY = point.y
        hideTask?.cancel()
        if stage == .hidden, showTask == nil {
            showTask = after(Self.showDelay) { state in
                state.showTask = nil
                state.stage = max(state.stage, .compact)
            }
        }
        if point.y <= Self.fullZone {
            if stage != .full, fullTask == nil {
                fullTask = after(Self.fullDelay) { state in
                    state.fullTask = nil
                    state.stage = .full
                }
            }
        } else {
            fullTask?.cancel()
            fullTask = nil
        }
        scheduleIdleHide()
    }

    func pointerExited() {
        pointerY = nil
        showTask?.cancel()
        showTask = nil
        fullTask?.cancel()
        fullTask = nil
        idleTask?.cancel()
        scheduleHide()
    }

    /// Turning a page means the reader is reading: get out of the way.
    func pageTurned() {
        guard !isHeld else { return }
        hideNow()
    }

    /// Tab or M from the keyboard.
    func toggle() {
        if stage == .full { hideNow() } else { showFull() }
    }

    func showFull() {
        cancelTimers()
        stage = .full
        scheduleIdleHide()
    }

    func showCompact() {
        cancelTimers()
        stage = .compact
        scheduleIdleHide()
    }

    func hideNow() {
        cancelTimers()
        stage = .hidden
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard stage != .hidden else { return }
        hideTask = after(Self.hideDelay) { state in
            guard !state.isHeld, state.pointerY == nil else { return }
            state.hideNow()
        }
    }

    private func scheduleIdleHide() {
        idleTask?.cancel()
        idleTask = after(Self.idleDelay) { state in
            // Resting on the band itself is not idling.
            guard !state.isHeld, (state.pointerY ?? .infinity) > ViewerWindow.bandHeight else { return }
            state.hideNow()
        }
    }

    private func cancelTimers() {
        for task in [showTask, fullTask, hideTask, idleTask] { task?.cancel() }
        showTask = nil
        fullTask = nil
        hideTask = nil
        idleTask = nil
    }

    private func after(_ delay: Duration, _ action: @escaping (OverlayMenuState) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            // A cancelled timer must not fire even if it woke up just before the cancellation.
            guard let self, !Task.isCancelled else { return }
            action(self)
        }
    }
}

/// The band at the top of the view mode window. It shows as many tools as fit and folds the rest into "…" in one fixed
/// order (`BandLayout`). Every part keeps its identity whatever fits, so a popover opened from the band stays open
/// when a layout change resizes the window.
struct OverlayBand: View {
    @Bindable var model: DocumentViewModel
    let stage: OverlayMenuState.Stage
    let menu: OverlayMenuState

    static let spacing: CGFloat = 10
    static let toolSpacing: CGFloat = 8
    static let titleSpacing: CGFloat = 6
    static let nameFont = Font.system(size: 13, weight: .semibold)
    private static let lightsWidth: CGFloat = 64
    private static let spacerMinimum: CGFloat = 8
    private static let trailingPadding: CGFloat = 8

    var body: some View {
        let items = BandLayout.Item.applicable(for: model, stage: stage)
        let plan = plan(for: items)
        HStack(spacing: Self.spacing) {
            // Room for the traffic lights.
            Color.clear.frame(width: Self.lightsWidth, height: 1)
            title(plan)
            Spacer(minLength: Self.spacerMinimum)
            if stage == .full {
                tools(plan)
            } else {
                CompactIndicators(model: model)
            }
            PrintButton(model: model, iconOnly: plan.forms[.print] == .compact)
        }
        .padding(.trailing, Self.trailingPadding)
        .frame(height: ViewerWindow.bandHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
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
        // The traffic lights, the title, the spacer, the tools or the indicators, and Print: four gaps.
        let stays = (stage == .full ? measured[.more] : measured[.indicators]) ?? 0
        let fixed = Self.lightsWidth + Self.spacing * 4 + Self.spacerMinimum + Self.trailingPadding + stays
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
        Menu {
            StyleMenuItems(model: model)
        } label: {
            let label = Label(
                model.styleName, systemImage: model.format.usesHTMLPreset ? "wand.and.rays" : "textformat")
            if showsName { label.labelStyle(.titleAndIcon) } else { label.labelStyle(.iconOnly) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.format.usesHTMLPreset ? LocalizedStringKey("HTML Preset") : LocalizedStringKey("Print Theme"))
    }
}

extension DocumentViewModel {
    /// The chosen print theme, or for HTML the cleanup preset and whether Smart Removal follows it.
    var styleName: String {
        if format.usesHTMLPreset {
            let preset = library.presets.first { $0.id == presetID }?.displayName(language: language) ?? presetID
            return isSmartRemovalEnabled ? preset + " + β" : preset
        }
        return library.themes.first { $0.id == themeID }?.displayName(language: language) ?? themeID
    }

    var zoomPercentage: String { "\(Int((zoom * 100).rounded()))%" }
}

struct StyleMenuItems: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if model.format.usesPrintTheme {
            Picker("Print Theme", selection: $model.themeID) {
                ForEach(model.library.themes) { theme in
                    Text(verbatim: theme.displayName(language: model.language)).tag(theme.id)
                }
            }
            .pickerStyle(.inline)
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
        .help("Spread or Single Page")
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
        }
    }
}

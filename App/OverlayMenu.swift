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

/// The band at the top of the view mode window.
struct OverlayBand: View {
    @Bindable var model: DocumentViewModel
    let stage: OverlayMenuState.Stage
    let menu: OverlayMenuState

    var body: some View {
        HStack(spacing: 10) {
            // Room for the traffic lights.
            Color.clear.frame(width: 64, height: 1)
            title
            Spacer(minLength: 8)
            if stage == .full {
                ViewThatFits(in: .horizontal) {
                    tools(overflow: false)
                    tools(overflow: true)
                }
            } else if model.isAlwaysOnTop {
                Image(systemName: "pin.fill").foregroundStyle(.secondary).help("Floating on Top")
            }
            PrintButton(model: model)
        }
        .padding(.trailing, 8)
        .frame(height: ViewerWindow.bandHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var title: some View {
        HStack(spacing: 6) {
            Text(verbatim: model.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.fileURL?.path ?? model.displayName)
            if stage == .full {
                FormatBadge(text: model.formatBadge)
                if let indicator = model.pageIndicator {
                    Text(verbatim: indicator).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .layoutPriority(1)
    }

    @ViewBuilder private func tools(overflow: Bool) -> some View {
        HStack(spacing: 8) {
            if !overflow { StyleMenu(model: model) }
            LayoutPicker(model: model)
            ViewOptionsButton(model: model)
            if model.zoom > 1.001 {
                Button {
                    model.paper.zoomToFit()
                } label: {
                    Text(verbatim: "\(Int((model.zoom * 100).rounded()))%").monospacedDigit()
                }
                .help("Fit to Window")
            }
            if model.imageBundle != nil {
                Toggle(isOn: $model.isDrawerOpen) { Label("Thumbnails", systemImage: "sidebar.left") }
                    .toggleStyle(.button).help("Thumbnails")
            }
            Toggle(isOn: $model.isAlwaysOnTop) {
                Label("Float on Top", systemImage: model.isAlwaysOnTop ? "pin.fill" : "pin")
            }
            .toggleStyle(.button).help("Float on Top")
            Toggle(isOn: $model.isMenuPinned) {
                Label("Keep Menu Visible", systemImage: "menubar.rectangle")
            }
            .toggleStyle(.button).help("Keep Menu Visible")
            if overflow {
                Menu {
                    StyleMenuItems(model: model)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .fixedSize()
    }
}

private struct FormatBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
    }
}

struct PrintButton: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Button {
            model.performPrintCommand()
        } label: {
            Label("Print", systemImage: "printer").labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .help("Show the sheets and print (⌘P)")
    }
}

/// Print themes for text formats and cleanup presets for HTML; PDFs and images print as they are.
private struct StyleMenu: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if model.format.usesPrintTheme || model.format.usesHTMLPreset {
            Menu {
                StyleMenuItems(model: model)
            } label: {
                Label(currentName, systemImage: model.format.usesHTMLPreset ? "wand.and.rays" : "textformat")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(model.format.usesHTMLPreset ? "HTML Preset" : "Print Theme")
        }
    }

    private var currentName: String {
        if model.format.usesHTMLPreset {
            return model.library.presets.first { $0.id == model.presetID }?.displayName(language: model.language)
                ?? model.presetID
        }
        return model.library.themes.first { $0.id == model.themeID }?.displayName(language: model.language)
            ?? model.themeID
    }
}

private struct StyleMenuItems: View {
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
        }
    }
}

private struct LayoutPicker: View {
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
        .fixedSize()
        .help("Spread, Single Page or Two-Page Scroll")
    }
}

private struct ViewOptionsButton: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Button {
            model.isViewOptionsPresented.toggle()
        } label: {
            Label("View Options", systemImage: "slider.horizontal.3")
        }
        .help("View Options")
        .popover(isPresented: $model.isViewOptionsPresented, arrowEdge: .bottom) {
            ViewOptionsPopover(model: model)
        }
    }
}

extension ViewOptions.Layout {
    var title: LocalizedStringKey {
        switch self {
        case .spread: "Spread"
        case .single: "Single Page"
        case .twoPageScroll: "Two-Page Scroll"
        }
    }

    var symbol: String {
        switch self {
        case .spread: "rectangle.split.2x1"
        case .single: "rectangle.portrait"
        case .twoPageScroll: "rectangle.grid.2x2"
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

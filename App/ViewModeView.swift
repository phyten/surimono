import AppKit
import SurimonoCore
import SwiftUI

// Bands that always show have their own room beside the paper and never cover it. Bands that show on pointing take
// that room only while they show: the window grows around the paper and gives the room back when they hide, so the
// window is the paper alone in between. Where the window cannot grow, they lie over the paper's edges.
struct ViewModeView: View {
    @Bindable var model: DocumentViewModel
    @State private var menu: OverlayMenuState

    init(model: DocumentViewModel, menu: OverlayMenuState? = nil) {
        self.model = model
        _menu = State(initialValue: menu ?? OverlayMenuState())
    }

    private var bandVisible: Bool { model.isBandAlwaysVisible || menu.stage != .hidden }
    /// Bands shown by the pointer or the keys rather than always.
    private var hoverBandShown: Bool { !model.isBandAlwaysVisible && menu.stage != .hidden }
    private var isSplit: Bool { model.menuArrangement == .split }
    /// What floats over the paper stays clear of the bottom band's room.
    private var bottomInset: CGFloat { isSplit ? ViewerWindow.bandHeight : 0 }
    private var holdsBand: Bool {
        model.isViewOptionsPresented || model.isThemePalettePresented || model.isPrintFinishPresented
            || model.isOutlinePresented || model.isFiguresPresented || model.isLaTeXRecognitionPresented
            || model.drop.holdsBand
    }

    var body: some View {
        let plans = BandPlans(model: model, menu: menu)
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if model.showsOutlineDrawer {
                    OutlineDrawer(model: model, availableWidth: menu.bandWidth - model.sideInset)
                        .transition(.move(edge: .leading))
                }
                if model.showsSideList {
                    if model.binder != nil {
                        BinderDrawer(model: model)
                    } else if model.imageBundle != nil {
                        if model.pageCount > 1 {
                            OutlineDrawer(model: model)
                        } else {
                            ImageBundleDrawer(model: model)
                        }
                    }
                }
                // A page turn moves the pages past the paper's edge, where the panel beside it must stay in front.
                PaperArea(model: model, menu: menu).clipped()
                if model.showsReadingPanel { OrgReadingPanel(model: model) }
            }
            .padding(.top, model.currentBandRoom.top)
            .padding(.bottom, model.currentBandRoom.bottom)
            // Overlays, so that a band without room draws over the paper's own view. The zones stay the same views
            // whether or not they have room, and so do the band and the popovers it anchors when the room comes or
            // goes.
            .overlay(alignment: .top) { topZone(plans) }
            .overlay(alignment: .bottom) {
                if isSplit, let plan = plans.bottom { bottomZone(plan) }
            }
            if model.isReviewingSmartRemoval {
                SmartRemovalPanel(model: model)
                    .padding(.top, model.topBandHeight + 8)
                    .padding(.bottom, bottomInset)
                    .padding([.trailing, .bottom], 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if bandVisible, plans.bottom?.showsScrubber == true { PageScrubPreview(model: model) }
            ToastOverlay(model: model).padding(.bottom, bottomInset)
            BandPresentationHost(model: model, plans: plans)
            ThemePaletteAnchor(model: model)
            PrintSettingsAnchor(model: model)
        }
        .coordinateSpace(name: BandAnchors.coordinateSpace)
        .ignoresSafeArea()
        .background(Color(nsColor: .underPageBackgroundColor))
        // Indigo marks what is chosen in every mode of a document window, so that vermilion alone means Print.
        .tint(PrintPalette.aiControl)
        .animation(.easeOut(duration: 0.16), value: menu.stage)
        .animation(.easeOut(duration: 0.2), value: model.showsOutlineDrawer)
        .animation(.easeOut(duration: 0.2), value: model.isReviewingSmartRemoval)
        .sheet(isPresented: $model.isGoToPagePresented) { GoToPageSheet(model: model) }
        .background {
            PointerTracker(isActive: !model.isBandAlwaysVisible) { point, contentHeight in
                menu.contentHeight = contentHeight
                if let point { menu.pointerMoved(to: point) } else { menu.pointerExited() }
            }
        }
        .onChange(of: isSplit, initial: true) { _, split in menu.hasBottomBand = split }
        .onChange(of: hoverBandShown) { _, shown in
            model.bandRevealDidChange(shown)
            followBandRoom()
        }
        .onChange(of: model.currentBandRoom, initial: true) { followBandRoom() }
        .onChange(of: model.topBandHeight, initial: true) { _, height in menu.topZone = height }
        // A window narrower than this would push the traffic lights, "…" or Print off a band.
        .onChange(of: plans.minimumWidth, initial: true) { _, width in
            menu.minimumWidth = width
            model.bandMinimumWidthDidChange(width)
        }
        // The first plans can come before the window does.
        .background {
            WindowReader { window in model.bandMinimumWidthDidChange(menu.minimumWidth, in: window) }
        }
        .onChange(of: model.latexBadge == nil) { _, hidden in
            if hidden { model.isLaTeXRecognitionPresented = false }
        }
        .recordingBandPlan(plans.resolved, in: model.bandAnchors)
        .onChange(of: plans.band(of: .thumbnails) == nil, initial: true) { _, hidden in
            // The list button's place is a drop target only while the list is on a band: a fold or another arrangement
            // leaves its last place behind, where a resting drag would open the list.
            if hidden { model.drop.listButtonFrame = nil }
        }
        .onChange(of: bandVisible) { _, visible in
            if let window = model.window { ViewerWindow.setTrafficLightsVisible(visible, in: window) }
        }
        // The band, which anchors its popovers, must stay while one is open, however it was opened.
        .onChange(of: model.scrubber.holdsBand, initial: true) { _, held in
            menu.scrubberHeld = held
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window { model.scrubber.cancel() }
        }
        .onChange(of: holdsBand) { _, held in
            if held { menu.showFull() }
            menu.isHolding = held
        }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: DebugSnapshot.showMenu)) { note in
                guard let target = note.object as? DocumentViewModel, target === model else { return }
                menu.isHolding = true
                menu.showFull()
                if let room = note.userInfo?["scrubRoom"] as? CGFloat, let window = model.window,
                    let row = BandPlans(model: model, menu: menu, availableWidth: .greatestFiniteMagnitude).bottom,
                    row.showsScrubber, let content = window.contentView
                {
                    let width = row.requiredWidth - BandLayout.scrubberMinimum + room
                    model.snapshotScrubWidth = width
                    window.setContentSize(CGSize(width: width, height: content.bounds.height))
                }
            }
        #endif
    }

    /// The pointer's zones move with the room at once, in the same update as the window.
    private func followBandRoom() {
        menu.topRoom = model.currentBandRoom.top
        menu.bottomRoom = model.currentBandRoom.bottom
    }

    private func topZone(_ plans: BandPlans) -> some View {
        BandZone(edge: .top, isShown: bandVisible, height: model.topBandHeight) {
            OverlayBand(model: model, menu: menu, plans: plans)
        }
        .background(alignment: .topLeading) {
            BandMeasurements(model: model, items: BandLayout.Item.applicable(for: model), menu: menu)
        }
        // Read while the band hides too, so that it shows on the buttons' line at once.
        .background {
            TrafficLightsReader { lights in
                if menu.trafficLights != lights { menu.trafficLights = lights }
                if !menu.hasReadTrafficLights { menu.hasReadTrafficLights = true }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            if menu.bandWidth != width { menu.bandWidth = width }
        }
    }

    private func bottomZone(_ row: BandRowPlan) -> some View {
        BandZone(edge: .bottom, isShown: bandVisible, height: ViewerWindow.bandHeight) {
            BottomBand(model: model, row: row)
        }
    }
}

/// The rendered pages, or the progress and error states in their place.
private struct PaperArea: View {
    @Bindable var model: DocumentViewModel
    let menu: OverlayMenuState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var updateDisplay: PageUpdateProgress.Display {
        #if DEBUG
            if let value = DebugSnapshot.argument("SurimonoUpdating"),
                let forced = PageUpdateProgress.Display(rawValue: value)
            {
                return model.pageUpdateState == .inactive ? .hidden : forced
            }
        #endif
        return model.pageUpdateDisplay
    }

    var body: some View {
        ZStack {
            if model.showsWeb, let fileURL = model.fileURL {
                WebPageView(
                    controller: model.web, fileURL: fileURL, allowsJavaScript: model.allowsLiveJavaScript,
                    onEscape: { [weak model, menu] in
                        guard let model, !model.isWindowClosed else { return false }
                        return menu.hideForEscape(alwaysVisible: model.isBandAlwaysVisible)
                    })
            } else if let document = model.paperDocument, !model.isCapturingWeb {
                PaperView(
                    document: document, initialPageIndex: model.currentPageIndex, options: model.viewOptions,
                    zoom: model.zoom, wheelSensitivity: model.preferences.wheelSensitivity,
                    selectsText: model.isSelectingText, logicalMargin: model.viewLogicalMargin,
                    showsPageNumbers: model.preferences.viewPageNumbers, changeMarks: model.paperChangeMarks,
                    formulaIndex: model.paperFormulaIndex, diagrams: model.paperDiagrams,
                    onDiagram: { [weak model] diagram, action in
                        guard let model, !model.isWindowClosed else { return }
                        model.exportDiagram(diagram, action: action)
                    },
                    furniture: model.paperFurniture,
                    narrowsLoneCover: model.loneCoverWidth == .onePage,
                    keepsSpotInPage: model.binder != nil || model.imageBundle != nil,
                    controller: model.paper,
                    onZoomChange: model.windowAction { $0.zoom = $1 },
                    onPageChange: model.windowAction { $0.paperDidChangePage($1) },
                    onTurn: { [menu] in menu.pageTurned() },
                    onKey: { [weak model, menu] event in
                        guard let model, !model.isWindowClosed else { return false }
                        return model.handleFixedPaperKey(event, menu: menu)
                    },
                    onShortcut: model.windowAction { [menu] in $0.performPaperShortcut($1, menu: menu) },
                    allowsShortcutHandling: { [weak model] in
                        guard let model, !model.isWindowClosed else { return false }
                        return !model.blocksSurfaceShortcuts
                    }
                )
                .paperFind(model)
            } else if model.error == nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Preparing pages…").font(.callout).foregroundStyle(PrintPalette.ink2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The live page shows whatever the paper's pagination ran into.
            if let error = model.error, !model.showsWeb {
                ErrorPanel(model: model, message: error)
            }
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if model.trialThemeName != nil || updateDisplay != .hidden {
                    Group {
                        if let name = model.trialThemeName {
                            ThemeTrialBadge(name: name, isReady: model.themeTrial.document != nil)
                        } else {
                            PageUpdateBadge(showsText: updateDisplay == .text)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 18)
            .allowsHitTesting(false)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: model.trialThemeName != nil || updateDisplay != .hidden)
        }
        .overlay(alignment: .topTrailing) {
            if model.find.isPresented, !model.showsWeb {
                FindBar(model: model).padding(10).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.find.isPresented)
        .overlay(alignment: .bottom) {
            if !model.unreadableImageURLs.isEmpty {
                NoticePlate(
                    text: String(
                        format: String(localized: "Could not open: %@"),
                        model.unreadableImageURLs.map(\.lastPathComponent).joined(separator: ", "))
                )
                .textSelection(.enabled)
                .padding(10)
            }
        }
        .alert(
            "Output Failed",
            isPresented: model.controlBinding(
                get: { $0.outputError != nil },
                set: { if !$1 { $0.outputError = nil } })
        ) {
            Button("OK", role: .cancel) { model.outputError = nil }
        } message: {
            Text(verbatim: model.outputError ?? "")
        }
    }

}

extension PaperView {
    /// Hands the paper the words of the window's find bar, and the model the hits the paper found.
    fileprivate func paperFind(_ model: DocumentViewModel) -> PaperView {
        var view = self
        let mark = model.proseMark
        if !mark.spans.isEmpty, model.isOutlineShown, model.contentsTab == .prose,
            mark.matches(generation: model.proseGeneration, readingPage: model.currentPageIndex)
        {
            view.proseSpans = mark.spans
        }
        view.onPaperPress = { [weak model] in
            guard let model, !model.isWindowClosed else { return }
            model.dismissProseMark()
        }
        view.findQuery = model.find.query
        view.onFindHits = { [weak model] pages, query in
            guard let model, !model.isWindowClosed else { return }
            model.paperFound(pages, for: query)
        }
        return view
    }
}

private struct ErrorPanel: View {
    @Bindable var model: DocumentViewModel
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(PrintPalette.ink2)
            Text(verbatim: message).multilineTextAlignment(.center).textSelection(.enabled)
            HStack {
                if !model.layoutTooLarge {
                    Button("Reload") { model.reload() }
                }
                if model.offersPlainTextRecovery {
                    Button("Open as Plain Text") { model.reopenAsText() }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .paperOverlayBackground(.panel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows a notice and its optional action; the model decides when it goes away.
struct ToastOverlay: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack {
            Spacer()
            if let toast = model.toast {
                HStack(spacing: 12) {
                    Image(systemName: toast.systemImage).font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: toast.title).font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = toast.detail {
                            Text(verbatim: detail).font(.system(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Group {
                        switch toast.action {
                        case .allowFolderAccess?:
                            Button("Choose Folder…") { model.allowFolderAccess() }
                                .controlSize(.small)
                        case .retryWebCapture?:
                            Button("Try Again") { model.retryWebCapture() }
                                .controlSize(.small)
                        case .nextChange?:
                            Button("Next Change") { model.goToNextChange() }
                        case .openIncludes?:
                            Button("Open as Binder") { model.openIncludesAsBinder() }
                                .controlSize(.small)
                        case .undoBinder?:
                            Button("Undo") { model.undoBinderConversion() }
                                .controlSize(.small)
                        case .undoReset?:
                            Button("Undo") { model.undoResetDocumentSettings() }
                                .controlSize(.small)
                        case nil:
                            EmptyView()
                        }
                    }
                    .buttonStyle(ToastActionButtonStyle(showsBackground: toast.action != .allowFolderAccess))
                    if toast.showsDismissButton {
                        PanelIconButton("xmark", label: "Dismiss") { model.dismissToast(closingFolderNotice: true) }
                    }
                }
                .foregroundStyle(PrintPalette.toastInk)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(CornerRole.toast.shape.fill(PrintPalette.toast))
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

/// A line that stays on the paper for as long as it is true, in the look of the toasts.
struct NoticePlate: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(PrintPalette.toastInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(CornerRole.toast.shape.fill(PrintPalette.toast))
    }
}

/// Toast actions stay legible regardless of the surrounding view's accent color or appearance.
struct ToastActionButtonStyle: ButtonStyle {
    var showsBackground = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .underline(!showsBackground)
            .contentShape(Rectangle())
            .background {
                if showsBackground {
                    AppCornerShape.capsule.fill(
                        DisplayAccessibility.shared.options.fill(
                            .white, opacity: configuration.isPressed ? 0.28 : 0.2, over: PrintPalette.toast))
                }
            }
            .opacity(!showsBackground && configuration.isPressed ? 0.75 : 1)
    }
}

private struct PageUpdateBadge: View {
    let showsText: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
                .tint(DisplayAccessibility.shared.options.increasedContrast ? PrintPalette.ink : nil)
                .accessibilityLabel(Text("Updating pages"))
            if showsText {
                Text("Updating pages…").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(DisplayAccessibility.shared.options.increasedContrast ? PrintPalette.ink : PrintPalette.ink2)
        .paperOverlayBackground(.toast)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

/// Says which theme the paper is trying while the pointer rests on it in the palette.
struct ThemeTrialBadge: View {
    let name: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 8) {
            if !isReady { ProgressView().controlSize(.mini) }
            Text(verbatim: String(format: String(localized: "Trying %@"), name)).font(
                .system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(PrintPalette.toastInk)
        .background(CornerRole.toast.shape.fill(PrintPalette.toast))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

/// Hangs the style palette off the window's trailing edge, so it opens beside the paper instead of over it and a
/// theme tried from it shows on the whole page. The edge never moves with the band, so the palette keeps its anchor.
struct ThemePaletteAnchor: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Color.clear
            .frame(width: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .allowsHitTesting(false)
            .popover(
                isPresented: model.controlBinding(
                    get: { $0.isThemePalettePresented },
                    set: { model, presented in
                        if presented { model.isThemePalettePresented = true } else { model.themePaletteDidClose() }
                    }),
                arrowEdge: .trailing
            ) {
                ThemePalette(model: model)
            }
    }
}

/// Hangs the print settings off the window's trailing edge, as the style palette is: the paper fills the window, which
/// keeps the page's shape and is often narrower than the panel, so a panel over the paper would hide the very pages it
/// changes. The tray has room beside its sheets and lays the same panel there instead.
struct PrintSettingsAnchor: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Color.clear
            .frame(width: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .allowsHitTesting(false)
            .popover(isPresented: $model.isPrintFinishPresented, arrowEdge: .trailing) {
                PrintFinishSheet(model: model, isInPopover: true)
            }
    }
}

@MainActor
extension DocumentViewModel {
    func handleFixedPaperKey(_ event: NSEvent, menu: OverlayMenuState) -> Bool {
        switch KeyGuideEntry.fixedPaperAction(for: event) {
        case .menu:
            performPaperShortcut(.viewToolbarToggle, menu: menu)
            return true
        case .escape:
            // Find is the innermost presentation even after focus returns to the paper.
            if find.isPresented {
                closeFind()
                return true
            }
            return menu.hideForEscape(alwaysVisible: isBandAlwaysVisible)
        default: return false
        }
    }

    func performPaperShortcut(_ operation: ShortcutOperationID, menu: OverlayMenuState) {
        guard mode == .view, !showsWeb else { return }
        switch operation {
        case .viewToolbarToggle: menu.toggle()
        case .viewOptions:
            menu.showFull()
            isViewOptionsPresented = true
        case .viewSelectText: toggleSelectingText()
        case .readingBack: goBack()
        case .readingForward: goForward()
        case .bookmarkToggle: toggleBookmark()
        case .bookmarkNext: goToNextBookmark()
        case .bookmarkPrevious: goToPreviousBookmark()
        default: break
        }
    }
}

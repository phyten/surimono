import AppKit
import SurimonoCore
import SwiftUI

// The paper keeps its space while the band appears above it.
struct ViewModeView: View {
    @Bindable var model: DocumentViewModel
    @State private var menu = OverlayMenuState()

    private var bandVisible: Bool { model.isMenuPinned || menu.stage != .hidden }

    var body: some View {
        ZStack(alignment: .top) {
            PaperArea(model: model, menu: menu)
                .padding(.top, model.isMenuPinned ? ViewerWindow.bandHeight : 0)
            if let bundle = model.imageBundle, model.isDrawerOpen {
                ImageBundleDrawer(model: bundle, onClose: { model.isDrawerOpen = false })
                    .padding(.top, ViewerWindow.bandHeight + 8)
                    .padding([.leading, .bottom], 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if model.isReviewingSmartRemoval {
                SmartRemovalPanel(model: model)
                    .padding(.top, ViewerWindow.bandHeight + 8)
                    .padding([.trailing, .bottom], 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if bandVisible {
                OverlayBand(model: model, menu: menu)
                    .transition(.opacity)
            }
            ToastOverlay(model: model)
            ThemePaletteAnchor(model: model)
        }
        .ignoresSafeArea()
        .background(Color(nsColor: .underPageBackgroundColor))
        .animation(.easeOut(duration: 0.16), value: menu.stage)
        .animation(.easeOut(duration: 0.2), value: model.isDrawerOpen)
        .animation(.easeOut(duration: 0.2), value: model.isReviewingSmartRemoval)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): menu.pointerMoved(to: point)
            case .ended: menu.pointerExited()
            }
        }
        .onChange(of: bandVisible) { _, visible in
            if let window = model.window { ViewerWindow.setTrafficLightsVisible(visible, in: window) }
        }
        .onChange(of: model.isViewOptionsPresented) { _, presented in
            // The band, which anchors the popover, must stay while the popover is open, however it was opened.
            if presented { menu.showFull() }
            menu.isHolding = presented || model.isThemePalettePresented
        }
        .onChange(of: model.isThemePalettePresented) { _, presented in
            if presented { menu.showFull() }
            menu.isHolding = presented || model.isViewOptionsPresented
        }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: DebugSnapshot.showMenu)) { note in
                guard let target = note.object as? DocumentViewModel, target === model else { return }
                menu.isHolding = true
                menu.showFull()
            }
        #endif
    }
}

/// The rendered pages, or the progress and error states in their place.
private struct PaperArea: View {
    @Bindable var model: DocumentViewModel
    let menu: OverlayMenuState

    var body: some View {
        ZStack {
            if model.showsWeb, let fileURL = model.fileURL {
                WebPageView(
                    controller: model.web, fileURL: fileURL, allowsJavaScript: model.preferences.allowsJavaScript,
                    onEscape: { menu.hideForEscape(pinned: model.isMenuPinned) })
            } else if let document = model.paperDocument, !model.isCapturingWeb {
                PaperView(
                    document: document, initialPageIndex: model.currentPageIndex, options: model.viewOptions,
                    zoom: model.zoom, wheelSensitivity: model.preferences.wheelSensitivity,
                    selectsText: model.isSelectingText, logicalMargin: model.viewLogicalMargin,
                    showsPageNumbers: model.preferences.viewPageNumbers, changeMarks: model.paperChangeMarks,
                    controller: model.paper,
                    onZoomChange: { model.zoom = $0 },
                    onPageChange: { model.paperDidChangePage($0) },
                    onTurn: { menu.pageTurned() },
                    onKey: handleKey)
            } else if model.error == nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Preparing pages…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The live page shows whatever the paper's pagination ran into.
            if let error = model.error, !model.showsWeb {
                ErrorPanel(model: model, message: error)
            }
        }
        .overlay(alignment: .bottom) {
            if let name = model.trialThemeName {
                ThemeTrialBadge(name: name, isReady: model.themeTrial.document != nil)
                    .padding(.bottom, 18)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.trialThemeName)
        .overlay(alignment: .bottom) {
            if !model.unreadableImageURLs.isEmpty {
                Text(
                    String(
                        format: String(localized: "Could not open: %@"),
                        model.unreadableImageURLs.map(\.lastPathComponent).joined(separator: ", "))
                )
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(8).paperOverlayBackground(cornerRadius: 8).padding(10)
            }
        }
        .alert(
            "Output Failed",
            isPresented: Binding(
                get: { model.outputError != nil },
                set: { if !$0 { model.outputError = nil } })
        ) {
            Button("OK", role: .cancel) { model.outputError = nil }
        } message: {
            Text(verbatim: model.outputError ?? "")
        }
    }

    /// Menu keys on the paper: Tab or M toggles the menu, Esc hides it, V opens the view options, T switches between
    /// selecting text and moving the window.
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        if event.specialKey == .tab {
            menu.toggle()
            return true
        }
        if event.keyCode == 53 {  // Escape
            return menu.hideForEscape(pinned: model.isMenuPinned)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m":
            menu.toggle()
            return true
        case "v":
            menu.showFull()
            model.isViewOptionsPresented = true
            return true
        case "t":
            guard model.canSelectText else { return false }
            model.toggleSelectingText()
            return true
        default:
            return false
        }
    }
}

private struct ErrorPanel: View {
    @Bindable var model: DocumentViewModel
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(verbatim: message).multilineTextAlignment(.center).textSelection(.enabled)
            HStack {
                Button("Reload") { model.reload() }
                if model.format.isWebRendered && model.format != .plainText {
                    Button("Open as Plain Text") { model.reopenAsText() }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .paperOverlayBackground(cornerRadius: 12)
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
                            Text(verbatim: detail).font(.system(size: 11)).opacity(0.75)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Group {
                        switch toast.action {
                        case .allowFolderAccess?:
                            Button("Allow Access to Folder…") { model.allowFolderAccess() }
                                .controlSize(.small)
                        case .retryWebCapture?:
                            Button("Try Again") { model.retryWebCapture() }
                                .controlSize(.small)
                        case nil:
                            EmptyView()
                        }
                    }
                    .buttonStyle(ToastActionButtonStyle())
                    Button {
                        model.dismissToast()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain).opacity(0.6).help("Dismiss")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.78)))
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

/// Toast actions stay legible regardless of the surrounding view's accent color or appearance.
private struct ToastActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(.white.opacity(configuration.isPressed ? 0.32 : 0.2))
            }
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
                .system(size: 12.5, weight: .semibold))
            Text("Click to choose. Move away to go back.").font(.system(size: 11.5)).opacity(0.75)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(PrintPalette.toastInk)
        .background(RoundedRectangle(cornerRadius: 9).fill(PrintPalette.toast))
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
                isPresented: Binding(
                    get: { model.isThemePalettePresented },
                    set: { presented in
                        if presented { model.isThemePalettePresented = true } else { model.themePaletteDidClose() }
                    }),
                arrowEdge: .trailing
            ) {
                ThemePalette(model: model)
            }
    }
}

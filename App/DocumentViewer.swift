import AppKit
import SurimonoCore
import SwiftUI

struct DocumentViewer: View {
    @State private var model: DocumentViewModel

    init(
        document: SurimonoDocument, fileURL: URL?, preferences: AppPreferences, library: UserLibrary,
        settingsStore: DocumentSettingsStore?
    ) {
        let format =
            fileURL.flatMap { DocumentFormat(fileExtension: $0.pathExtension) } ?? document.format ?? .plainText
        var bundle: ImageBundleModel?
        var failure: String?
        if format == .zipArchive {
            (bundle, failure) = Self.openArchive(document.data, url: fileURL)
        }
        let model = DocumentViewModel(
            data: document.data, fileURL: fileURL, format: format, preferences: preferences, library: library,
            imageBundle: bundle, settingsStore: settingsStore)
        if let failure { model.failToOpen(failure) }
        _model = State(initialValue: model)
    }

    var body: some View {
        DocumentContent(model: model)
    }

    /// A ZIP opens as an image bundle of the images inside it, read from memory without extracting anything.
    private static func openArchive(_ data: Data, url: URL?) -> (ImageBundleModel?, String?) {
        do {
            let archive = try ZipArchive(data: data)
            let selection = ZipImageSelection(archive: archive)
            guard !selection.images.isEmpty else {
                return (nil, String(localized: "This ZIP archive contains no images."))
            }
            if selection.images.contains(where: \.isEncrypted) {
                return (nil, String(localized: "Encrypted ZIP archives cannot be opened."))
            }
            let total = selection.images.reduce(UInt64(0)) { total, entry in
                let (sum, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
                return overflow ? .max : sum
            }
            guard total <= ZipArchive.Limits.default.maximumTotalSize else {
                return (nil, String(localized: "This ZIP archive is too large to open."))
            }
            let archiveURL = url ?? URL(fileURLWithPath: "/Archive.zip")
            return (ImageBundleModel(archive: archive, selection: selection, archiveURL: archiveURL), nil)
        } catch ZipArchive.ReadError.encrypted {
            return (nil, String(localized: "Encrypted ZIP archives cannot be opened."))
        } catch ZipArchive.ReadError.tooManyEntries, ZipArchive.ReadError.entryTooLarge {
            return (nil, String(localized: "This ZIP archive is too large to open."))
        } catch {
            return (nil, String(localized: "This ZIP archive could not be read."))
        }
    }
}

/// One window's content, shared by document windows and image bundle windows.
struct DocumentContent: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Group {
            switch model.mode {
            case .view: ViewModeView(model: model)
            case .print: PrintModeView(model: model)
            case .compare: ThemeCompareView(model: model)
            }
        }
        // The tray's and the stage's top bars need the taller title bar of a window with a toolbar.
        .toolbar {
            if model.mode != .view { PrintModeToolbarPlaceholder() }
        }
        .background(
            WindowReader { window in
                ViewerWindow.configure(window)
                model.window = window
                DocumentWindows.shared.register(model, for: window)
                // SwiftUI moves the content to the window again when the print mode adds its toolbar.
                ViewerWindow.setTrafficLightsVisible(model.isBandAlwaysVisible || model.mode != .view, in: window)
                ViewerWindow.setAlwaysOnTop(model.isAlwaysOnTop, in: window)
                // Reattaching after a stage must preserve the frame chosen for the return to reading.
                model.sizeWindowToPaper(initialOnly: true)
                #if DEBUG
                    DebugSnapshot.captureIfReady(model)
                #endif
            }
        )
        .overlay {
            ZStack {
                DropOverlay(model: model)
                DropCatcher(
                    session: model.drop, onEnter: { model.dragEntered($0, at: $1) }, onPerform: { model.performDrop() })
            }
            .ignoresSafeArea()
        }
        .onAppear {
            WelcomeController.shared.close()
            model.start()
        }
        .onDisappear { model.stop() }
        .sheet(item: $model.duplexTestResult) { test in
            DuplexTestSheet(model: model, test: test)
        }
        .modifier(DocumentContentChanges(model: model))
        .modifier(DocumentWindowChanges(model: model))
    }
}

// The window's reactions stand apart from the view above: the compiler of the oldest supported Xcode gives up on
// type-checking them as one chain.

/// What follows from changes to the pages and the documents behind them.
private struct DocumentContentChanges: ViewModifier {
    let model: DocumentViewModel

    func body(content: Content) -> some View {
        content
            .onChange(of: model.renderSettings) { _, _ in model.renderForChangedSettings() }
            .onChange(of: model.allowsLiveJavaScript) { _, _ in model.javaScriptSettingDidChange() }
            .onChange(of: model.imageBundle?.urls) { _, _ in
                if let bundle = model.imageBundle { model.window?.title = bundle.title(language: model.language) }
                model.listDidChange()
            }
            .onChange(of: model.binder?.urls) { _, _ in
                model.window?.title = model.displayName
                model.listDidChange()
            }
            .onChange(of: model.library.revision) { _, _ in model.reloadLibrary() }
            .onChange(of: model.rememberedSettings) { _, _ in model.rememberedSettingsDidChange() }
    }
}

/// What follows for the window itself.
private struct DocumentWindowChanges: ViewModifier {
    let model: DocumentViewModel

    func body(content: Content) -> some View {
        content
            // The paper is shown before the sheets are composed, so the window takes its shape then too.
            .onChange(of: model.result.map { ObjectIdentifier($0.logicalDocument) }) { _, document in
                if document != nil { model.sizeWindowToPaper() }
            }
            .onChange(of: model.isRendering) { _, rendering in
                if !rendering {
                    model.sizeWindowToPaper()
                    OpenRouter.shared.printIfRequested(model)
                    model.enterRequestedPrintMode()
                }
                #if DEBUG
                    if !rendering { DebugSnapshot.captureIfReady(model) }
                #endif
            }
            .onChange(of: model.viewOptions.layout) { old, new in
                // Switching between one page and a spread keeps the height and changes the width.
                if (old == .single) != (new == .single) { model.sizeWindowToPaper(keepHeight: true) }
            }
            // At once, in the same update as the list: an animation would first take the room from the paper.
            .onChange(of: model.showsSideList) { _, _ in model.sizeWindowToPaper(keepsRightEdge: true) }
            .onChange(of: model.showsNarrowCover) { _, _ in model.coverWidthDidChange() }
            .onChange(of: model.menuArrangement) { old, _ in model.menuArrangementDidChange(from: old) }
            .onChange(of: model.isAlwaysOnTop) { _, onTop in
                if let window = model.window { ViewerWindow.setAlwaysOnTop(onTop, in: window) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
                if let window = note.object as? NSWindow, window === model.window { model.windowDidEndLiveResize() }
            }
    }
}

extension View {
    /// AppKit hands a new popover or panel's first text field the focus, where the next key press would type into it.
    func clearsInitialFocus() -> some View {
        background(
            WindowReader { window in
                Task { @MainActor in
                    // After AppKit's own choice, which comes once the view is on screen.
                    try? await Task.sleep(for: .milliseconds(60))
                    window.makeFirstResponder(nil)
                }
            })
    }
}

struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> ReaderView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI may be updating its views right now (for example when a toolbar comes or goes); changing the
            // window from inside that update can crash it, so wait until the update is done.
            Task { @MainActor [weak self] in
                guard let self, let window else { return }
                onWindow(window)
            }
        }
    }
}

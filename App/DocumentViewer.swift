import AppKit
import PDFKit
import SurimonoCore
import SwiftUI

struct DocumentViewer: View {
    @State private var model: DocumentViewModel

    init(document: SurimonoDocument, fileURL: URL?, preferences: AppPreferences, library: UserLibrary) {
        _model = State(
            initialValue: DocumentViewModel(
                data: document.data, fileURL: fileURL,
                format: fileURL.flatMap { DocumentFormat(fileExtension: $0.pathExtension) } ?? document.format
                    ?? .plainText,
                preferences: preferences, library: library))
    }

    var body: some View {
        DocumentPreview(model: model)
            .frame(minWidth: 760, minHeight: 480)
            .toolbar { DocumentToolbar(model: model) }
            .focusedSceneValue(\.documentModel, model)
            .preferredColorScheme(model.appearance.colorScheme)
            .background(
                WindowReader { window in
                    model.window = window
                    #if DEBUG
                        DebugSnapshot.captureIfReady(model)
                    #endif
                }
            )
            .onAppear {
                WelcomeController.shared.close()
                model.start()
            }
            .onDisappear { model.stop() }
            .onChange(of: model.renderSettings) { _, _ in model.render() }
            .onChange(of: model.library.revision) { _, _ in model.reloadLibrary() }
            .onChange(of: model.isRendering) { _, rendering in
                #if DEBUG
                    if !rendering { DebugSnapshot.captureIfReady(model) }
                #endif
            }
    }
}

struct DocumentPreview: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(verbatim: error).textSelection(.enabled)
                    Spacer()
                    Button("Reload") { model.reload() }
                    if model.format.isWebRendered && model.format != .plainText {
                        Button("Open as Plain Text") { model.reopenAsText() }
                    }
                }.padding()
                Divider()
            }
            if let document = model.previewDocument {
                PDFDocumentView(document: document)
            } else {
                ContentUnavailableView(
                    "Print Preview", systemImage: "doc.richtext",
                    description: Text(
                        model.isRendering
                            ? LocalizedStringKey("Preparing pages…") : LocalizedStringKey("No preview is available."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if model.isRendering {
                    ProgressView().controlSize(.small)
                    Text("Preparing pages…")
                } else if let summary = model.summary {
                    Text(verbatim: summary)
                }
                Spacer()
                if let notice = model.notice {
                    Text(verbatim: notice).foregroundStyle(.secondary)
                    Button {
                        model.notice = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain).help("Dismiss")
                }
            }
            .font(.callout)
            .padding(10)
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
}

struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PaperPDFView {
        let view = PaperPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.show(document)
        return view
    }

    func updateNSView(_ view: PaperPDFView, context: Context) {
        if view.document !== document {
            view.show(document)
            view.goToFirstPage(nil)
        }
        // PDFKit's page rendering stays light while the surrounding canvas follows the window.
        let appearance = view.superview?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            view.backgroundColor = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
        }
        view.appearance = NSAppearance(named: .aqua)
        view.needsLayout = true
    }
}

final class PaperPDFView: PDFView {
    private var largestPageSize = CGSize.zero
    private var fittedViewSize: CGSize?

    func show(_ document: PDFDocument) {
        self.document = document
        displayBox = .cropBox
        largestPageSize = (0..<document.pageCount).reduce(into: CGSize.zero) { size, index in
            guard let page = document.page(at: index) else { return }
            let bounds = page.bounds(for: .cropBox)
            let pageSize =
                page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
            size = CGSize(width: max(size.width, pageSize.width), height: max(size.height, pageSize.height))
        }
        fittedViewSize = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Fit whole pages when the document or the view size changes, so a zoom the user chose survives other
        // layout passes.
        guard largestPageSize.width > 0, largestPageSize.height > 0, bounds.width > 40, bounds.height > 40,
            fittedViewSize != bounds.size
        else { return }
        fittedViewSize = bounds.size
        // The clip view excludes the scroller, and the page break margins surround every page.
        let visible = documentView?.enclosingScrollView?.contentSize ?? bounds.size
        let padding: CGFloat = 16
        let widthScale =
            (visible.width - pageBreakMargins.left - pageBreakMargins.right - padding) / largestPageSize.width
        let heightScale =
            (visible.height - pageBreakMargins.top - pageBreakMargins.bottom - padding) / largestPageSize.height
        let scale = max(min(widthScale, heightScale), 0.05)
        if abs(scaleFactor - scale) > 0.001 { scaleFactor = scale }
    }
}

private struct WindowReader: NSViewRepresentable {
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
            if let window { onWindow(window) }
        }
    }
}

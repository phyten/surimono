import AppKit
import PDFKit
import SurimonoCore
import SwiftUI

/// "Fold It": the booklet in reading order, one spread at a time, as it will read once folded and stapled.
struct PrintFoldView: View {
    let model: DocumentViewModel
    let close: () -> Void
    @State private var book = FoldBook()

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 5) {
                Text(verbatim: title)
                    .font(.custom("Hiragino Mincho ProN", size: 16).weight(.semibold))
                    .tracking(0.6)
                Text(verbatim: subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(PrintPalette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            FoldBookView(book: book)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(caption)
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(PrintPalette.ink2)
                .frame(minHeight: 20)
            HStack(spacing: 8) {
                Button {
                    book.turn(by: -1)
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 34)
                }
                .buttonStyle(PrintBorderedButtonStyle(height: 30))
                .disabled(!book.canTurn(by: -1))
                .help("Previous Spread")
                .keyboardShortcut(.leftArrow, modifiers: [])
                Button {
                    book.turn(by: 1)
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).frame(width: 34)
                }
                .buttonStyle(PrintBorderedButtonStyle(height: 30))
                .disabled(!book.canTurn(by: 1))
                .help("Next Spread")
                .keyboardShortcut(.rightArrow, modifiers: [])
                Rectangle().fill(PrintPalette.line2).frame(width: 1, height: 18).padding(.horizontal, 4)
                Button(action: close) {
                    Label("Back to Sheets", systemImage: "rectangle.split.2x1").padding(.horizontal, 12)
                }
                .buttonStyle(PrintBorderedButtonStyle(height: 30))
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            }
        }
        .padding(.top, 22)
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PrintPalette.stage)
        // Rebuild the book whenever the pages are rendered again, for example after a style change.
        .task(id: model.result.map { ObjectIdentifier($0.logicalDocument) }) {
            guard let result = model.result, let settings = model.renderedSettings else { return }
            book.load(
                result.logicalDocument, pageSize: settings.layout.logicalPageSize,
                blankLabel: PrintModeText.string("Blank", language: model.language))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }

    private var layout: PrintLayout { model.renderedSettings?.layout ?? model.layout }

    private var title: String {
        PrintModeText.format(
            "%@ booklet, folded", language: model.language, (layout.sheet.halved ?? layout.sheet).displayName)
    }

    private var subtitle: String {
        [model.displayName, model.summary].compactMap { $0 }.joined(separator: "　")
    }

    private var caption: AttributedString {
        let language = model.language
        func label(_ page: Int) -> String {
            page <= book.contentPageCount
                ? PrintModeText.format("Page %lld", language: language, page)
                : PrintModeText.format("%lld (blank)", language: language, page)
        }
        let markdown: String
        switch book.spread {
        case .cover(let page):
            markdown = PrintModeText.format("**Cover**  %@", language: language, label(page))
        case .backCover(let page):
            markdown = PrintModeText.format("**Back cover**  %@", language: language, label(page))
        case .pages(let left, let right, let isCenter):
            markdown =
                PrintModeText.format("**Spread**  %1$@ | %2$@", language: language, label(left), label(right))
                + (isCenter ? "  " + PrintModeText.string("Center spread (staple position)", language: language) : "")
        }
        var text = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        for run in text.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            text[run.range].foregroundColor = PrintPalette.ink
        }
        return text
    }
}

/// The folded booklet: the logical pages padded with blank pages to whole sheets, turned a spread at a time.
@Observable
final class FoldBook {
    enum Spread: Equatable {
        case cover(Int)
        case backCover(Int)
        case pages(Int, Int, isCenter: Bool)
    }

    private(set) var document: PDFDocument?
    private(set) var contentPageCount = 0
    private(set) var pageCount = 0
    private(set) var pageIndex = 0
    @ObservationIgnored private weak var view: PDFView?
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Spreads in reading order: the cover alone, then two pages at a time, then the back cover alone.
    var row: Int { (pageIndex + 1) / 2 }
    var lastRow: Int { pageCount / 2 }

    var spread: Spread { Self.spread(row: row, pageCount: pageCount) }

    static func spread(row: Int, pageCount: Int) -> Spread {
        if row <= 0 { return .cover(1) }
        if row >= pageCount / 2 { return .backCover(pageCount) }
        return .pages(row * 2, row * 2 + 1, isCenter: row * 2 == pageCount / 2)
    }

    func canTurn(by offset: Int) -> Bool { document != nil && (0...lastRow).contains(row + offset) }

    func turn(by offset: Int) {
        guard canTurn(by: offset), let view, let document else { return }
        // Go to the first page of the target spread rather than relying on how PDFKit steps through two-up rows.
        let index = min(max((row + offset) * 2 - 1, 0), document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        pageIndex = index
        view.go(to: page)
    }

    func load(_ logical: PDFDocument, pageSize: CGSize, blankLabel: String) {
        guard let data = logical.dataRepresentation(), let book = PDFDocument(data: data) else { return }
        pageIndex = 0
        contentPageCount = book.pageCount
        let padded = (book.pageCount + 3) / 4 * 4
        while book.pageCount < padded, let blank = Self.blankPage(size: pageSize, label: blankLabel) {
            book.insert(blank, at: book.pageCount)
        }
        pageCount = book.pageCount
        document = book
    }

    func attach(_ view: PDFView) {
        guard self.view !== view else { return }
        self.view = view
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePage() }
        }
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        view = nil
    }

    func updatePage() {
        guard let view, let document, let page = view.currentPage else { return }
        pageIndex = document.index(for: page)
    }

    /// A grey page marked "Blank", like the blank halves on the tray.
    private static func blankPage(size: CGSize, label: String) -> PDFPage? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data),
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0xEB / 255, green: 0xEB / 255, blue: 0xE8 / 255, alpha: 1))
        context.fill(box)
        let font = NSFont(name: "HiraMinProN-W6", size: size.width * 0.05) ?? .systemFont(ofSize: size.width * 0.05)
        let text = NSAttributedString(
            string: label,
            attributes: [
                .font: font, .kern: size.width * 0.015,
                .foregroundColor: NSColor(srgbRed: 0xA2 / 255, green: 0xA2 / 255, blue: 0x9E / 255, alpha: 1),
            ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: box.midX - bounds.midX, y: box.midY - bounds.midY)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}

/// A book-style two-up PDF view that starts with the cover on the right, like a closed booklet.
private struct FoldBookView: NSViewRepresentable {
    let book: FoldBook

    func makeCoordinator() -> FoldBook { book }

    static func dismantleNSView(_ view: FoldPDFView, coordinator: FoldBook) { coordinator.detach() }

    func makeNSView(context: Context) -> FoldPDFView {
        let view = FoldPDFView()
        view.acceptsDraggedFiles = false
        view.displayMode = .twoUp
        view.displaysAsBook = true
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.pageShadowsEnabled = true
        view.autoScales = true
        book.attach(view)
        return view
    }

    func updateNSView(_ view: FoldPDFView, context: Context) {
        if view.document !== book.document, let document = book.document {
            view.document = document
            view.autoScales = true
            view.goToFirstPage(nil)
            book.updatePage()
        }
        // The pages stay light; only the surrounding stage follows the window's appearance.
        let appearance = view.superview?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            view.backgroundColor = PrintPalette.stageColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
        }
        view.appearance = NSAppearance(named: .aqua)
    }
}

/// A spread always fits, so an idle scroll bar would only draw a stripe beside the book. PDFKit turns its scroll bars
/// back on in every layout pass, so its scroll view uses overlay scroll bars, which stay hidden while nothing scrolls.
private final class FoldPDFView: PDFView {
    override func layout() {
        super.layout()
        if let scrollView = documentView?.enclosingScrollView, scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
    }
}

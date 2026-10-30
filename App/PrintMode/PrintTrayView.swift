import AppKit
import PDFKit
import SurimonoCore
import SwiftUI

/// The tray (刷り台): one row per physical sheet, front and back side by side, drawn from the imposed PDF.
struct PrintTrayView: View {
    let model: DocumentViewModel
    let tray: PrintTray
    let document: PDFDocument
    @Binding var showsFold: Bool
    @State private var zoom: CGFloat = 1
    @State private var visibleRow: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            // Legacy scroll bars take their width from the visible area; overlay scroll bars take nothing.
            let width = geometry.size.width - Self.scrollerWidth
            let metrics = TrayMetrics(layout: tray.layout, viewportWidth: width, zoom: zoom)
            // Scroll sideways only when zoomed wider than the window, so no idle horizontal scroll bar shows.
            let scrollsSideways = metrics.rowWidth + 2 * TrayMetrics.padding > width
            ZStack(alignment: .bottomTrailing) {
                ScrollView(scrollsSideways ? [.vertical, .horizontal] : .vertical) {
                    VStack(alignment: .leading, spacing: 30) {
                        header.frame(width: metrics.rowWidth, alignment: .leading)
                        LazyVStack(alignment: .leading, spacing: 34) {
                            ForEach(tray.rows) { row in
                                HStack(alignment: .top, spacing: TrayMetrics.twoUpSpacing) {
                                    ForEach(row.sheets) { sheet in
                                        TraySheetView(
                                            sheet: sheet, layout: tray.layout, metrics: metrics, document: document,
                                            language: model.language, imageNames: imageNames,
                                            options: model.printOptions)
                                    }
                                }
                                .id(row.id)
                            }
                        }
                        .scrollTargetLayout()
                        // A lazy stack fills the offered width; pin it so the sheets stay centered.
                        .frame(width: metrics.rowWidth, alignment: .leading)
                    }
                    .padding(.top, 22)
                    .padding(.horizontal, TrayMetrics.padding)
                    .padding(.bottom, 40)
                    .frame(minWidth: scrollsSideways ? width : nil, maxWidth: scrollsSideways ? nil : .infinity)
                }
                .scrollPosition(id: $visibleRow, anchor: .top)
                .scrollIndicators(.automatic)
                TrayNavigator(
                    current: currentRowIndex, rows: tray.rows, sheetCount: tray.sheets.count,
                    zoomPercent: metrics.zoomPercent, canZoomIn: zoom < TrayMetrics.zoomRange.upperBound,
                    canZoomOut: zoom > TrayMetrics.zoomRange.lowerBound, go: go(to:),
                    zoomIn: { setZoom(zoom * 1.25) }, zoomOut: { setZoom(zoom / 1.25) }, resetZoom: { setZoom(1) }
                )
                .padding(.trailing, 14)
                .padding(.bottom, 16)
            }
        }
        .onChange(of: tray.layout) { _, _ in
            zoom = 1
            visibleRow = nil
        }
    }

    private static var scrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(instructions)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(PrintPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if tray.isBooklet {
                    Button {
                        showsFold = true
                    } label: {
                        Label("Fold It", systemImage: "book")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(PrintPalette.ai)
                            .padding(.leading, 11)
                            .padding(.trailing, 13)
                            .frame(height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PrintPalette.ai, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Fold the sheets into a booklet and turn its pages")
                }
            }
            .padding(.bottom, 14)
            PrintSourceNotes(model: model)
            Rectangle().fill(PrintPalette.line).frame(height: 1)
        }
    }

    /// The Markdown emphasis of the instructions is drawn in the darker ink, as in the design.
    private var instructions: AttributedString {
        let markdown = PrintModeText.instructions(tray.layout, language: model.language)
        var text = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        for run in text.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            text[run.range].foregroundColor = PrintPalette.ink
        }
        return text
    }

    /// Unreadable images get no page, so they are left out to keep the names in step with the pages.
    private var imageNames: [String]? {
        model.imageBundle?.urls.filter { !model.unreadableImageURLs.contains($0) }.map(\.lastPathComponent)
    }

    private var currentRowIndex: Int {
        guard let visibleRow else { return 0 }
        return tray.rows.firstIndex { $0.id == visibleRow } ?? 0
    }

    private func go(to index: Int) {
        guard tray.rows.indices.contains(index) else { return }
        if reduceMotion {
            visibleRow = tray.rows[index].id
        } else {
            withAnimation(.easeOut(duration: 0.25)) { visibleRow = tray.rows[index].id }
        }
    }

    /// The scroll position follows the top sheet, so the sheet in view stays in view when the rows change height.
    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, TrayMetrics.zoomRange.lowerBound), TrayMetrics.zoomRange.upperBound)
    }
}

/// One physical sheet: its heading, then the front and the back next to each other.
private struct TraySheetView: View {
    let sheet: PrintTray.Sheet
    let layout: PrintLayout
    let metrics: TrayMetrics
    let document: PDFDocument
    let language: String
    let imageNames: [String]?
    let options: PrintOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: PrintModeText.sheetTitle(sheet, language: language))
                    .font(.custom("Hiragino Mincho ProN", size: 13).weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(PrintPalette.ink)
                    .fixedSize()
                Text(verbatim: PrintModeText.sheetSubtitle(sheet, layout: layout, language: language))
                    .font(.system(size: 11.5))
                    .foregroundStyle(PrintPalette.ink2)
                    .lineLimit(1)
                Rectangle()
                    .fill(PrintPalette.line)
                    .frame(minWidth: 24, maxWidth: .infinity)
                    .frame(height: 1)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            .frame(width: width, alignment: .leading)
            HStack(alignment: .top, spacing: TrayMetrics.sideSpacing) {
                ForEach(sheet.sides, id: \.documentIndex) { side in
                    TraySideView(
                        side: side, page: document.page(at: side.documentIndex), size: metrics.sideSize,
                        scale: metrics.scale, layout: layout, language: language, imageNames: imageNames,
                        options: options)
                }
            }
        }
    }

    private var width: CGFloat {
        let count = CGFloat(sheet.sides.count)
        return metrics.sideSize.width * count + TrayMetrics.sideSpacing * (count - 1)
    }
}

/// A printed side: the white sheet, blank halves tinted, the fold line for booklets, and its page labels.
private struct TraySideView: View {
    let side: PrintTray.Side
    let page: PDFPage?
    let size: CGSize
    let scale: CGFloat
    let layout: PrintLayout
    let language: String
    let imageNames: [String]?
    let options: PrintOptions

    var body: some View {
        VStack(spacing: 9) {
            paper
            if showsCaption { caption }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var paper: some View {
        SheetPageView(page: page)
            .frame(width: size.width, height: size.height)
            .overlay {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(side.visiblePages.enumerated()), id: \.offset) { index, page in
                        let rect = layout.slotRect(at: index, options: options)
                        if page == nil && layout.kind != .handout3 {
                            ZStack {
                                PrintPalette.blankPaper
                                Text("Blank")
                                    .font(.custom("Hiragino Mincho ProN", size: max(7, 30 * scale)).weight(.semibold))
                                    .tracking(max(2, 9 * scale))
                                    .foregroundStyle(PrintPalette.blankInk)
                            }
                            .frame(width: rect.width * size.width, height: rect.height * size.height)
                            .offset(x: rect.minX * size.width, y: rect.minY * size.height)
                        }
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .overlay {
                if layout.kind == .booklet { FoldLine() }
            }
            .background {
                Rectangle()
                    .fill(PrintPalette.paper)
                    .shadow(color: PrintPalette.paperShadow.opacity(0.5), radius: 1, y: 1)
                    .shadow(color: PrintPalette.paperShadow, radius: 12, y: 10)
            }
            .overlay { Rectangle().strokeBorder(PrintPalette.paperRing, lineWidth: 0.5) }
            .overlay {
                if layout.kind == .booklet { FoldTicks().frame(width: 9, height: size.height + 14) }
            }
    }

    private var showsCaption: Bool {
        layout.kind != .normal || layout.duplex != .none || imageNames != nil
    }

    private var caption: some View {
        let pages = side.visiblePages
        let face = PrintModeText.faceLabel(side, language: language)
        return ZStack(alignment: .leading) {
            if layout.hasStackedSlots {
                Text(
                    verbatim: layout.kind == .handout3
                        ? PrintModeText.handoutCaption(pages, language: language)
                        : PrintModeText.stackedCaption(pages, language: language)
                )
                .font(.system(size: 12)).monospacedDigit().lineLimit(1)
                .frame(width: size.width)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        pageLabel(page)
                            // The first label stays clear of the front and back tag at the left edge.
                            .padding(.leading, index == 0 && face != nil ? (side.isRotated ? 56 : 28) : 4)
                            .padding(.trailing, 4)
                            .frame(width: size.width / CGFloat(max(pages.count, 1)))
                    }
                }
            }
            if let face { PrintTag(text: face) }
        }
        .frame(width: size.width, height: 20)
    }

    @ViewBuilder private func pageLabel(_ page: Int?) -> some View {
        if let page {
            if let imageNames, imageNames.indices.contains(page - 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: "\(page)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text(verbatim: imageNames[page - 1])
                        .font(.system(size: 10.5))
                        .foregroundStyle(PrintPalette.ink2)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
            } else {
                Text("Page **\(page)**")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        } else {
            Text("Blank").font(.system(size: 11.5)).foregroundStyle(PrintPalette.ink2).lineLimit(1)
        }
    }

    private var accessibilityText: String {
        let pages = side.visiblePages.map { page in
            page.map { PrintModeText.format("Page %lld", language: language, $0) }
                ?? PrintModeText.string("Blank", language: language)
        }
        return ([PrintModeText.faceLabel(side, language: language)].compactMap { $0 } + pages).joined(separator: ", ")
    }
}

/// The center fold of a booklet sheet.
private struct FoldLine: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: geometry.size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height))
            }
            .stroke(PrintPalette.foldLine, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .allowsHitTesting(false)
    }
}

/// The small marks above and below a booklet sheet where it is folded.
private struct FoldTicks: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: 0.5))
            path.addLine(to: CGPoint(x: size.width, y: 0.5))
            path.move(to: CGPoint(x: 0, y: size.height - 0.5))
            path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(path, with: .color(PrintPalette.foldMark), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// The floating control on the right: the current sheet with up and down, and the zoom.
private struct TrayNavigator: View {
    let current: Int
    let rows: [PrintTray.Row]
    let sheetCount: Int
    let zoomPercent: Int
    let canZoomIn: Bool
    let canZoomOut: Bool
    let go: (Int) -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            Button {
                go(current - 1)
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
            }
            .disabled(current <= 0)
            .help("Previous Sheet")
            Text(verbatim: "\(sheetNumber)/\(sheetCount)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(PrintPalette.ink2)
                // Hundreds of sheets would wrap in the narrow navigator; shrink instead.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.vertical, 2)
                .accessibilityLabel(Text("Sheet \(sheetNumber) of \(sheetCount)"))
            Button {
                go(current + 1)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .disabled(current >= rows.count - 1)
            .help("Next Sheet")
            Rectangle().fill(PrintPalette.line2).frame(width: 20, height: 1).padding(.vertical, 4)
            Button(action: zoomIn) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }
            .disabled(!canZoomIn)
            .help("Zoom In")
            Button(action: resetZoom) {
                Text(verbatim: "\(zoomPercent)%").font(.system(size: 10.5)).monospacedDigit()
            }
            .buttonStyle(PrintIconButtonStyle(size: CGSize(width: 36, height: 22)))
            .help("Fit to Width")
            Button(action: zoomOut) {
                Image(systemName: "minus").font(.system(size: 11, weight: .semibold))
            }
            .disabled(!canZoomOut)
            .help("Zoom Out")
        }
        .buttonStyle(PrintIconButtonStyle())
        .padding(3)
        .frame(width: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(PrintPalette.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PrintPalette.line2, lineWidth: 1))
        .shadow(color: PrintPalette.popShadow, radius: 9, y: 6)
    }

    private var sheetNumber: Int {
        rows.indices.contains(current) ? (rows[current].sheets.first?.number ?? 1) : 1
    }
}

/// Draws a sheet side from the imposed PDF as vectors, so it stays sharp at any size.
struct SheetPageView: NSViewRepresentable {
    let page: PDFPage?

    func makeNSView(context: Context) -> SheetPageNSView { SheetPageNSView() }

    func updateNSView(_ view: SheetPageNSView, context: Context) { view.page = page }
}

final class SheetPageNSView: NSView {
    var page: PDFPage? {
        didSet { if page !== oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Redraw from the PDF instead of stretching the old bitmap while the size changes.
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        guard let page else { return }
        let box = page.bounds(for: .cropBox)
        let size = page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        context.saveGState()
        context.translateBy(
            x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
    }
}

import SurimonoCore
import SwiftUI

// Frequent choices stay on the band; this popover keeps the remaining document values beside a live sample.
struct ViewOptionsPopover: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("View Options").font(.headline)
                Text(verbatim: model.displayName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            SpreadSample(options: model.viewOptions, unit: currentUnit)
            SpreadMap(units: model.displayUnits, current: currentUnitIndex) { unit in
                if let first = unit.pages.first { model.paper.goToPage(index: first - 1) }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                heading("On Screen")
                GridRow {
                    rowLabel("Reading Direction")
                    Picker("Reading Direction", selection: option(\.direction)) {
                        Text("Left to Right · Bound Left").tag(ViewOptions.Direction.leftToRight)
                        Text("Right to Left · Bound Right").tag(ViewOptions.Direction.rightToLeft)
                    }
                    .pickerStyle(.menu)
                }
                GridRow {
                    rowLabel("Scroll Direction")
                    Picker("Scroll Direction", selection: option(\.scrollAxis)) {
                        Text("Vertical").tag(ViewOptions.ScrollAxis.vertical)
                        Text("Horizontal").tag(ViewOptions.ScrollAxis.horizontal)
                    }
                    .disabled(!model.viewOptions.usesScrollAxis)
                }
                GridRow {
                    rowLabel("Show First Page Alone")
                    HStack(spacing: 12) {
                        Toggle("Show First Page Alone", isOn: option(\.showsCoverAlone))
                            .toggleStyle(.switch).controlSize(.small)
                        CoverSample(direction: model.viewOptions.direction)
                    }
                    .disabled(!model.viewOptions.usesCoverOption)
                }
                if model.viewOptions.canJoinPages, model.viewLogicalMargin != nil {
                    GridRow {
                        rowLabel("Join Pages")
                        Toggle("Join Pages", isOn: option(\.joinsPages))
                            .toggleStyle(.switch).controlSize(.small)
                    }
                }
                GridRow {
                    rowLabel("Toolbar")
                    BandVisibilityPicker(selection: $model.bandVisibility)
                }
                if model.offersPaperSeries {
                    // The label follows the picker, not the note that hangs under it.
                    GridRow(alignment: .firstTextBaseline) {
                        rowLabel("Paper on Screen")
                        VStack(alignment: .leading, spacing: 4) {
                            PaperSeriesPicker(selection: $model.paperSeries)
                            caption("Choose the paper for printing on the print screen.")
                        }
                    }
                }
                if model.marginsApply {
                    heading("Printed Text")
                    GridRow {
                        rowLabel("Text Margins")
                        HStack(spacing: 4) {
                            MarginControl(model: model)
                            Text("mm").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            HStack(spacing: 8) {
                // Resetting belongs to the statement that the document has its own settings; the setting sets are a
                // separate, stronger choice on the other side.
                if model.hasSavedSettings {
                    Text("Using this document’s settings")
                        .font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Words the reader must read stay in ink: an accent color of their choice may not be dark enough.
                Button {
                    model.resetDocumentSettings()
                } label: {
                    Text("Reset This Document").underline()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(PrintPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(!model.hasSavedSettings)
                Spacer(minLength: 8)
                SettingSetMenu(preferences: model.preferences, library: model.library, model: { model })
                    .fixedSize()
            }
        }
        .padding(16)
        .frame(width: 560)
        .paperOverlayBackground(cornerRadius: 0, tintOpacity: 0.985)
        .clearsInitialFocus()
    }

    private var currentUnitIndex: Int? {
        SpreadLayout.unitIndex(containing: model.currentPageIndex + 1, in: model.displayUnits)
    }

    private var currentUnit: DisplayUnit? {
        currentUnitIndex.map { model.displayUnits[$0] }
    }

    private func rowLabel(_ key: LocalizedStringKey) -> some View {
        Text(key).foregroundStyle(PrintPalette.ink2).gridColumnAlignment(.trailing)
    }

    private func heading(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 13, weight: .bold))
            .padding(.top, 4)
            .gridCellColumns(2)
            .gridCellAnchor(.leading)
    }

    private func caption(_ key: LocalizedStringKey) -> some View {
        // Wraps instead of being cut short: a longer translation must still be readable in full.
        Text(key).font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func option<Value>(_ keyPath: WritableKeyPath<ViewOptions, Value>) -> Binding<Value> {
        model.viewOption(keyPath)
    }
}

/// The settings' default and the document's own choice of when the bands show.
struct BandVisibilityPicker: View {
    @Binding var selection: BandVisibility

    var body: some View {
        Picker("Toolbar", selection: $selection) {
            Text("Always").tag(BandVisibility.always)
            Text("On Hover").tag(BandVisibility.onHover)
        }
    }
}

struct PaperSeriesPicker: View {
    @Binding var selection: ViewPaperSeries

    var body: some View {
        Picker("Paper on Screen", selection: $selection) {
            ForEach(ViewPaperSeries.allCases, id: \.self) { series in
                Text(series.title).tag(series)
            }
        }
    }
}

extension ViewPaperSeries {
    var title: LocalizedStringKey {
        switch self {
        case .a: "A4 / A3"
        case .b: "B5 / B4"
        }
    }

    var name: String {
        switch self {
        case .a: String(localized: "A4 / A3")
        case .b: String(localized: "B5 / B4")
        }
    }

    /// The sheet the figures count, without the "(JIS)" the print layouts carry.
    var sheetName: String { self == .a ? "A4" : "B5" }
}

extension ViewOptions.Transition {
    var title: LocalizedStringKey {
        switch self {
        case .scroll: "Scroll"
        case .instant: "Switch"
        case .slide: "Slide"
        case .fade: "Fade"
        case .cover: "Cover Slide"
        case .reveal: "Reveal"
        case .wipe: "Wipe"
        case .zoom: "Zoom"
        case .pageCurl: "Page Curl"
        }
    }

    var name: String {
        switch self {
        case .scroll: String(localized: "Scroll")
        case .instant: String(localized: "Switch")
        case .slide: String(localized: "Slide")
        case .fade: String(localized: "Fade")
        case .cover: String(localized: "Cover Slide")
        case .reveal: String(localized: "Reveal")
        case .wipe: String(localized: "Wipe")
        case .zoom: String(localized: "Zoom")
        case .pageCurl: String(localized: "Page Curl")
        }
    }

    var symbol: String {
        switch self {
        case .scroll: "scroll"
        case .instant: "square.on.square"
        case .slide: "rectangle.righthalf.inset.filled.arrow.right"
        case .fade: "circle.lefthalf.filled"
        case .cover: "square.on.square"
        case .reveal: "square.stack"
        case .wipe: "rectangle.lefthalf.filled"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        case .pageCurl: "book.pages"
        }
    }
}

extension DisplayUnit {
    /// The pages as they stand on screen from left to right. An empty side of a spread draws nothing, so a lone cover
    /// is one sheet.
    var visualPages: [Int] {
        switch self {
        case .single(let page): [page]
        case .spread(let left, let right): [left, right].compactMap { $0 }
        }
    }

    /// "3" or "2–3", for VoiceOver.
    var pageRangeText: String {
        guard let first = pages.first, let last = pages.last else { return "" }
        return first == last ? "\(first)" : "\(first)–\(last)"
    }
}

/// A display unit drawn as small paper: one sheet for a lone page, two joined sheets for a facing pair. The sheets stay
/// white in the dark appearance, as the paper does.
struct SpreadGlyph: View {
    let unit: DisplayUnit
    var isCurrent = false

    static let paperWidth: CGFloat = 22
    /// The proportion of the A-series paper on screen (595 × 842).
    static let paperHeight: CGFloat = 31

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(unit.visualPages.enumerated()), id: \.offset) { _, page in
                sheet(page)
            }
        }
        .shadow(color: PrintPalette.paperShadow.opacity(0.5), radius: 1, y: 0.5)
        .background {
            // Outside the sheets, so that picking the current unit does not move its neighbours.
            if isCurrent {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2).padding(-4)
            }
        }
        .accessibilityHidden(true)
    }

    private func sheet(_ page: Int) -> some View {
        // Four-digit page numbers shrink to stay on the sheet.
        Text(verbatim: "\(page)")
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.black.opacity(0.75))
            .lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 2)
            .frame(width: Self.paperWidth, height: Self.paperHeight)
            .background(PrintPalette.paper)
            .overlay { Rectangle().strokeBorder(PrintPalette.paperRing, lineWidth: 0.5) }
    }
}

/// What "Show First Page Alone" makes of the pages, as the first few groups of a five-page document.
private struct CoverSample: View {
    let direction: ViewOptions.Direction
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let units = SpreadLayout.units(pageCount: 5, layout: .spread, showsCoverAlone: true, direction: direction)
        HStack(spacing: SpreadMap.spacing) {
            ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                SpreadGlyph(unit: unit)
            }
            Text(verbatim: "…").foregroundStyle(.secondary)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityHidden(true)
    }
}

/// A miniature of the current display unit that follows the options as they change.
private struct SpreadSample: View {
    let options: ViewOptions
    let unit: DisplayUnit?

    var body: some View {
        HStack(spacing: 0) {
            switch unit ?? (options.layout == .single ? .single(1) : .spread(left: nil, right: 1)) {
            case .single(let page): MiniPage(number: page)
            case .spread(let left, let right):
                MiniPage(number: left)
                MiniPage(number: right)
            }
        }
        .frame(height: 72)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
        .overlay(alignment: .topLeading) {
            Text("Sample").font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
        }
        .animation(.easeInOut(duration: 0.25), value: options)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: unit?.pageRangeText ?? ""))
    }
}

private struct MiniPage: View {
    let number: Int?

    var body: some View {
        ZStack {
            if let number {
                Rectangle().fill(.white).shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                // Four-digit page numbers shrink to stay on the miniature page.
                Text(verbatim: "\(number)").font(.system(size: 26, weight: .semibold)).foregroundStyle(.black)
                    .lineLimit(1).minimumScaleFactor(0.4).padding(.horizontal, 4)
            } else {
                Rectangle().fill(.clear)
            }
        }
        .aspectRatio(595 / 842, contentMode: .fit)
    }
}

/// The display units around the current one as small paper; the current unit is outlined and a click jumps to it. A
/// lone page is one sheet wide and a facing pair two, whatever the page numbers, so the strip keeps its shape at any
/// page count; units that do not fit are left out behind an ellipsis.
struct SpreadMap: View {
    let units: [DisplayUnit]
    let current: Int?
    let onSelect: (DisplayUnit) -> Void

    static let spacing: CGFloat = 8
    static let ellipsisWidth: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let range = SpreadLayout.visibleRange(
                unitCount: units.count, current: current,
                capacity: Self.capacity(
                    unitCount: units.count, width: proxy.size.width, tileWidth: Self.tileWidth(for: units)))
            HStack(spacing: Self.spacing) {
                if range.lowerBound > 0 { ellipsis }
                ForEach(range, id: \.self) { index in
                    tile(units[index], isCurrent: index == current)
                }
                if range.upperBound < units.count { ellipsis }
            }
        }
        .frame(height: SpreadGlyph.paperHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spreads")
    }

    private func tile(_ unit: DisplayUnit, isCurrent: Bool) -> some View {
        Button {
            onSelect(unit)
        } label: {
            SpreadGlyph(unit: unit, isCurrent: isCurrent)
                // Reaches halfway to the next tile, so that the gap between small sheets is not a dead zone.
                .contentShape(.interaction, Rectangle().inset(by: -Self.spacing / 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: unit.pageRangeText))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var ellipsis: some View {
        Text(verbatim: "…").foregroundStyle(.secondary).frame(width: Self.ellipsisWidth)
    }

    /// The width of the widest tile of the document: two sheets when it has facing pairs, otherwise one.
    static func tileWidth(for units: [DisplayUnit]) -> CGFloat {
        CGFloat(units.map { $0.visualPages.count }.max() ?? 1) * SpreadGlyph.paperWidth
    }

    /// How many tiles fit into `width`; when not all of them do, room is kept for an ellipsis on either side.
    static func capacity(unitCount: Int, width: CGFloat, tileWidth: CGFloat) -> Int {
        let slot = tileWidth + spacing
        guard slot > 0, width > 0 else { return 0 }
        let all = Int((width + spacing) / slot)
        guard unitCount > all else { return unitCount }
        return max(Int((width - 2 * (ellipsisWidth + spacing) + spacing) / slot), 0)
    }
}

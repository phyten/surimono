import SurimonoCore
import SwiftUI

// Frequent choices stay on the band; this popover keeps the remaining document values under the strip of spreads.
struct ViewOptionsPopover: View {
    @Bindable var model: DocumentViewModel
    /// The longest row label and the widest value control in the current language, measured out of sight.
    @State private var labelWidth: CGFloat = 0
    @State private var controlWidth: CGFloat = 0

    /// The widest the popover gets; a narrower content makes it narrower, so that it covers no more of the page than
    /// its rows need.
    private static let maximumWidth: CGFloat = 560
    /// Room for the title, the file name and the close button, and for the row of the reset and the setting sets.
    private static let minimumWidth: CGFloat = 340
    private static let padding: CGFloat = 16
    private static let columnSpacing: CGFloat = 12
    /// The display units the strip of small pages shows at most, around the current one.
    static let spreadMapLimit = 8
    private static let labels: [LocalizedStringKey] = [
        "Page Arrangement", "Reading Direction", "Scroll Direction", "Show First Page Alone", "Join Pages", "Toolbar",
        "Paper Size Series", "Text Margins", "Text Size",
    ]

    /// Labels over their settings, where the longest label beside the widest setting would not fit the popover: a
    /// menu squeezed into what the labels leave is cut, as the reading direction was in Spanish.
    private var stacksLabels: Bool {
        labelWidth + Self.columnSpacing + controlWidth > Self.maximumWidth - 2 * Self.padding
    }

    /// The longest row and the margins around it, in the current language. Until the copies are measured it is the
    /// widest, which the first layout then narrows.
    private var width: CGFloat {
        guard labelWidth > 0, controlWidth > 0 else { return Self.maximumWidth }
        let rows = stacksLabels ? max(labelWidth, controlWidth) : labelWidth + Self.columnSpacing + controlWidth
        return min(Self.maximumWidth, max(Self.minimumWidth, (rows + 2 * Self.padding).rounded(.up)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("View Options").font(.headline)
                    Text(verbatim: model.displayName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                PopoverCloseButton()
            }
            Grid(alignment: .leading, horizontalSpacing: Self.columnSpacing, verticalSpacing: stacksLabels ? 10 : 12) {
                heading("On Screen")
                // The pages as the options below arrange them: it changes as they do, with the current unit marked.
                if !model.displayUnits.isEmpty {
                    // How the pages stand under these options; a click on one goes there, but it arranges nothing.
                    row("Page Arrangement", fills: true) {
                        SpreadMap(units: model.displayUnits, current: currentUnitIndex, limit: Self.spreadMapLimit) {
                            unit in
                            if let first = unit.pages.first { model.paper.goToPage(index: first - 1) }
                        }
                    }
                }
                row("Reading Direction") { directionPicker(option(\.direction)) }
                row("Scroll Direction") {
                    Picker("Scroll Direction", selection: option(\.scrollAxis)) {
                        Text("Vertical").tag(ViewOptions.ScrollAxis.vertical)
                        Text("Horizontal").tag(ViewOptions.ScrollAxis.horizontal)
                    }
                    .disabled(!model.viewOptions.usesScrollAxis)
                }
                row("Show First Page Alone") {
                    Toggle("Show First Page Alone", isOn: option(\.showsCoverAlone))
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(!model.viewOptions.usesCoverOption)
                }
                if model.viewOptions.canJoinPages, model.viewLogicalMargin != nil {
                    row("Join Pages") {
                        Toggle("Join Pages", isOn: option(\.joinsPages))
                            .toggleStyle(.switch).controlSize(.small)
                    }
                }
                row("Toolbar") { BandVisibilityPicker(selection: $model.bandVisibility) }
                // The paper series decides the paper the document prints on as well, so it goes with the text.
                if model.offersPaperSeries || model.marginsApply || model.usesPrintTheme {
                    heading("Paper and Text")
                }
                if model.offersPaperSeries {
                    row("Paper Size Series") { paperSeriesPicker(seriesBinding) }
                }
                if model.marginsApply {
                    row("Text Margins") { MarginControl(model: model) }
                }
                if model.usesPrintTheme {
                    row("Text Size") {
                        TextSizeField(title: "Text Size", scale: model.textScale) { model.setTextScale($0) }
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            HStack(spacing: 8) {
                // The setting sets are a separate, stronger choice on the other side.
                // Only a document with settings of its own has something to reset; a dimmed link read as broken.
                if model.hasSavedSettings {
                    Button("Reset This Document") { model.resetDocumentSettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(PrintPalette.ai)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SettingSetMenu(preferences: model.preferences, library: model.library, model: { model })
                    .fixedSize()
            }
        }
        .padding(Self.padding)
        .frame(width: width)
        .background(alignment: .topLeading) { measurements }
        .paperOverlayBackground(cornerRadius: 0, tintOpacity: 0.985)
        .clearsInitialFocus()
    }

    private var currentUnitIndex: Int? {
        SpreadLayout.unitIndex(containing: model.currentPageIndex + 1, in: model.displayUnits)
    }

    /// A setting with its label: beside it, right-aligned in a column as wide as the longest label, or over it.
    /// `fills` lets a setting with no width of its own, the strip of pages, take the column's width without setting it.
    @ViewBuilder private func row(
        _ key: LocalizedStringKey, fills: Bool = false, @ViewBuilder content: () -> some View
    ) -> some View {
        if stacksLabels {
            GridRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(key).foregroundStyle(PrintPalette.ink2)
                    content()
                }
                .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
                .gridCellUnsizedAxes(fills ? .horizontal : [])
            }
        } else {
            GridRow {
                Text(key).foregroundStyle(PrintPalette.ink2).gridColumnAlignment(.trailing)
                // Every setting asks for the measured width, so the column is as wide as the widest setting needs and
                // the popover's width (taken from the same measure) leaves no room beside it.
                content()
                    .frame(
                        minWidth: fills ? nil : controlWidth, maxWidth: fills ? .infinity : nil, alignment: .leading
                    )
                    .gridCellUnsizedAxes(fills ? .horizontal : [])
            }
        }
    }

    private func heading(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 13, weight: .bold))
            .padding(.top, 4)
            .gridCellColumns(stacksLabels ? 1 : 2)
            .gridCellAnchor(.leading)
    }

    private var seriesBinding: Binding<PaperSeries> {
        Binding(get: { model.layout.series }, set: { model.choosePaperSeries($0) })
    }

    /// Named as the print screen's menu names the series ("A Sizes"), so that the two places agree.
    private func paperSeriesPicker(_ selection: Binding<PaperSeries>) -> some View {
        Picker("Paper Size Series", selection: selection) {
            ForEach(PaperSeries.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
        }
    }

    private func directionPicker(_ selection: Binding<ViewOptions.Direction>) -> some View {
        Picker("Reading Direction", selection: selection) {
            Text("Left to Right · Bound Left").tag(ViewOptions.Direction.leftToRight)
            Text("Right to Left · Bound Right").tag(ViewOptions.Direction.rightToLeft)
        }
        .pickerStyle(.menu)
    }

    /// Copies of the labels and of the widest settings, which decide whether the labels go over the settings and how
    /// wide the popover is. A menu needs its whole width; a segmented picker shares out what it gets between its
    /// narrowest and its own width, so it counts at its narrowest.
    private var measurements: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.labels.indices, id: \.self) { Text(Self.labels[$0]).fixedSize() }
            }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { width in
                if labelWidth != width { labelWidth = width }
            }
            VStack(alignment: .leading, spacing: 0) {
                directionPicker(.constant(.leftToRight)).fixedSize()
                NarrowestWidth { BandVisibilityPicker(selection: .constant(.always)).pickerStyle(.segmented) }
                    .fixedSize()
                NarrowestWidth { paperSeriesPicker(.constant(.a)).pickerStyle(.segmented) }.fixedSize()
            }
            .labelsHidden()
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { width in
                if controlWidth != width { controlWidth = width }
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func option<Value>(_ keyPath: WritableKeyPath<ViewOptions, Value>) -> Binding<Value> {
        model.viewOption(keyPath)
    }
}

/// Its one view at the narrowest it goes, as a segmented picker that shares out the width it is given.
private struct NarrowestWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: 0, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The settings' default and the document's own choice of when the bands show.
struct BandVisibilityPicker: View {
    @Binding var selection: BandVisibility

    var body: some View {
        Picker("Toolbar Visibility", selection: $selection) {
            Text("Always").tag(BandVisibility.always)
            Text("On Hover").tag(BandVisibility.onHover)
        }
    }
}

struct PaperSeriesPicker: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Picker("Paper Series", selection: Binding(get: { model.layout.series }, set: { model.choosePaperSeries($0) })) {
            ForEach(PaperSeries.allCases, id: \.self) { series in
                Text(series.title).tag(series)
            }
        }
    }
}

extension PaperSeries {
    var title: LocalizedStringKey {
        switch self {
        case .a: "A4 / A3"
        case .b: "B5 / B4"
        case .letter: "Letter / Tabloid"
        }
    }

    var name: String {
        switch self {
        case .a: String(localized: "A4 / A3")
        case .b: String(localized: "B5 / B4")
        case .letter: String(localized: "Letter / Tabloid")
        }
    }
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
                RoundedRectangle(cornerRadius: 4).strokeBorder(PrintPalette.ai, lineWidth: 2).padding(-4)
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

/// The display units around the current one as small paper; the current unit is outlined and a click jumps to it. A
/// lone page is one sheet wide and a facing pair two, whatever the page numbers, so the strip keeps its shape at any
/// page count; units that do not fit are left out behind an ellipsis.
struct SpreadMap: View {
    let units: [DisplayUnit]
    let current: Int?
    /// The most units shown at once; a long row of small pages only repeats the numbers.
    var limit: Int?
    let onSelect: (DisplayUnit) -> Void

    static let spacing: CGFloat = 8
    static let ellipsisWidth: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let range = SpreadLayout.visibleRange(
                unitCount: units.count, current: current,
                capacity: Self.capacity(
                    unitCount: units.count, width: proxy.size.width, tileWidth: Self.tileWidth(for: units),
                    limit: limit))
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
    static func capacity(unitCount: Int, width: CGFloat, tileWidth: CGFloat, limit: Int? = nil) -> Int {
        let slot = tileWidth + spacing
        guard slot > 0, width > 0 else { return 0 }
        let all = min(Int((width + spacing) / slot), limit ?? .max)
        guard unitCount > all else { return unitCount }
        let fitting = max(Int((width - 2 * (ellipsisWidth + spacing) + spacing) / slot), 0)
        return min(fitting, limit ?? .max)
    }
}

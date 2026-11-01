import SurimonoCore
import SwiftUI

// Frequent choices stay on the band; this popover keeps the remaining document values beside a live sample.
struct ViewOptionsPopover: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("View").font(.headline)
                Text(verbatim: model.displayName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            SpreadSample(options: model.viewOptions, unit: currentUnit)
            SpreadMap(units: model.displayUnits, current: currentUnitIndex) { unit in
                if let first = unit.pages.first { model.paper.goToPage(index: first - 1) }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    rowLabel("Direction")
                    Picker("Direction", selection: option(\.direction)) {
                        Text("Left to Right · Bound Left").tag(ViewOptions.Direction.leftToRight)
                        Text("Right to Left · Bound Right").tag(ViewOptions.Direction.rightToLeft)
                    }
                    .pickerStyle(.menu)
                }
                GridRow {
                    rowLabel("Scrolling")
                    Picker("Scrolling", selection: option(\.scrollAxis)) {
                        Text("Vertical").tag(ViewOptions.ScrollAxis.vertical)
                        Text("Horizontal").tag(ViewOptions.ScrollAxis.horizontal)
                    }
                    .disabled(!model.viewOptions.usesScrollAxis)
                }
                GridRow {
                    rowLabel("Cover")
                    HStack(spacing: 8) {
                        Toggle("Show Alone", isOn: option(\.showsCoverAlone))
                            .toggleStyle(.switch).controlSize(.small)
                        Text(verbatim: coverSample).font(.caption).monospaced().foregroundStyle(.secondary)
                    }
                    .disabled(!model.viewOptions.usesCoverOption)
                }
                if model.viewOptions.isSinglePageContinuous, model.viewLogicalMargin != nil {
                    GridRow {
                        rowLabel("Join Pages")
                        Toggle("Join Pages", isOn: option(\.joinsPages))
                            .toggleStyle(.switch).controlSize(.small)
                    }
                }
                if model.marginsApply {
                    GridRow {
                        rowLabel("Margins")
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
            HStack {
                if model.hasSavedSettings {
                    Text("Using this document’s settings")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset to Defaults") { model.resetDocumentSettings() }
                    .buttonStyle(.link)
                    .disabled(!model.hasSavedSettings)
            }
        }
        .padding(16)
        .frame(width: 560)
        .paperOverlayBackground(cornerRadius: 0, tintOpacity: 0.985)
    }

    private var currentUnitIndex: Int? {
        SpreadLayout.unitIndex(containing: model.currentPageIndex + 1, in: model.displayUnits)
    }

    private var currentUnit: DisplayUnit? {
        currentUnitIndex.map { model.displayUnits[$0] }
    }

    private var coverSample: String {
        let units = SpreadLayout.units(
            pageCount: 5, layout: .spread, showsCoverAlone: true, direction: model.viewOptions.direction)
        return units.map(\.compactText).joined(separator: " ") + " …"
    }

    private func rowLabel(_ key: LocalizedStringKey) -> some View {
        Text(key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func option<Value>(_ keyPath: WritableKeyPath<ViewOptions, Value>) -> Binding<Value> {
        model.viewOption(keyPath)
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

/// The label of one tile of the spread map, on one line in the font the tile width is measured with.
struct SpreadMapLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(Font(SpreadMap.font as CTFont)).lineLimit(1).fixedSize()
    }
}

extension DisplayUnit {
    /// "[ |1]", "[2|3]" or "[4]".
    var compactText: String {
        switch self {
        case .single(let page): "[\(page)]"
        case .spread(let left, let right): "[\(left.map(String.init) ?? " ")|\(right.map(String.init) ?? " ")]"
        }
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
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
        .overlay(alignment: .topLeading) {
            Text("Sample").font(.caption2).foregroundStyle(.secondary).padding(6)
        }
        .animation(.easeInOut(duration: 0.25), value: options)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: unit?.compactText ?? ""))
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

/// The display units around the current one as small tiles; the current tile is highlighted and a click jumps to it.
/// Every tile is as wide as the widest label of the document and never wraps, so the strip keeps its shape at any page
/// count; units that do not fit are left out behind an ellipsis.
struct SpreadMap: View {
    let units: [DisplayUnit]
    let current: Int?
    let onSelect: (DisplayUnit) -> Void

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    static let spacing: CGFloat = 6
    static let tileHeight: CGFloat = 18
    static let ellipsisWidth: CGFloat = 12
    private static let horizontalPadding: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let tileWidth = Self.tileWidth(for: units)
            let range = SpreadLayout.visibleRange(
                unitCount: units.count, current: current,
                capacity: Self.capacity(unitCount: units.count, width: proxy.size.width, tileWidth: tileWidth))
            HStack(spacing: Self.spacing) {
                if range.lowerBound > 0 { ellipsis }
                ForEach(range, id: \.self) { index in
                    tile(units[index], isCurrent: index == current, width: tileWidth)
                }
                if range.upperBound < units.count { ellipsis }
            }
        }
        .frame(height: Self.tileHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spreads")
    }

    private func tile(_ unit: DisplayUnit, isCurrent: Bool, width: CGFloat) -> some View {
        Button {
            onSelect(unit)
        } label: {
            SpreadMapLabel(text: unit.compactText)
                .frame(width: width, height: Self.tileHeight)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(
                            isCurrent ? Color.accentColor : Color.secondary.opacity(0.4),
                            lineWidth: isCurrent ? 1.5 : 0.75)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var ellipsis: some View {
        Text(verbatim: "…").foregroundStyle(.secondary).frame(width: Self.ellipsisWidth)
    }

    /// The width of a tile for the longest label the document can have, with "8" standing for every digit.
    static func tileWidth(for units: [DisplayUnit]) -> CGFloat {
        let digits = String(repeating: "8", count: String(units.flatMap(\.pages).max() ?? 1).count)
        let isSpread = units.contains { if case .spread = $0 { true } else { false } }
        let widest = isSpread ? "[\(digits)|\(digits)]" : "[\(digits)]"
        let textWidth = (widest as NSString).size(withAttributes: [.font: font]).width
        return (textWidth + horizontalPadding * 2).rounded(.up)
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

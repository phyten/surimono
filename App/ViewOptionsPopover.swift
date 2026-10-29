import SurimonoCore
import SwiftUI

/// The standard popover behind "View Options": a live sample and a map of the spreads on top, the options in the
/// middle, and the choice spelled out as a sentence below.
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
                    rowLabel("View")
                    Picker("View", selection: option(\.layout)) {
                        ForEach(ViewOptions.Layout.allCases, id: \.self) { layout in
                            Label(layout.title, systemImage: layout.symbol).tag(layout)
                        }
                    }
                }
                GridRow {
                    rowLabel("Direction")
                    Picker("Direction", selection: option(\.direction)) {
                        Text("Left to Right · Bound Left").tag(ViewOptions.Direction.leftToRight)
                        Text("Right to Left · Bound Right").tag(ViewOptions.Direction.rightToLeft)
                    }
                }
                GridRow {
                    rowLabel("Scrolling")
                    Picker("Scrolling", selection: option(\.scrollAxis)) {
                        Text("Vertical").tag(ViewOptions.ScrollAxis.vertical)
                        Text("Horizontal").tag(ViewOptions.ScrollAxis.horizontal)
                    }
                }
                GridRow {
                    rowLabel("Page Turn")
                    Picker("Page Turn", selection: option(\.transition)) {
                        ForEach(model.viewOptions.availableTransitions, id: \.self) { transition in
                            Text(transition.title).tag(transition)
                        }
                    }
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
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(verbatim: ViewOptionsSummary.sentence(for: model.viewOptions))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if let hash = model.contentHash {
                    Text(verbatim: "sha256 \(hash.abbreviated)…")
                        .font(.caption).monospaced().foregroundStyle(.secondary)
                        .help("Settings are remembered for this content, whatever the file is called.")
                }
                Spacer()
                Button("Reset to Defaults") { model.resetDocumentSettings() }
                    .buttonStyle(.link)
                    .disabled(!model.hasSavedSettings)
            }
        }
        .padding(16)
        .frame(width: 460)
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
        Binding(
            get: { model.viewOptions[keyPath: keyPath] },
            set: { value in model.updateViewOptions { $0[keyPath: keyPath] = value } })
    }
}

extension ViewOptions.Transition {
    var title: LocalizedStringKey {
        switch self {
        case .scroll: "Scroll"
        case .instant: "Switch"
        case .slide: "Slide"
        case .fade: "Fade"
        case .pageCurl: "Page Curl"
        }
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

/// Spells out the chosen options, so the effect of each control is clear without trying it.
enum ViewOptionsSummary {
    static func sentence(for options: ViewOptions) -> String {
        var parts: [String] = []
        switch options.layout {
        case .spread: parts.append(String(localized: "Shows this document as spreads. "))
        case .single: parts.append(String(localized: "Shows this document one page at a time. "))
        case .twoPageScroll:
            parts.append(String(localized: "Shows this document as spreads and scrolls one spread at a time. "))
        }
        switch options.direction {
        case .leftToRight: parts.append(String(localized: "Pages turn from left to right (bound on the left). "))
        case .rightToLeft: parts.append(String(localized: "Pages turn from right to left (bound on the right). "))
        }
        if options.usesCoverOption, options.showsCoverAlone {
            parts.append(String(localized: "The cover is shown alone. "))
        }
        switch options.scrollAxis {
        case .vertical: parts.append(String(localized: "Scrolling is vertical. "))
        case .horizontal: parts.append(String(localized: "Scrolling is horizontal. "))
        }
        switch options.transition {
        case .scroll: parts.append(String(localized: "Pages scroll continuously."))
        case .instant: parts.append(String(localized: "Pages switch instantly."))
        case .slide: parts.append(String(localized: "Pages slide into place."))
        case .fade: parts.append(String(localized: "Pages fade into each other."))
        case .pageCurl: parts.append(String(localized: "Pages curl like paper."))
        }
        return parts.joined().trimmingCharacters(in: .whitespaces)
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
            case .spread(nil, 1?), .spread(1?, nil):
                // PDFKit shows a cover alone in the middle of the spread.
                MiniPage(number: 1)
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
                Text(verbatim: "\(number)").font(.system(size: 26, weight: .semibold)).foregroundStyle(.black)
            } else {
                Rectangle().fill(.clear)
            }
        }
        .aspectRatio(595 / 842, contentMode: .fit)
    }
}

/// Every display unit as a small tile; the current one is highlighted and a click jumps to it.
private struct SpreadMap: View {
    let units: [DisplayUnit]
    let current: Int?
    let onSelect: (DisplayUnit) -> Void
    private let limit = 14

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(units.prefix(limit).enumerated()), id: \.offset) { index, unit in
                Button {
                    onSelect(unit)
                } label: {
                    Text(verbatim: unit.compactText)
                        .font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 4).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(
                                    index == current ? Color.accentColor : Color.secondary.opacity(0.4),
                                    lineWidth: index == current ? 1.5 : 0.75))
                }
                .buttonStyle(.plain)
            }
            if units.count > limit {
                Text(verbatim: "…").foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Spreads")
    }
}

import SurimonoCore
import SwiftUI

/// The headings of the document, deepest indented, with the chapter being read picked out.
private struct OutlineList: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        let entries = model.outlineEntries
        let current = model.currentOutlineEntry
        let top = entries.map(\.level).min() ?? 1
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        OutlineRow(entry: entry, indent: entry.level - top, isCurrent: index == current) {
                            model.goToOutlineEntry(entry)
                        }
                        .id(index)
                    }
                }
            }
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .accessibilityLabel("Contents")
    }
}

private struct OutlineRow: View {
    let entry: OutlineEntry
    let indent: Int
    let isCurrent: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    init(entry: OutlineEntry, indent: Int, isCurrent: Bool, onSelect: @escaping () -> Void) {
        self.entry = entry
        self.indent = indent
        self.isCurrent = isCurrent
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text(verbatim: entry.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let page = entry.pageIndex {
                    Text(verbatim: "\(page + 1)").monospacedDigit().foregroundStyle(PrintPalette.ink2)
                }
            }
            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? PrintPalette.ai : PrintPalette.ink)
            .padding(.leading, 8 + CGFloat(min(indent, 4)) * 12)
            .padding(.trailing, 8)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? PrintPalette.aiTint2 : isHovered ? PrintPalette.hover : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry.pageIndex == nil)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

struct OutlinePopover: View {
    @Bindable var model: DocumentViewModel

    private static let rowHeight: CGFloat = 33
    private static let maximumListHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Contents").font(.system(size: 13, weight: .bold)).foregroundStyle(PrintPalette.ink)
            OutlineList(model: model)
                .frame(height: min(CGFloat(model.outlineEntries.count) * Self.rowHeight, Self.maximumListHeight))
        }
        .padding(12)
        .frame(width: 286)
        .paperOverlayBackground(cornerRadius: 0, tintOpacity: 0.985)
    }
}

/// The table of contents kept open beside the paper; the paper makes room for it.
struct OutlineDrawer: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Contents").font(.system(size: 13, weight: .bold))
                Spacer()
                Button {
                    model.isOutlineDrawerOpen = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
            }
            .padding(.horizontal, 8)
            OutlineList(model: model)
        }
        .foregroundStyle(PrintPalette.ink)
        .padding(12)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PrintPalette.raised)
        .overlay(alignment: .trailing) { Divider() }
    }
}

/// The figures a reader wants before printing. Only documents laid out from text have an amount of text to tell.
struct DocumentFiguresPopover: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Document Figures").font(.system(size: 13, weight: .bold)).foregroundStyle(PrintPalette.ink)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                if let statistics = model.documentStatistics {
                    GridRow {
                        figure(
                            String(localized: "Characters"),
                            String(
                                format: String(localized: "%@ characters"),
                                statistics.characters.formatted(.number.locale(Locale(identifier: model.language)))))
                        figure(
                            String(localized: "Reading Time"),
                            String(format: String(localized: "About %lld min"), statistics.readingMinutes))
                    }
                }
                GridRow {
                    figure(
                        String(localized: "Pages"),
                        String(format: String(localized: "%lld pages"), model.pageCount))
                    figure(
                        String(format: String(localized: "If printed double-sided on %@"), model.paperSeries.sheetName),
                        String(
                            format: String(localized: "%lld sheets"),
                            DocumentStatistics.duplexSheets(pageCount: model.pageCount)))
                }
            }
            Divider().padding(.top, 4)
            Button("Check on the Print Tray") { model.checkFiguresOnTray() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PrintPalette.ai)
        }
        .padding(12)
        .frame(width: 286, alignment: .leading)
        .paperOverlayBackground(cornerRadius: 0, tintOpacity: 0.985)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
            Text(verbatim: value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(PrintPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

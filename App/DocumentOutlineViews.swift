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
    @Environment(\.colorScheme) private var colorScheme

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
            // The chapter being read is picked out by the accent color's tint and the weight; the text stays ink, which
            // keeps its contrast whatever accent color the Mac is set to.
            .foregroundStyle(PrintPalette.ink)
            .padding(.leading, 8 + CGFloat(min(indent, 4)) * 12)
            .padding(.trailing, 8)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isCurrent
                            ? Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.16)
                            : isHovered ? PrintPalette.hover : .clear)
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
        SidePanel("Contents") {
            PanelIconButton("xmark", label: "Close") { model.isOutlineDrawerOpen = false }
        } content: {
            OutlineList(model: model)
        }
    }
}

/// The figures a reader wants before printing: the pages and the sheets they come to first, then, for documents laid
/// out from text, the amount of text.
struct DocumentFiguresPopover: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Document Info").font(.system(size: 13, weight: .bold)).foregroundStyle(PrintPalette.ink)
            // The note belongs to the sheets, so it stays right under them and the text figures follow it.
            VStack(alignment: .leading, spacing: 4) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        figure(
                            String(localized: "Pages"),
                            String(format: String(localized: "%lld pages"), model.pageCount))
                        if let tray = model.currentTrayFigures {
                            figure(
                                String(localized: "With the Current Print Settings"),
                                String(format: String(localized: "%1$@, %2$lld sheets"), tray.paper, tray.sheetCount))
                        } else {
                            figure(
                                String(
                                    format: String(localized: "For Reference: %@, Double-Sided"),
                                    model.paperSeries.sheetName),
                                String(
                                    format: String(localized: "%lld sheets"),
                                    DocumentStatistics.duplexSheets(pageCount: model.pageCount)))
                        }
                    }
                }
                if model.currentTrayFigures == nil {
                    Text("Does not count added contents or note pages.")
                        .font(.system(size: 11))
                        .foregroundStyle(PrintPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let statistics = model.documentStatistics {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
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
                .padding(.top, 4)
            }
            Divider().padding(.top, 4)
            Button("Check on the Print Screen") { model.checkFiguresOnTray() }
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
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(PrintPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

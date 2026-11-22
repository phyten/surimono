import SurimonoCore
import SwiftUI

/// The headings of the document, deepest indented, with the chapter being read picked out.
private struct OutlineList: View {
    @Bindable var model: DocumentViewModel
    @State private var isHovered = false

    var body: some View {
        let entries = model.outlineEntries
        let current = model.currentOutlineEntry
        let top = entries.map(\.level).min() ?? 1
        VStack(alignment: .leading, spacing: 8) {
            // The marks stay above the headings: the list opens scrolled to the chapter being read, which would hide
            // them.
            if model.outlineFilter.query.isEmpty, !model.bookmarkPages.isEmpty {
                BookmarkList(model: model)
                if !entries.isEmpty { Rectangle().fill(PrintPalette.line).frame(height: DisplayAccessibility.hairline) }
            }
            headings(entries: entries, current: current, top: top)
        }
    }

    private func headings(entries: [OutlineEntry], current: Int?, top: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !model.outlineFilter.query.isEmpty, model.outlineFilter.matches.isEmpty {
                        Text("No Matching Headings").font(.system(size: 13)).foregroundStyle(PrintPalette.ink2)
                            .padding(.vertical, 8)
                    }
                    ForEach(model.outlineFilter.matches, id: \.self) { index in
                        let entry = entries[index]
                        OutlineRow(
                            entry: entry, indent: model.outlineFilter.query.isEmpty ? entry.level - top : 0,
                            isCurrent: index == current,
                            isSelected: !model.outlineFilter.query.isEmpty && model.outlineFilter.selection == index
                        ) {
                            model.outlineFilter.setQuery("", entries: entries)
                            model.goToOutlineEntry(entry)
                            model.paper.focus()
                        }
                        .id(index)
                    }
                }
            }
            .onAppear {
                if model.outlineFilter.query.isEmpty, let current { proxy.scrollTo(current, anchor: .center) }
            }
            .onHover { isHovered = $0 }
            .onChange(of: current) { _, value in
                guard model.outlineFilter.query.isEmpty, !isHovered, let value else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(value, anchor: .center) }
            }
            .onChange(of: model.outlineFilter.selection) { _, value in
                if !model.outlineFilter.query.isEmpty, let value { proxy.scrollTo(value, anchor: .center) }
            }
        }
        .accessibilityLabel("Contents")
    }
}

private struct OutlineRow: View {
    let entry: OutlineEntry
    let indent: Int
    let isCurrent: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    init(entry: OutlineEntry, indent: Int, isCurrent: Bool, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.entry = entry
        self.indent = indent
        self.isCurrent = isCurrent
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text(verbatim: entry.title)
                    .emphasisForDisplayContrast(isSelected || isHovered)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let page = entry.pageIndex {
                    Text(verbatim: "\(page + 1)").monospacedDigit().foregroundStyle(PrintPalette.ink2)
                }
            }
            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
            // The chapter being read is picked out by an indigo wash and the weight; the text stays ink.
            .foregroundStyle(PrintPalette.ink)
            .padding(.leading, 8 + CGFloat(min(indent, 4)) * 12)
            .padding(.trailing, 8)
            .frame(minHeight: 32)
            .background {
                CornerRole.control.shape
                    .fill(
                        isSelected
                            ? PrintPalette.hover
                            : isCurrent
                                ? PrintPalette.aiTint2
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

/// The reader's marks, in the order of the document. More than five scroll on their own.
private struct BookmarkList: View {
    @Bindable var model: DocumentViewModel
    static let rowHeight: CGFloat = 33
    static let headingHeight: CGFloat = 22

    static func height(count: Int) -> CGFloat { headingHeight + CGFloat(min(count, 5)) * rowHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Bookmarks").font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                .padding(.horizontal, 8).frame(height: Self.headingHeight - 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.bookmarkPages, id: \.self) { page in BookmarkRow(model: model, page: page) }
                }
            }
            .frame(height: CGFloat(min(model.bookmarkPages.count, 5)) * Self.rowHeight)
        }
    }
}

private struct BookmarkRow: View {
    @Bindable var model: DocumentViewModel
    let page: Int
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.goToBookmark(page: page)
                model.paper.focus()
            } label: {
                HStack(spacing: 10) {
                    Text(verbatim: model.bookmarkTitle(page: page))
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // A mark with no heading to name it is named by its page already.
                    if model.hasOutline {
                        Text(verbatim: "\(page + 1)").monospacedDigit().foregroundStyle(PrintPalette.ink2)
                    }
                }
                .frame(minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                model.removeBookmark(page: page)
            } label: {
                Image(systemName: "xmark").font(.system(size: 10))
                    .frame(width: 22, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(PrintPalette.ink2)
            .opacity(isHovered ? 1 : 0)
            .accessibilityLabel("Remove Bookmark")
            .help("Remove Bookmark")
        }
        .font(.system(size: 13)).foregroundStyle(PrintPalette.ink)
        .padding(.leading, 8).padding(.trailing, 4)
        .background(CornerRole.control.shape.fill(isHovered ? PrintPalette.hover : .clear))
        .onHover { isHovered = $0 }
    }
}

private struct ContentsTabPicker: View {
    let model: DocumentViewModel

    var body: some View {
        Picker("Contents", selection: Binding(get: { model.contentsTab }, set: model.selectContentsTab)) {
            Text("Contents").tag(DocumentSettings.ContentsPanel.Tab.contents)
            Text("Pages Tab").tag(DocumentSettings.ContentsPanel.Tab.pages)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

struct OutlinePopover: View {
    @Bindable var model: DocumentViewModel

    private static let rowHeight: CGFloat = 33
    private static let maximumListHeight: CGFloat = 420
    private var bookmarkHeight: CGFloat {
        model.outlineFilter.query.isEmpty && !model.bookmarkPages.isEmpty
            ? BookmarkList.height(count: model.bookmarkPages.count) + (model.outlineEntries.isEmpty ? 0 : 17) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.showsContentsTabs {
                    ContentsTabPicker(model: model)
                } else {
                    Text(model.contentsTab == .pages ? "Pages Tab" : "Contents")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(PrintPalette.ink)
                }
                Spacer(minLength: 0)
                PopoverCloseButton()
            }
            if model.contentsTab == .pages {
                ContentsPages(model: model, popover: true).frame(height: Self.maximumListHeight)
                if let bundle = model.imageBundle { BundlePageActions(model: model, bundle: bundle) }
            } else {
                if OutlineFilterState.showsField(count: model.outlineEntries.count) {
                    OutlineSearchField(model: model, autofocus: true).frame(height: 28)
                }
                OutlineList(model: model)
                    .frame(
                        height: min(
                            CGFloat(model.outlineEntries.count) * Self.rowHeight + bookmarkHeight,
                            Self.maximumListHeight))
            }
        }
        .padding(12)
        .frame(width: 286)
        .paperOverlayBackground(nil, tintOpacity: 0.985)
    }
}

/// The table of contents kept open beside the paper; the paper makes room for it.
struct OutlineDrawer: View {
    @Bindable var model: DocumentViewModel
    var availableWidth: CGFloat = .infinity

    private var width: CGFloat {
        // A temporary squeeze of the window must not overwrite the width the reader chose.
        guard availableWidth > 0 else { return model.contentsWidth }
        return min(model.contentsWidth, max(176, availableWidth - 200))
    }

    var body: some View {
        SidePanel(
            model.contentsTab == .pages ? "Pages Tab" : "Contents", width: width,
            showsTitle: !model.showsContentsTabs
        ) {
            if model.showsContentsTabs { ContentsTabPicker(model: model) }
            Spacer(minLength: 0)
            if let bundle = model.imageBundle, bundle.archiveURL == nil, model.contentsTab == .pages {
                PanelIconButton("plus", label: "Add Documents…") { model.chooseDocumentsToAdd() }
            }
            PanelIconButton("xmark", label: "Close") { model.setContentsOpen(false) }
        } content: {
            if model.contentsTab == .pages {
                ContentsPages(model: model, popover: false)
                if let bundle = model.imageBundle { BundlePageActions(model: model, bundle: bundle) }
            } else {
                if OutlineFilterState.showsField(count: model.outlineEntries.count) {
                    OutlineSearchField(model: model, autofocus: false).frame(height: 28)
                }
                OutlineList(model: model)
            }
        }
        .overlay(alignment: .trailing) {
            if model.pageCount > 1 { ContentsDivider(model: model, displayedWidth: width) }
        }
    }
}

private struct ContentsDivider: View {
    let model: DocumentViewModel
    let displayedWidth: CGFloat
    @State private var initialWidth: CGFloat?

    var body: some View {
        Color.clear.frame(width: 6).contentShape(Rectangle())
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = initialWidth ?? displayedWidth
                        initialWidth = start
                        let room = (model.window?.frame.width ?? 680) - 240
                        model.contentsPanel.width = max(176, min(400, room, start + drag.translation.width)).rounded()
                    }
                    .onEnded { _ in initialWidth = nil })
    }
}

/// The figures a reader wants before printing: the pages and the sheets they come to first, then, for documents laid
/// out from text, the amount of text.
struct DocumentFiguresPopover: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Document Info").font(.system(size: 13, weight: .bold)).foregroundStyle(PrintPalette.ink)
                Spacer(minLength: 0)
                PopoverCloseButton()
            }
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
                                    format: String(localized: "If Double-Sided on %@"),
                                    model.layout.sheet.shortName),
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
            Rectangle().fill(PrintPalette.line).frame(height: DisplayAccessibility.hairline).padding(.top, 4)
            Button("Check on the Print Screen") { model.checkFiguresOnTray() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PrintPalette.ai)
        }
        .padding(12)
        .frame(width: 286, alignment: .leading)
        .paperOverlayBackground(nil, tintOpacity: 0.985)
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

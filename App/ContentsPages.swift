import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import UniformTypeIdentifiers

struct PageSection: Identifiable {
    let title: String?
    let pages: Range<Int>
    var id: Int { pages.lowerBound }

    static func sections(count: Int, chapters: [OutlineEntry]) -> [Self] {
        var titles: [Int: String] = [:]
        for chapter in chapters {
            if let page = chapter.pageIndex, (0..<count).contains(page) { titles[page] = chapter.title }
        }
        guard count > 0 else { return [] }
        let starts = Set(titles.keys).union([0]).sorted()
        return zip(starts, starts.dropFirst() + [count]).map { Self(title: titles[$0], pages: $0..<$1) }
    }

    /// Each chapter starts a fresh row. Crossing its heading keeps the column if the next row has that column.
    static func verticalNeighbor(of page: Int, down: Bool, columns: Int, sections: [Self]) -> Int {
        guard let index = sections.firstIndex(where: { $0.pages.contains(page) }) else { return page }
        let pages = sections[index].pages
        let column = (page - pages.lowerBound) % columns
        let row = page - column
        if down {
            let next = row + columns
            if next < pages.upperBound { return min(next + column, pages.upperBound - 1) }
            guard index + 1 < sections.count else { return page }
            let following = sections[index + 1].pages
            return min(following.lowerBound + column, following.upperBound - 1)
        }
        if row > pages.lowerBound { return page - columns }
        guard index > 0 else { return page }
        let previous = sections[index - 1].pages
        let lastRow = previous.upperBound - 1 - (previous.count - 1) % columns
        return min(lastRow + column, previous.upperBound - 1)
    }
}

struct ContentsPages: View {
    let model: DocumentViewModel
    let popover: Bool
    @FocusState private var focused: Bool
    @State private var selection: Int?
    @Environment(\.displayScale) private var scale
    @Environment(\.layoutDirection) private var interfaceDirection

    var body: some View {
        GeometryReader { geometry in
            let columns = !popover && geometry.size.width >= 220 ? 2 : 1
            let width = PageTileSize.availableWidth(
                in: geometry.size.width, columns: columns, bundle: model.imageBundle != nil)
            grid(columns: columns, width: width)
        }
    }

    private func grid(columns: Int, width: CGFloat) -> some View {
        let generation = model.thumbnailGeneration
        let marks = Set(model.bookmarkPages)
        let spreads = model.viewOptions.layout == .spread
        let rtl = model.viewOptions.direction == .rightToLeft
        let rows =
            spreads
            ? SpreadLayout.drawerRows(
                pageCount: model.pageCount,
                showsCoverAlone: model.viewOptions.showsCoverAlone, direction: model.viewOptions.direction,
                columns: columns) : []
        let sections = spreads ? [] : PageSection.sections(count: model.pageCount, chapters: model.chapterEntries)
        let items = model.imageBundle?.items.filter { !model.unreadableImageURLs.contains($0.url) }
        let rightToLeft = spreads ? rtl : interfaceDirection == .rightToLeft
        let horizontalStep = columns == 2 && rightToLeft ? -1 : 1
        let dropGrid = items.map {
            DropSession.PageGrid(readable: $0.map(\.url), columns: columns, rightToLeft: rightToLeft)
        }
        let current = model.currentPageIndex
        let visiblePages = model.visibleReadingPages
        // Bundle tiles own their half of the gutter so a drop directly on the insertion line still lands.
        let spacing: CGFloat = items == nil ? 10 : 0
        let selected = selection ?? current
        @ViewBuilder func cell(_ page: Int, chapter: String?, mate: Int?) -> some View {
            let item = items.flatMap { $0.indices.contains(page) ? $0[page] : nil }
            let tile = PageTile(
                model: model, page: page, generation: generation, width: width,
                scale: scale, chapter: chapter, marked: marks.contains(page), current: visiblePages.contains(page),
                selected: focused && selected == page, rowMate: mate
            ) {
                selection = page
                focused = true
                jump(page, item: item)
            }
            if let item, let items, let bundle = model.imageBundle, let type = bundle.pageDragType {
                tile.modifier(
                    BundlePageDrag(
                        model: model, bundle: bundle, type: type, item: item,
                        readable: items, page: page, columns: columns,
                        rightToLeft: rightToLeft)
                )
                .id(item.url)
            } else {
                tile
            }
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing
                ) {
                    if spreads {
                        ForEach(rows.indices, id: \.self) { index in
                            let row = rows[index]
                            // SwiftUI lays columns out from leading to trailing in the interface language.
                            ForEach(row.indices, id: \.self) { i in
                                let column = interfaceDirection == .rightToLeft ? row.count - 1 - i : i
                                if let page = row[column] {
                                    cell(page, chapter: nil, mate: row.count == 2 ? row[1 - column] : nil).id(page)
                                } else {
                                    Color.clear.frame(height: 1).allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                        }
                    } else {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.pages, id: \.self) { page in
                                    cell(
                                        page, chapter: section.title,
                                        mate: items == nil
                                            ? nil : PageTileSize.rowMate(of: page, in: section.pages, columns: columns)
                                    ).id(page)
                                }
                            } header: {
                                if let title = section.title {
                                    Text(verbatim: title).font(.caption).foregroundStyle(PrintPalette.ink2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityAddTraits(.isHeader)
                                }
                            }
                        }
                    }
                }
                .padding(4)
            }
            .focusable(interactions: .edit)
            .focused($focused)
            .accessibilityLabel("Pages Tab")
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return]) { press in
                // Arrow keys always carry the numeric-pad and function flags.
                guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]), model.pageCount > 0
                else { return .ignored }
                let next: Int
                switch press.key {
                case .upArrow, .downArrow:
                    next =
                        spreads
                        ? SpreadLayout.verticalNeighbor(of: selected, down: press.key == .downArrow, in: rows)
                        : PageSection.verticalNeighbor(
                            of: selected, down: press.key == .downArrow, columns: columns, sections: sections)
                case .leftArrow: next = selected - horizontalStep
                case .rightArrow: next = selected + horizontalStep
                default:
                    let item = items.flatMap { $0.indices.contains(selected) ? $0[selected] : nil }
                    jump(selected, item: item)
                    return .handled
                }
                selection = min(max(0, next), model.pageCount - 1)
                if let selection {
                    if let items, items.indices.contains(selection) {
                        model.imageBundle?.selection = items[selection].url
                    }
                    proxy.scrollTo(selection)
                }
                return .handled
            }
            .onChange(of: current, initial: true) { _, page in
                selection = page
                proxy.scrollTo(page)
            }
            .onChange(of: model.pageCount) { _, count in
                selection = min(selected, max(0, count - 1))
                proxy.scrollTo(current)
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                if model.imageBundle != nil { model.drop.listFrame = $0 }
            }
            .onChange(of: dropGrid, initial: true) { _, grid in model.drop.pageGrid = grid }
            .onDisappear {
                if model.imageBundle != nil {
                    model.drop.listFrame = nil
                    model.drop.pageGrid = nil
                }
            }
        }
    }

    private func jump(_ page: Int, item: ImageBundleModel.Item?) {
        if let item {
            model.goToBundleImage(item.url)
        } else {
            model.jumpToReadingPage(page)
        }
        if popover { model.isOutlinePresented = false }
    }
}

private struct BundlePageDrag: ViewModifier {
    let model: DocumentViewModel
    let bundle: ImageBundleModel
    let type: UTType
    let item: ImageBundleModel.Item
    let readable: [ImageBundleModel.Item]
    let page: Int
    let columns: Int
    let rightToLeft: Bool
    @State private var size: CGSize = .zero
    @State private var insertion: PageGridInsertion?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .help(item.name)
            .background {
                if bundle.flashedURLs.contains(item.url) { CornerRole.control.shape.fill(PrintPalette.aiTint2) }
            }
            .onDrag {
                let provider = NSItemProvider()
                let url = item.url.dataRepresentation
                provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) {
                    completion in
                    completion(url, nil)
                    return nil
                }
                return provider
            }
            .padding(5)
            .contentShape(Rectangle())
            .overlay {
                if let line = insertion?.line {
                    Path(line).fill(PrintPalette.ai).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onDrop(
                of: [type],
                delegate: BundlePageDrop(
                    bundle: bundle, type: type, readable: readable, page: page, size: size, columns: columns,
                    rightToLeft: rightToLeft, insertion: $insertion)
            )
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { frame in
                if size != frame.size { size = frame.size }
                model.drop.rowFrames[item.url] = frame
            }
            .onDisappear {
                insertion = nil
                model.drop.rowFrames[item.url] = nil
            }
    }
}

private struct BundlePageDrop: DropDelegate {
    let bundle: ImageBundleModel
    let type: UTType
    let readable: [ImageBundleModel.Item]
    let page: Int
    let size: CGSize
    let columns: Int
    let rightToLeft: Bool
    @Binding var insertion: PageGridInsertion?

    private func placement(_ info: DropInfo) -> PageGridInsertion {
        PageGridInsertion(point: info.location, tile: size, columns: columns, rightToLeft: rightToLeft)
    }

    func dropEntered(info: DropInfo) { insertion = placement(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = placement(info)
        if insertion != next { insertion = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { insertion = nil }

    func performDrop(info: DropInfo) -> Bool {
        insertion = nil
        guard let provider = info.itemProviders(for: [type]).first else { return false }
        let gap = PageGridGap(readable: readable, page: page, after: placement(info).after)
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let source = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                bundle.move(source, to: gap)
            }
        }
        return true
    }
}

private struct PageTile: View {
    struct Request: Equatable {
        let generation: Int
        let page: Int
        let pixels: Int
    }

    let model: DocumentViewModel
    let page: Int
    let generation: Int?
    let width: CGFloat
    let scale: CGFloat
    let chapter: String?
    let marked: Bool
    let current: Bool
    let selected: Bool
    let rowMate: Int?
    let jump: () -> Void
    #if DEBUG
        @State private var captureID = UUID()
    #endif
    @State private var visible = false
    @State private var loaded: (Request, CGImage)?

    private func aspect(of page: Int) -> CGFloat {
        if let size = model.slideDeck?.size, size.width > 0, size.height > 0 { return size.width / size.height }
        guard let sheet = model.result?.viewDocument.page(at: page) else { return 0.707 }
        let box = sheet.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return 0.707 }
        return sheet.rotation % 180 == 0 ? box.width / box.height : box.height / box.width
    }

    var body: some View {
        let tile = PageTileSize(width: width, aspect: aspect(of: page), rowMateAspect: rowMate.map { aspect(of: $0) })
        // Quantize the long edge so dragging the divider does not generate a bitmap for every point.
        let pixels = min(1024, max(32, Int(ceil(max(tile.paper.height, tile.paper.width) * scale / 32)) * 32))
        let request = visible ? generation.map { Request(generation: $0, page: page, pixels: pixels) } : nil
        Button(action: jump) {
            VStack(spacing: 5) {
                Color.white
                    .overlay {
                        if let loaded, loaded.0 == request {
                            Image(decorative: loaded.1, scale: scale).resizable().scaledToFit()
                                #if DEBUG
                                    .id(loaded.0.generation)
                                    .onAppear {
                                        model.thumbnailDidAppear?(loaded.0.generation)
                                        if model.snapshotContentsTab == .pages {
                                            model.snapshotThumbnailRequests[captureID] = true
                                        }
                                    }
                                #endif
                        }
                    }
                    .frame(width: tile.paper.width, height: tile.paper.height)
                    .overlay(alignment: .topTrailing) {
                        if marked { Image(systemName: "bookmark.fill").foregroundStyle(PrintPalette.ai).padding(3) }
                    }
                    .overlay { if !current { Rectangle().strokeBorder(PrintPalette.line, lineWidth: 1) } }
                    .padding(PageTileSize.framePadding)
                    .background(current ? Color.white : Color.clear)
                    .overlay {
                        if current {
                            Rectangle().strokeBorder(PrintPalette.ai, lineWidth: PageTileSize.currentLineWidth)
                                #if DEBUG
                                    .preference(key: PageCurrentFramePreference.self, value: [page])
                                #endif
                        }
                    }
                    .padding(2)
                    .overlay {
                        if selected {
                            Rectangle().strokeBorder(PrintPalette.ai, style: StrokeStyle(dash: [2, 2]))
                                #if DEBUG
                                    .preference(key: PageFocusRingPreference.self, value: [page])
                                #endif
                        }
                    }
                    .frame(height: tile.paperAreaHeight + 4)
                Text(verbatim: String(page + 1)).monospacedDigit().font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(
            Text(
                verbatim: chapter.map {
                    String(format: String(localized: "Page %1$lld, %2$@"), page + 1, $0)
                } ?? String(format: String(localized: "Page %lld"), page + 1))
        )
        .accessibilityValue(marked ? Text("Bookmarked") : Text(verbatim: ""))
        .accessibilityIdentifier("reading-page-\(page)")
        .accessibilityAddTraits(current ? .isSelected : [])
        #if DEBUG
            .onDisappear { model.snapshotThumbnailRequests.removeValue(forKey: captureID) }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PageTileFramePreference.self, value: [page: geometry.frame(in: .global)])
                }
            }
        #endif
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(id: request, priority: .utility) {
            #if DEBUG
                if model.snapshotContentsTab == .pages {
                    model.snapshotThumbnailRequests[captureID] = request == nil ? nil : false
                }
            #endif
            loaded = nil
            guard let request, let thumbnails = model.thumbnails(for: request.generation),
                let image = await thumbnails.image(page: page, pixels: pixels), !Task.isCancelled
            else { return }
            loaded = (request, image)
            if page + 1 < model.pageCount {
                _ = await thumbnails.image(page: page + 1, pixels: pixels)
            }
        }
    }
}

#if DEBUG
    /// Report rings that the hosted drawer actually drew, including duplicate rings on different pages.
    struct PageFocusRingPreference: PreferenceKey {
        static let defaultValue: Set<Int> = []
        static func reduce(value: inout Set<Int>, nextValue: () -> Set<Int>) {
            value.formUnion(nextValue())
        }
    }

    /// Where each tile was laid out, so that hosted tests can check the order of a row on screen.
    struct PageTileFramePreference: PreferenceKey {
        static let defaultValue: [Int: CGRect] = [:]
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    /// Report the pages the hosted drawer actually framed as current. Hosted tests cannot rely on the
    /// accessibility tree, which SwiftUI builds only for an assistive client.
    struct PageCurrentFramePreference: PreferenceKey {
        static let defaultValue: Set<Int> = []
        static func reduce(value: inout Set<Int>, nextValue: () -> Set<Int>) {
            value.formUnion(nextValue())
        }
    }
#endif

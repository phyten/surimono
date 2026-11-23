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

nonisolated private struct DraggedImagePage: Codable, Transferable {
    let bundle: UUID
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "app.surimono.image-page")).visibility(.ownProcess)
    }
}

struct ContentsPages: View {
    let model: DocumentViewModel
    let popover: Bool
    @FocusState private var focused: Bool
    @State private var selection: Int?
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let columns = !popover && geometry.size.width >= 220 ? 2 : 1
            let width = min(200, floor((geometry.size.width - CGFloat(columns - 1) * 10 - 12) / CGFloat(columns)))
            grid(columns: columns, width: max(32, width))
        }
    }

    private func grid(columns: Int, width: CGFloat) -> some View {
        let generation = model.thumbnailGeneration
        let marks = Set(model.bookmarkPages)
        let sections = PageSection.sections(count: model.pageCount, chapters: model.chapterEntries)
        let items = model.imageBundle?.items.filter { !model.unreadableImageURLs.contains($0.url) }
        let current = model.currentPageIndex
        let selected = selection ?? current
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.pages, id: \.self) { page in
                                let item = items.flatMap { $0.indices.contains(page) ? $0[page] : nil }
                                let tile = PageTile(
                                    model: model, page: page, generation: generation, width: width,
                                    scale: scale, chapter: section.title, marked: marks.contains(page),
                                    current: page == current, selected: focused && selected == page
                                ) {
                                    selection = page
                                    focused = true
                                    jump(page, item: item)
                                }
                                if let item, let bundle = model.imageBundle {
                                    tile.modifier(
                                        BundlePageDrag(model: model, bundle: bundle, item: item, columns: columns)
                                    ).id(page)
                                } else {
                                    tile.id(page)
                                }
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
                .padding(4)
            }
            .focusable()
            .focused($focused)
            .accessibilityLabel("Pages Tab")
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return]) { press in
                // Arrow keys always carry the numeric-pad and function flags.
                guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]), model.pageCount > 0
                else { return .ignored }
                let next: Int
                switch press.key {
                case .upArrow, .downArrow:
                    next = PageSection.verticalNeighbor(
                        of: selected, down: press.key == .downArrow, columns: columns, sections: sections)
                case .leftArrow: next = selected - 1
                case .rightArrow: next = selected + 1
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
            .onChange(of: columns, initial: true) { _, value in
                if model.imageBundle != nil { model.drop.usesPageGrid = value == 2 }
            }
            .onDisappear {
                if model.imageBundle != nil {
                    model.drop.listFrame = nil
                    model.drop.usesPageGrid = false
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
    let item: ImageBundleModel.Item
    let columns: Int
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .help(item.name)
            .background {
                if bundle.flashedURLs.contains(item.url) { CornerRole.control.shape.fill(PrintPalette.aiTint2) }
            }
            .draggable(DraggedImagePage(bundle: bundle.dragID, url: item.url))
            .dropDestination(for: DraggedImagePage.self) { dragged, point in
                guard let source = dragged.first, source.bundle == bundle.dragID,
                    let from = bundle.items.firstIndex(where: { $0.url == source.url }),
                    let to = bundle.items.firstIndex(of: item)
                else { return false }
                let after = columns == 1 ? point.y > size.height / 2 : point.x > size.width / 2
                bundle.move(fromOffsets: IndexSet(integer: from), toOffset: to + (after ? 1 : 0))
                return true
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { frame in
                if size != frame.size { size = frame.size }
                model.drop.rowFrames[item.url] = frame
            }
            .onDisappear { model.drop.rowFrames[item.url] = nil }
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
    let jump: () -> Void
    #if DEBUG
        @State private var captureID = UUID()
    #endif
    @State private var visible = false
    @State private var loaded: (Request, CGImage)?

    private var aspect: CGFloat {
        if let size = model.slideDeck?.size, size.width > 0, size.height > 0 { return size.width / size.height }
        guard let sheet = model.result?.viewDocument.page(at: page) else { return 0.707 }
        let box = sheet.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return 0.707 }
        return sheet.rotation % 180 == 0 ? box.width / box.height : box.height / box.width
    }

    var body: some View {
        let ratio = aspect
        let height = min(208, width / ratio)
        let paperWidth = min(width, height * ratio)
        // Quantize the long edge so dragging the divider does not generate a bitmap for every point.
        let pixels = min(1024, max(32, Int(ceil(max(height, paperWidth) * scale / 32)) * 32))
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
                    .frame(width: paperWidth, height: height)
                    .overlay {
                        Rectangle().strokeBorder(
                            current ? PrintPalette.ai : PrintPalette.line, lineWidth: current ? 3 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if marked { Image(systemName: "bookmark.fill").foregroundStyle(PrintPalette.ai).padding(3) }
                    }
                Text(verbatim: String(page + 1)).monospacedDigit().font(.caption)
            }
            .padding(2)
            .overlay { if selected { Rectangle().strokeBorder(PrintPalette.ai, style: StrokeStyle(dash: [2, 2])) } }
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
        .accessibilityAddTraits(current ? .isSelected : [])
        #if DEBUG
            .onDisappear { model.snapshotThumbnailRequests.removeValue(forKey: captureID) }
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

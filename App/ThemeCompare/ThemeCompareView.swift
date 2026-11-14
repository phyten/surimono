import PDFKit
import SurimonoCore
import SwiftUI

/// The comparison stage (見比べ台, 案 D): up to four themes side by side on this document's first page, or from a heading
/// or a code block chosen in the bar, in the print tray's colours. A candidate becomes the current theme with
/// 「これにする」; the row below adds and takes out others.
struct ThemeCompareView: View {
    @Bindable var model: DocumentViewModel
    @State private var filterID = "featured"
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            CompareTopBar(model: model, onShuffle: shuffle).zIndex(1)
            stage
            tray.zIndex(1)
        }
        .foregroundStyle(PrintPalette.ink)
        .tint(PrintPalette.ai)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            model.followThemeSamples()
            if let window = model.window { ViewerWindow.setTrafficLightsVisible(true, in: window) }
        }
        .onChange(of: model.renderSettings) { _, _ in model.followThemeSamples() }
        .task(id: model.themeSamples.generation) { await model.followComparePlaces() }
        .onDisappear { noticeTask?.cancel() }
    }

    private var comparison: ThemeComparison {
        model.themeComparison ?? ThemeComparison(current: model.themeID, suggestions: [])
    }

    private var stage: some View {
        GeometryReader { proxy in
            let candidates = comparison.candidates.compactMap { model.theme($0) }
            let layout = ThemeCompareLayout(stage: proxy.size, paper: model.themeSamples.paperSize)
            ZStack(alignment: .top) {
                PrintPalette.stage
                // Four across while each page keeps its width, two when the window is narrow; the rest scrolls.
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(
                                .fixed(layout.cardWidth), spacing: ThemeCompareLayout.gap, alignment: .top),
                            count: layout.columns),
                        spacing: ThemeCompareLayout.gap
                    ) {
                        ForEach(candidates) { theme in
                            CompareCard(
                                model: model, theme: theme, width: layout.cardWidth,
                                onChoose: { choose(theme) },
                                onRemove: { model.themeComparison?.remove(theme.id) })
                        }
                        ForEach(candidates.count..<ThemeComparison.capacity, id: \.self) { _ in
                            // Level with the pages, below the row that marks the current one.
                            EmptyCompareSlot(width: layout.cardWidth, paperSize: model.themeSamples.paperSize)
                                .padding(.top, ThemeCompareLayout.tagRowHeight + ThemeCompareLayout.rowSpacing)
                        }
                    }
                    .padding(.horizontal, ThemeCompareLayout.margin)
                    .padding(.top, ThemeCompareLayout.topInset)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                if let notice {
                    Text(verbatim: notice)
                        .font(.system(size: 12.5))
                        .foregroundStyle(PrintPalette.toastInk)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(PrintPalette.toast))
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: notice)
            .animation(.easeOut(duration: 0.2), value: comparison.candidates)
        }
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Add to Compare").font(.system(size: 12, weight: .semibold)).foregroundStyle(PrintPalette.ink2)
                Text("Up to four").font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                FadingScrollRow {
                    HStack(spacing: 6) {
                        ForEach(filters, id: \.id) { filter in
                            ThemeGroupChip(
                                title: filter.title, isSelected: filter.id == filterID,
                                selectedText: PrintPalette.raised, action: { filterID = filter.id })
                        }
                    }
                    .padding(2)
                }
            }
            FadingScrollRow {
                HStack(alignment: .top, spacing: 12) {
                    let themes = themes(for: filterID)
                    if themes.isEmpty {
                        Text(filterID == "favorites" ? "Styles you star appear here." : "Nothing here yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(PrintPalette.ink2)
                            .padding(.vertical, 30)
                    }
                    ForEach(themes) { theme in
                        CompareTrayCell(model: model, theme: theme) { model.themeComparison?.toggle(theme.id) }
                    }
                }
                // Room above and beside the samples for the check that hangs off a corner.
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(PrintPalette.chrome)
        .overlay(alignment: .top) { Rectangle().fill(PrintPalette.line).frame(height: 1) }
    }

    private var filters: [(id: String, title: String)] {
        [
            ("featured", String(localized: "Suggested")), ("favorites", String(localized: "Favorites")),
            ("recent", String(localized: "Recent")),
        ]
            + model.themeGroups.map { group in
                switch group.kind {
                case .category(let category): (group.id, category.displayName(language: model.language))
                default: (group.id, String(localized: "My Styles"))
                }
            }
    }

    private func themes(for filterID: String) -> [PrintTheme] {
        model.themeMenu.sections.first { $0.id == filterID }?.themes ?? []
    }

    private func choose(_ theme: PrintTheme) {
        model.selectTheme(theme.id)
        let name = theme.displayName(language: model.language)
        notice = String(format: String(localized: "%@ is the style now. The paper shows it when you go back."), name)
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// 「おまかせで並べ替える」: the current theme and three from the row's group, or from all if it is short.
    private func shuffle() {
        let group = themes(for: filterID).map(\.id)
        let pool = group.count > 3 ? group : model.library.themes.filter(\.isBuiltIn).map(\.id)
        var generator = SystemRandomNumberGenerator()
        model.themeComparison?.shuffle(from: pool, using: &generator)
    }
}

/// The stage's bar: back to the view mode, what is compared and 「おまかせ」. The current style is told by its tag on
/// the stage, not here.
private struct CompareTopBar: View {
    @Bindable var model: DocumentViewModel
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.exitCompareMode()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PrintPalette.ink2)
                    Text("Back to View")
                    PrintTag(
                        text: "esc", font: .system(size: 9.5), color: PrintPalette.ink3, border: PrintPalette.line2
                    )
                    .padding(.leading, 3)
                }
                .padding(.horizontal, 7)
            }
            .buttonStyle(PrintBorderedButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Back to the view mode (Esc)")
            .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text("Compare Styles").font(.system(size: 13, weight: .semibold))
                // A chosen place is told by the button that chose it.
                Text(
                    verbatim: model.comparePlace == nil
                        ? String(format: String(localized: "First page of %@"), model.displayName) : model.displayName
                )
                .font(.system(size: 11))
                .foregroundStyle(PrintPalette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .padding(.leading, 16)
            .layoutPriority(-1)
            Spacer(minLength: 12)
            if !model.themeSamples.places.isEmpty {
                ComparePlacePicker(model: model).padding(.trailing, 8)
            }
            Button(action: onShuffle) {
                Label("Shuffle", systemImage: "dice").padding(.horizontal, 9)
            }
            .buttonStyle(PrintBorderedButtonStyle())
            .help("Keep the current style and pick three others at random")
            .fixedSize()
        }
        .padding(.leading, trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(PrintPalette.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(PrintPalette.line).frame(height: 1) }
    }

    /// The traffic lights stay where the window draws them; the bar starts after them.
    private var trafficLightInset: CGFloat {
        guard let button = model.window?.standardWindowButton(.zoomButton) else { return 86 }
        return max(button.convert(button.bounds, to: nil).maxX + 14, 76)
    }
}

/// 「比べる箇所」: where the stage's pages start. Themes fit different amounts on a page, so their first pages rarely
/// show the same text; from one heading or code block they all do.
private struct ComparePlacePicker: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Button {
            model.isComparePlacePickerPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Text("Compare At").foregroundStyle(PrintPalette.ink2)
                Text(verbatim: model.comparePlace?.title ?? String(localized: "First Page"))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PrintPalette.ink2)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
        }
        .buttonStyle(PrintBorderedButtonStyle())
        .fixedSize()
        .help("Start every page at the same heading or code")
        .popover(isPresented: $model.isComparePlacePickerPresented, arrowEdge: .bottom) {
            ComparePlaceList(model: model).presentationBackground(PrintPalette.raised)
        }
    }
}

/// The places to choose from: the first page, then the headings, deepest indented, and the code blocks.
private struct ComparePlaceList: View {
    @Bindable var model: DocumentViewModel

    private static let firstPageID = "first-page"
    private static let rowHeight: CGFloat = 30
    private static let titleHeight: CGFloat = 28
    private static let rowSpacing: CGFloat = 1
    private static let padding: CGFloat = 6
    private static let maximumHeight: CGFloat = 420

    var body: some View {
        let headings = model.themeSamples.places.filter { $0.kind == .heading }
        let code = model.themeSamples.places.filter { $0.kind == .code }
        let top = headings.compactMap(\.level).min() ?? 1
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ComparePlaceRow(
                        title: String(localized: "First Page"), height: Self.rowHeight,
                        isCurrent: model.comparePlace == nil
                    ) { choose(nil) }
                    .id(Self.firstPageID)
                    if !headings.isEmpty { sectionTitle("Headings") }
                    ForEach(headings) { place in
                        ComparePlaceRow(
                            title: place.title, indent: (place.level ?? top) - top, height: Self.rowHeight,
                            isCurrent: place == model.comparePlace
                        ) { choose(place) }
                        .id(place.id)
                    }
                    if !code.isEmpty { sectionTitle("Code") }
                    ForEach(code) { place in
                        ComparePlaceRow(
                            title: place.title, isCode: true, height: Self.rowHeight,
                            isCurrent: place == model.comparePlace
                        ) { choose(place) }
                        .id(place.id)
                    }
                }
                .padding(Self.padding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onAppear { proxy.scrollTo(model.comparePlace?.id ?? Self.firstPageID, anchor: .center) }
        }
        .frame(width: 320, height: height(headings: headings.count, code: code.count))
        .accessibilityLabel("Compare At")
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PrintPalette.ink2)
            .padding(.horizontal, 8)
            .frame(height: Self.titleHeight, alignment: .bottomLeading)
    }

    private func height(headings: Int, code: Int) -> CGFloat {
        let rows = 1 + headings + code
        let titles = (headings > 0 ? 1 : 0) + (code > 0 ? 1 : 0)
        let content =
            CGFloat(rows) * Self.rowHeight + CGFloat(titles) * Self.titleHeight
            + CGFloat(rows + titles - 1) * Self.rowSpacing + Self.padding * 2
        return min(content, Self.maximumHeight)
    }

    private func choose(_ place: SamplePlace?) {
        model.comparePlace = place
        model.isComparePlacePickerPresented = false
    }
}

private struct ComparePlaceRow: View {
    let title: String
    var indent = 0
    var isCode = false
    let height: CGFloat
    let isCurrent: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            Text(verbatim: title)
                .font(
                    isCode
                        ? .system(size: 12, design: .monospaced)
                        : .system(size: 13, weight: isCurrent ? .semibold : .regular)
                )
                // The raised paper colour reads on the indigo in both appearances.
                .foregroundStyle(isCurrent ? PrintPalette.raised : PrintPalette.ink)
                .lineLimit(isCode ? 1 : 2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8 + CGFloat(min(indent, 4)) * 12)
                .padding(.trailing, 8)
                .frame(minHeight: height)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isCurrent ? PrintPalette.ai : isHovered ? PrintPalette.hover : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// One candidate: its page, name and category, a star, 「外す」 and 「これにする」. The current style is marked by its tag
/// alone: a frame, a fill and a button of the same strength on every card would outweigh the pages.
private struct CompareCard: View {
    let model: DocumentViewModel
    let theme: PrintTheme
    let width: CGFloat
    let onChoose: () -> Void
    let onRemove: () -> Void
    /// The page last drawn, which stays up while the next place is drawn rather than leaving a blank sheet for a moment.
    @State private var lastPage: PDFPage?

    var body: some View {
        let place = model.comparePlace
        let page = model.themeSamples.page(for: theme, at: place)
        let isCurrent = theme.id == model.themeID
        let isFavorite = model.isFavoriteTheme(theme.id)
        let name = theme.displayName(language: model.language)
        VStack(alignment: .leading, spacing: ThemeCompareLayout.rowSpacing) {
            // Above the page, so the tag never covers the document's own heading.
            HStack {
                if isCurrent {
                    Text("Current Style")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PrintPalette.raised)
                        .padding(.horizontal, 8)
                        .frame(height: ThemeCompareLayout.tagRowHeight)
                        .background(Capsule().fill(PrintPalette.ai))
                }
            }
            .frame(height: ThemeCompareLayout.tagRowHeight)
            ThemeSampleView(
                page: page ?? lastPage, paperSize: model.themeSamples.paperSize,
                margins: model.themeSamples.margins, cornerRadius: 2
            )
            .frame(width: width)
            .shadow(color: PrintPalette.paperShadow, radius: 7, y: 3)
            .overlay {
                RoundedRectangle(cornerRadius: 2).strokeBorder(PrintPalette.paperRing, lineWidth: 1)
            }
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .help(name)
                    Text(verbatim: categoryName).font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                // The star and the cross are the same size and shape, so that they read as one kind of control.
                FavoriteStarButton(
                    isFavorite: isFavorite, name: name, idleColor: PrintPalette.ink2
                ) { model.toggleFavoriteTheme(theme.id) }
                .buttonStyle(PrintIconButtonStyle(size: Self.iconSize))
                if !isCurrent {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PrintPalette.ink2)
                            .frame(width: Self.iconSize.width, height: Self.iconSize.height)
                    }
                    .buttonStyle(PrintIconButtonStyle(size: Self.iconSize))
                    .accessibilityLabel(Text(verbatim: String(format: String(localized: "Remove %@"), name)))
                    .help("Remove from Compare")
                }
            }
            .frame(width: width, height: ThemeCompareLayout.nameRowHeight, alignment: .top)
            if !isCurrent {
                Button(action: onChoose) { Text("Use This") }
                    .buttonStyle(CompareChooseButtonStyle())
                    .frame(width: width)
            }
        }
        .task(id: model.themeSamples.taskID(for: theme, at: place)) { await model.themeSamples.load(theme, at: place) }
        .onChange(of: page) { _, page in if let page { lastPage = page } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: name))
    }

    private static let iconSize = CGSize(width: 22, height: 22)

    private var categoryName: String {
        guard let id = theme.category,
            let category = model.library.themeCategories.first(where: { $0.id == id })
        else { return String(localized: "My Styles") }
        return category.displayName(language: model.language)
    }
}

/// 「これにする」: an outline until the pointer is on it, then filled with the indigo. Filled on every card, it
/// outweighed the pages it stands under.
private struct CompareChooseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompareChooseButton(configuration: configuration)
    }
}

private struct CompareChooseButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let isFilled = (hovering || configuration.isPressed) && isEnabled
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            // The raised paper colour reads on the indigo in both appearances; white fades on the night one.
            .foregroundStyle(isFilled ? PrintPalette.raised : PrintPalette.ink)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: ThemeCompareLayout.buttonHeight)
            .background { RoundedRectangle(cornerRadius: 6).fill(isFilled ? PrintPalette.ai : .clear) }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFilled ? PrintPalette.ai : PrintPalette.line3, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

/// A place for one more candidate.
private struct EmptyCompareSlot: View {
    let width: CGFloat
    let paperSize: CGSize

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 18, weight: .light))
            Text("Pick a style in the row below").font(.system(size: 12)).multilineTextAlignment(.center)
        }
        .foregroundStyle(PrintPalette.ink3)
        .frame(width: width, height: width * paperSize.height / max(paperSize.width, 1))
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(
                PrintPalette.line3, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
    }
}

/// A small sample in the stage's row: a click adds the theme to the stage or takes it out. A candidate on the stage
/// carries a check that hangs off the corner of its page.
private struct CompareTrayCell: View {
    let model: DocumentViewModel
    let theme: PrintTheme
    let onToggle: () -> Void
    @State private var isHovering = false

    static let width: CGFloat = 80

    var body: some View {
        let isIn = model.themeComparison?.contains(theme.id) ?? false
        let name = theme.displayName(language: model.language)
        Button(action: onToggle) {
            VStack(spacing: 4) {
                ThemeSampleView(
                    page: model.themeSamples.page(for: theme), paperSize: model.themeSamples.paperSize,
                    margins: model.themeSamples.margins, cornerRadius: 2
                )
                .frame(width: Self.width)
                .shadow(color: PrintPalette.paperShadow, radius: 2, y: 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(PrintPalette.paperRing, lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    // Off the page's corner, clear of the page's own heading.
                    Image(systemName: isIn ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(PrintPalette.raised, isIn ? PrintPalette.ai : PrintPalette.ink3)
                        .background(Circle().fill(PrintPalette.chrome).padding(-1.5))
                        .offset(x: 6, y: -6)
                        .opacity(isIn || isHovering ? 1 : 0)
                }
                Text(verbatim: name)
                    .font(.system(size: 11))
                    .foregroundStyle(PrintPalette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.width)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovering ? PrintPalette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .task(id: model.themeSamples.taskID(for: theme)) { await model.themeSamples.load(theme) }
        .help(name)
        .accessibilityLabel(
            Text(
                verbatim: String(
                    format: isIn
                        ? String(localized: "Remove %@ from Compare") : String(localized: "Add %@ to Compare"), name))
        )
        .accessibilityAddTraits(isIn ? .isSelected : [])
    }
}

/// A row that scrolls sideways and fades out at its right end while more lies beyond it, so that a sample or a
/// category cut off by the edge reads as "there is more", not as a mistake.
private struct FadingScrollRow<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var hasMore = false

    static var fadeWidth: CGFloat { 24 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { content }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.width - geometry.contentOffset.x - geometry.containerSize.width > 1
            } action: { _, more in
                hasMore = more
            }
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: hasMore ? Self.fadeWidth : 0)
                }
                .animation(.easeOut(duration: 0.15), value: hasMore)
            }
    }
}

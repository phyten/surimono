import SurimonoCore
import SwiftUI

/// The comparison stage (見比べ台, 案 D): up to four themes side by side on this document's first page, in the print
/// tray's colours. A candidate becomes the current theme with 「これにする」; the row below adds and takes out others.
struct ThemeCompareView: View {
    @Bindable var model: DocumentViewModel
    @State private var filterID = "featured"
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    static let gap: CGFloat = 22

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
        .onDisappear { noticeTask?.cancel() }
    }

    private var comparison: ThemeComparison {
        model.themeComparison ?? ThemeComparison(current: model.themeID, suggestions: [])
    }

    private var stage: some View {
        GeometryReader { proxy in
            let candidates = comparison.candidates.compactMap { model.theme($0) }
            let width = cardWidth(in: proxy.size)
            ZStack(alignment: .top) {
                PrintPalette.stage
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(candidates) { theme in
                        CompareCard(
                            model: model, theme: theme, width: width,
                            onChoose: { choose(theme) },
                            onRemove: { model.themeComparison?.remove(theme.id) })
                    }
                    ForEach(candidates.count..<ThemeComparison.capacity, id: \.self) { _ in
                        // Level with the pages, below the row that marks the current one.
                        EmptyCompareSlot(width: width, paperSize: model.themeSamples.paperSize)
                            .padding(.top, 29)
                    }
                }
                .padding(.top, 18)
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

    /// Four pages and the room under them for their names and buttons fill the stage, whichever runs out first.
    private func cardWidth(in size: CGSize) -> CGFloat {
        let count = CGFloat(ThemeComparison.capacity)
        let byWidth = (size.width - 64 - Self.gap * (count - 1)) / count
        let paper = model.themeSamples.paperSize
        // The mark above the page, the name and category, the button and the gaps between them take 185 pt.
        let byHeight = (size.height - 18 - 185) * paper.width / max(paper.height, 1)
        return max(min(byWidth, byHeight, 300), 120)
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Add to Compare").font(.system(size: 12, weight: .semibold)).foregroundStyle(PrintPalette.ink2)
                Text("Up to four").font(.system(size: 11)).foregroundStyle(PrintPalette.ink3)
                ScrollView(.horizontal, showsIndicators: false) {
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
            ScrollView(.horizontal, showsIndicators: false) {
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
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
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

/// The stage's bar: back to the view mode, what is compared, the current theme and 「おまかせ」.
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
                Text(verbatim: String(format: String(localized: "First page of %@"), model.displayName))
                    .font(.system(size: 11))
                    .foregroundStyle(PrintPalette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, 16)
            .layoutPriority(-1)
            Spacer(minLength: 12)
            Text(
                verbatim: String(
                    format: String(localized: "Current: %@"),
                    model.theme(model.themeID)?.displayName(language: model.language) ?? model.themeID)
            )
            .font(.system(size: 12))
            .foregroundStyle(PrintPalette.ink2)
            .lineLimit(1)
            .padding(.trailing, 12)
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

/// One candidate: its page, name and category, a star, 「外す」 and 「これにする」.
private struct CompareCard: View {
    let model: DocumentViewModel
    let theme: PrintTheme
    let width: CGFloat
    let onChoose: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let isCurrent = theme.id == model.themeID
        let isFavorite = model.isFavoriteTheme(theme.id)
        let name = theme.displayName(language: model.language)
        VStack(alignment: .leading, spacing: 9) {
            // Above the page, so the mark never covers the document's own heading.
            HStack {
                if isCurrent {
                    Text("Current Style")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PrintPalette.raised)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(PrintPalette.ai))
                }
            }
            .frame(height: 20)
            ThemeSampleView(
                page: model.themeSamples.page(for: theme), paperSize: model.themeSamples.paperSize,
                margins: model.themeSamples.margins, cornerRadius: 2
            )
            .frame(width: width)
            .shadow(color: PrintPalette.paperShadow, radius: 7, y: 3)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isCurrent ? PrintPalette.ai : PrintPalette.paperRing, lineWidth: isCurrent ? 2 : 1)
            }
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(name)
                    Text(verbatim: categoryName).font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                FavoriteStarButton(isFavorite: isFavorite, name: name) { model.toggleFavoriteTheme(theme.id) }
                if !isCurrent {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PrintPalette.ink2)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(PrintIconButtonStyle())
                    .accessibilityLabel(Text(verbatim: String(format: String(localized: "Remove %@"), name)))
                    .help("Remove from Compare")
                }
            }
            .frame(width: width)
            Button(action: onChoose) {
                Text(isCurrent ? "Current Style" : "Use This")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: width, height: 30)
                    // The raised paper colour reads on the indigo in both appearances; white fades on the night one.
                    .foregroundStyle(isCurrent ? PrintPalette.ink2 : PrintPalette.raised)
                    .background(
                        RoundedRectangle(cornerRadius: 7).fill(isCurrent ? PrintPalette.aiTint : PrintPalette.ai)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(isCurrent)
        }
        .task(id: model.themeSamples.taskID(for: theme)) { await model.themeSamples.load(theme) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: name))
    }

    private var categoryName: String {
        guard let id = theme.category,
            let category = model.library.themeCategories.first(where: { $0.id == id })
        else { return String(localized: "My Styles") }
        return category.displayName(language: model.language)
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
            RoundedRectangle(cornerRadius: 3).strokeBorder(
                PrintPalette.line3, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
    }
}

/// A small sample in the stage's row: a click adds the theme to the stage or takes it out.
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
            VStack(spacing: 5) {
                ThemeSampleView(
                    page: model.themeSamples.page(for: theme), paperSize: model.themeSamples.paperSize,
                    margins: model.themeSamples.margins, cornerRadius: 2
                )
                .frame(width: Self.width)
                .shadow(color: PrintPalette.paperShadow, radius: 2, y: 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(isIn ? PrintPalette.ai : PrintPalette.paperRing, lineWidth: isIn ? 2 : 1)
                }
                .overlay(alignment: .topLeading) {
                    Image(systemName: isIn ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(PrintPalette.raised, isIn ? PrintPalette.ai : PrintPalette.ink3)
                        .padding(4)
                        .opacity(isIn || isHovering ? 1 : 0)
                }
                Text(verbatim: name)
                    .font(.system(size: 10.5, weight: isIn ? .semibold : .regular))
                    .foregroundStyle(isIn ? PrintPalette.ai : PrintPalette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.width)
            }
            .padding(3)
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

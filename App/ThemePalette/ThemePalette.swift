import SurimonoCore
import SwiftUI

/// The style palette (案 A): every print theme as a sample of this document's first page. Resting the pointer on a
/// sample tries it on the paper; a click chooses it and leaves the palette open for the next look.
struct ThemePalette: View {
    @Bindable var model: DocumentViewModel
    @State private var query = ""

    static let columns = 5
    static let cellWidth: CGFloat = 104
    static let width: CGFloat = 628
    static let height: CGFloat = 660

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Leaving the samples puts the paper back; moving between them keeps the last trial meanwhile.
            .onHover { inside in if !inside { model.endThemeTrial() } }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: Self.width, height: Self.height)
        .onAppear { model.followThemeSamples() }
        .onChange(of: model.renderSettings) { _, _ in model.followThemeSamples() }
        .onDisappear { model.themePaletteDidClose() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Print Theme").font(.system(size: 14, weight: .semibold)).fixedSize()
                Text(verbatim: model.theme(model.themeID)?.displayName(language: model.language) ?? model.themeID)
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name or category", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear Search"))
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        }
    }

    @ViewBuilder private var content: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = model.searchThemes(query)
            section(
                String(format: String(localized: "Matching “%@”"), query.trimmingCharacters(in: .whitespaces)),
                count: matches.count, themes: matches,
                empty: String(localized: "No styles match. Try a category instead."))
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(model.themeMenu.sections, id: \.id) { group in
                    section(groupTitle(group), themes: group.themes)
                }
            }
        }
    }

    private func section(_ title: String, count: Int? = nil, themes: [PrintTheme], empty: String? = nil)
        -> some View
    {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                if let count {
                    Text(verbatim: "\(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if themes.isEmpty, let empty {
                Text(verbatim: empty)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.quaternary))
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(Self.cellWidth), spacing: 10, alignment: .top), count: Self.columns),
                    alignment: .leading, spacing: 12
                ) {
                    ForEach(themes) { theme in
                        ThemePaletteCell(model: model, theme: theme, width: Self.cellWidth)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.enterCompareMode()
            } label: {
                Label("Compare…", systemImage: "square.grid.2x2")
            }
            .help("Lay a few styles side by side")
            Spacer(minLength: 8)
            Text("Text Size").font(.system(size: 11.5)).foregroundStyle(.secondary)
            ControlGroup {
                Button {
                    model.decreaseTextSize()
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .accessibilityLabel(Text("Smaller"))
                Button {
                    model.resetTextSize()
                } label: {
                    Text(verbatim: model.textScalePercentage).monospacedDigit().frame(minWidth: 38)
                }
                .help("Original Size")
                Button {
                    model.increaseTextSize()
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityLabel(Text("Larger"))
            }
            .fixedSize()
        }
        .controlSize(.small)
    }

    private func groupTitle(_ group: PrintThemeMenu.Section) -> String {
        switch group.kind {
        case .category(let category): category.displayName(language: model.language)
        case .recent: String(localized: "Recent")
        case .favorites: String(localized: "Favorites")
        case .featured: String(localized: "Suggested")
        case .user: String(localized: "My Styles")
        }
    }
}

/// One sample in the palette: the page, its name, a star, and a mark on the current theme.
struct ThemePaletteCell: View {
    let model: DocumentViewModel
    let theme: PrintTheme
    let width: CGFloat
    @State private var isHovering = false
    @FocusState private var isStarFocused: Bool

    var body: some View {
        let isCurrent = theme.id == model.themeID
        let isFavorite = model.isFavoriteTheme(theme.id)
        let name = theme.displayName(language: model.language)
        Button {
            model.selectTheme(theme.id)
        } label: {
            VStack(spacing: 5) {
                ThemeSampleView(
                    page: model.themeSamples.page(for: theme), paperSize: model.themeSamples.paperSize,
                    margins: model.themeSamples.margins
                )
                .frame(width: width)
                .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(
                            isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.black.opacity(0.12)),
                            lineWidth: isCurrent ? 2 : 0.5)
                }
                Text(verbatim: name)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 7).fill(isHovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .tint)
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Always there, so the keyboard can reach it; it shows on hover, when focused, or on a favorite.
            let showsStar = isHovering || isFavorite || isStarFocused
            FavoriteStarButton(isFavorite: isFavorite, name: name) { model.toggleFavoriteTheme(theme.id) }
                .focused($isStarFocused)
                .opacity(showsStar ? 1 : 0)
                .allowsHitTesting(showsStar)
                .padding(7)
        }
        .onHover { inside in
            isHovering = inside
            if inside { model.tryTheme(theme.id) }
        }
        .task(id: model.themeSamples.taskID(for: theme)) { await model.themeSamples.load(theme) }
        .help(name)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityAction(
            named: isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites")
        ) { model.toggleFavoriteTheme(theme.id) }
    }
}

/// The star that adds a theme to the favorites or takes it out.
struct FavoriteStarButton: View {
    let isFavorite: Bool
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isFavorite ? Color.orange : Color.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.background).shadow(color: .black.opacity(0.18), radius: 1, y: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .help(isFavorite ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites"))
    }

    private var label: String {
        if isFavorite {
            String(format: String(localized: "Remove %@ from Favorites"), name)
        } else {
            String(format: String(localized: "Add %@ to Favorites"), name)
        }
    }
}

/// A category to show in the palette.
struct ThemeGroupChip: View {
    let title: String
    let isSelected: Bool
    /// The text on the tint when selected; a light tint, such as the stage's indigo at night, needs dark text.
    var selectedText: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11.5))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .foregroundStyle(isSelected ? AnyShapeStyle(selectedText) : AnyShapeStyle(.primary))
                .background(
                    Capsule().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.06)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
